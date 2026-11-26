require 'json'

module DMACC
  module WallFramer
    # HtmlDialog windows and their callbacks.
    module Dialogs
      HTML = File.join(__dir__, 'html')
      @frame = nil
      @frame_wall = nil
      @setup = nil
      @takeoff = nil

      class << self
        # ---------------- shared ----------------

        def make(title, file, w, h, key)
          d = UI::HtmlDialog.new(dialog_title: title, preferences_key: "dmacc_wf_#{key}",
                                 width: w, height: h, min_width: 600, min_height: 400,
                                 resizable: true, style: UI::HtmlDialog::STYLE_DIALOG)
          d.set_file(File.join(HTML, file))
          d
        end

        def js(dialog, fn, data)
          dialog.execute_script("#{fn}(#{JSON.generate(data)})")
        end

        def len_text(v)
          Framing.fmt_len(v.to_f)
        end

        def parse_required(text, what, errs)
          v = Framing.parse_len(text)
          errs << "#{what}: couldn't read \"#{text}\"." if v.nil?
          v
        end

        def operation(name)
          m = Sketchup.active_model
          m.start_operation(name, true)
          yield
          m.commit_operation
        rescue StandardError => e
          m.abort_operation
          UI.messagebox("Wall Framer error: #{e.message}")
          puts e.full_message
        end

        # ---------------- framing form ----------------

        def open_frame(wall, center: nil)
          @frame_wall = Builder.params_of(wall)['id']
          @prefill = center
          if @frame&.visible?
            send_frame
            @frame.bring_to_front
            return
          end
          @frame = make('Frame Wall', 'frame.html', 900, 720, 'frame')
          d = @frame
          d.add_action_callback('ready') { |_c, _a| send_frame }
          d.add_action_callback('save_openings') { |_c, a| save_openings(JSON.parse(a)) }
          d.add_action_callback('save_entries') { |_c, a| save_entries(JSON.parse(a)['entries']) }
          d.add_action_callback('inspect') { |_c, _a| request_inspection(nil) }
          d.add_action_callback('go_frame') { |_c, _a| open_yard; Sketchup.active_model.select_tool(InstallTool.new) }
          d.add_action_callback('shop') { |_c, _a| (g = frame_group) && open_shop(g) }
          d.add_action_callback('zoom') { |_c, a| zoom(JSON.parse(a)['slot']) }
          d.show
        end

        def frame_group
          g = Builder.find_wall(@frame_wall)
          UI.messagebox("Wall #{@frame_wall} isn't in the model anymore.") unless g
          g
        end

        def group_name(slot)
          if slot.opening then "Opening #{slot.opening}"
          elsif slot.kind == :horizontal then 'Plates'
          else 'Studs on layout'
          end
        end

        STEP_NAMES = ['1. Plates', '2. Lay out openings', '3. Build opening units', '4. Lay out + nail commons', '5. Double top plate'].freeze

        def frame_state(group)
          p = Builder.params_of(group)
          s = Project.settings
          table = Project.header_table
          slots = Builder.work_slots(p)
          # Group display order: plates, studs on layout, then each opening
          order = slots.sort_by do |sl|
            g = group_name(sl)
            [g == 'Plates' ? 0 : g == 'Studs on layout' ? 1 : 2, sl.opening.to_s, sl.kind == :horizontal ? 0 : 1, sl.x, sl.z]
          end
          entries = p['entries'] || {}
          {
            'wall' => { 'id' => p['id'], 'type' => p['type'], 'level' => p['level'], 'stud' => p['stud'],
                        'spacing' => p['spacing'], 'length_text' => len_text(p['length']),
                        'height_text' => len_text(p['height']) },
            'pos_mode' => @prefill ? 'center' : 'left',
            'prefill' => @prefill && { 'x_text' => len_text(@prefill) },
            'openings' => p['openings'].map do |o|
              { 'mark' => o['mark'], 'type' => o['type'],
                'x_text' => len_text(@prefill ? o['x'].to_f + o['width'].to_f / 2.0 : o['x']),
                'width_text' => len_text(o['width']), 'height_text' => len_text(Framing.ro_height(o)),
                'sill_text' => o['type'] == 'Window' ? len_text(o['height']) : '', 'header' => o['header'] || 'Not shown' }
            end,
            'slots' => order.map do |sl|
              e = entries[sl.id]
              installed = if Inspector.complete?(e)
                            pcs = e['pieces'] || [e]
                            pcs.map { |pc| "#{pc['size']} x #{len_text(pc['length'])}" }.join(' + ')
                          else
                            ''
                          end
              { 'id' => sl.id, 'label' => sl.label, 'group' => group_name(sl), 'installed' => installed,
                'flagged' => (p['flags'] || []).include?(sl.id),
                'entry' => e && { 'role' => e['role'], 'size' => e['size'],
                                  'length_text' => e['length'].to_f > 0 ? len_text(e['length']) : '' } }
            end,
            'roles' => Framing::ROLES, 'sizes' => Framing::SIZES,
            'header_choices' => ['Not shown'] + Framing::SIZES,
            'inspection' => p['last_inspection'],
            'allow_apply' => s['feedback'] == 'fix'
          }
        end

        def send_frame
          g = frame_group or return
          js(@frame, 'load', frame_state(g))
          @prefill = nil
        end

        def save_openings(data)
          g = frame_group or return
          p = Builder.params_of(g)
          errs = []
          ops = data['openings'].each_with_index.map do |o, i|
            name = o['mark'].to_s.strip.empty? ? "Opening row #{i + 1}" : o['mark'].strip
            w = parse_required(o['width_text'], "#{name} RO width", errs)
            h = parse_required(o['height_text'], "#{name} RO height", errs)
            x = parse_required(o['x_text'], "#{name} position", errs)
            head = o['type'] == 'Window' ? parse_required(o['sill_text'], "#{name} head height", errs) : h
            x -= w / 2.0 if x && w && data['pos_mode'] == 'center'
            { 'mark' => o['mark'].to_s.strip.upcase, 'type' => o['type'], 'x' => x, 'width' => w,
              'header' => o['header'] }.merge(h && head ? Framing.opening_from_ro(o['type'], h, head) : {})
          end
          # marks must be unique across the whole model (they match the schedules)
          others = Builder.all_walls.reject { |w| w == g }.flat_map { |w| Builder.params_of(w)['openings'].map { |o| o['mark'] } }
          ops.each { |o| errs << "#{o['mark']} is already used on another wall." if others.include?(o['mark']) }
          if errs.empty?
            test = p.merge('openings' => ops)
            errs = Framing.validate(test, Project.header_table)
          end
          unless errs.empty?
            js(@frame, 'openingErrors', errs)
            return
          end
          operation('Edit Openings') do
            p['openings'] = ops
            p['last_inspection'] = nil
            p['flags'] = []
            Builder.set_params(g, p)
            Builder.rebuild(g)
          end
          send_frame
          js(@frame, 'openingErrors', [])
          js(@frame, 'afterOps', nil)
        end

        # Parses and stores entries. Returns parse errors {slot_id => msg}.
        def store_entries(g, raw)
          p = Builder.params_of(g)
          old = p['entries'] || {}
          errs = {}
          entries = {}
          (raw || {}).each do |id, e|
            len = e['length'].to_s.strip.empty? ? 0.0 : Framing.parse_len(e['length'])
            if len.nil?
              errs[id] = "Couldn't read the cut length \"#{e['length']}\". Try 92 5/8 or 7' 8-5/8\"."
              len = 0.0
            end
            entries[id] = { 'role' => e['role'].to_s, 'size' => e['size'].to_s, 'length' => len }
          end
          changed = (entries.keys | old.keys).reject { |id| entries[id] == old[id] }
          p['entries'] = entries
          p['flags'] = (p['flags'] || []) - changed
          if p['last_inspection']
            p['last_inspection']['issues'] = p['last_inspection']['issues'].reject { |i| changed.include?(i['slot_id']) }
          end
          Builder.set_params(g, p)
          errs
        end

        def save_entries(raw)
          g = frame_group or return
          errs = {}
          operation('Install Framing Members') do
            errs = store_entries(g, raw)
            Builder.rebuild(g)
          end
          js(@frame, 'entryErrors', errs)
        end

        def request_inspection(raw)
          g = frame_group or return
          operation('Request Inspection') do
            store_entries(g, raw) if raw
            inspect_group(g)
          end
          send_frame
        end

        # Runs an inspection on one wall at the instructor's feedback level,
        # flags errors red in the model and logs the attempt.
        def inspect_group(g)
          Builder.refresh_corner_needs(Builder.params_of(g)['level'])
          level = Project.settings['feedback']
          p = Builder.params_of(g)
          full = Inspector.inspect_wall(p, p['entries'], level: 'fix', table: Project.header_table, student_layout: Project.settings['student_layout'])
          res = Inspector.inspect_wall(p, p['entries'], level: level, table: Project.header_table, student_layout: Project.settings['student_layout'])
          res['issues'] = res['issues'].map(&:to_h)
          p['flags'] = level == 'count' ? [] : full['issues'].reject { |i| i.message.start_with?('Not filled') }.map(&:slot_id)
          p['last_inspection'] = res
          Builder.set_params(g, p)
          Builder.rebuild(g)
          Project.log_inspection('wall' => p['id'], 'correct' => full['correct'], 'total' => full['total'],
                                 'wrong' => full['wrong'], 'blank' => full['blank'])
          res
        end

        def zoom(slot_id)
          g = frame_group or return
          Builder.highlight(g, slot_id)
          js(@frame, 'setStatus', 'Highlighted in yellow in the model. It goes back to normal on the next save.')
        end

        def refresh_frame
          send_frame if @frame&.visible?
        end

        # ---------------- shop drawing ----------------

        def open_shop(group)
          p = Builder.params_of(group)
          s = Project.settings
          inst = Project.instructor? && Project.locked?
          opts = { 'letters' => s['shop_letters'] || inst, 'cutlist' => s['shop_cutlist'] || inst,
                   'elevation' => s['shop_elevation'] || inst }
          html = Shop.html(p, opts, Project.header_table)
          dlg = UI::HtmlDialog.new(dialog_title: "Shop Drawing - #{p['id']}", width: 1080, height: 820,
                                   preferences_key: 'dmacc_wf_shop', style: UI::HtmlDialog::STYLE_DIALOG)
          dlg.set_html(html)
          dlg.show
          dlg
        end

        # ---------------- yard + saw ----------------

        def open_yard
          if @yard&.visible?
            send_yard
            @yard.bring_to_front
            return
          end
          Yard.redraw unless Yard.group
          @yard = make('Framing', 'yard.html', 520, 820, 'yard')
          d = @yard
          y_op = lambda do |name, &blk|
            operation(name) { Yard.change(&blk) }
            send_yard
          end
          d.add_action_callback('ready') { |_c, _a| send_yard }
          d.add_action_callback('set_stock') { |_c, a| id = JSON.parse(a)['id']; y_op.call('Choose Stock') { |y| y['stock'] = id }; activate_tool }
          d.add_action_callback('set_cut') do |_c, a|
            t = JSON.parse(a)['text'].to_s.strip
            if t.empty? || %w[full f 0 -].include?(t.downcase)
              y_op.call('Clear Saw Stop') { |y| y['cut'] = nil }
            elsif (len = Framing.parse_len(t)) && len > 0
              activate_tool
              @tool.set_cut(len)
              send_yard
            else
              js(d, 'setStatus', "Couldn't read that length - try 81 or 6' 9\".")
            end
          end
          d.add_action_callback('toggle_offcuts') { |_c, a| on = JSON.parse(a)['on']; y_op.call('Offcuts First') { |y| y['use_offcuts'] = on } }
          d.add_action_callback('take') do |_c, a|
            err = nil
            y_op.call('Pick Up Piece') { |y| y['hand'] = nil; _, err = YardLogic.take(y, JSON.parse(a)['id']) }
            js(d, 'setStatus', err) if err
            activate_tool
          end
          d.add_action_callback('set_down') { |_c, _a| y_op.call('Set Down') { |y| y['hand'] = nil } }
          d.add_action_callback('discard') { |_c, a| y_op.call('Scrap Piece') { |y| YardLogic.discard(y, JSON.parse(a)['id']) } }
          d.add_action_callback('tool') { |_c, _a| activate_tool }
          d.add_action_callback('dtp') do |_c, _a|
            activate_tool
            @tool.set_mode('dtp')
            top_view
            send_yard
          end
          d.add_action_callback('check_interlock') do |_c, _a|
            @show_interlock = true
            send_yard
          end
          d.add_action_callback('mode') do |_c, a|
            activate_tool
            @tool.set_mode(JSON.parse(a)['mode'])
            send_yard
          end
          d.add_action_callback('inspect') do |_c, _a|
            g = focus_group or next
            operation('Request Inspection') { inspect_group(g) }
            send_yard
            refresh_frame
          end
          d.add_action_callback('shop') { |_c, _a| (g = focus_group) && open_shop(g) }
          d.add_action_callback('openings') { |_c, _a| (g = focus_group) && open_frame(g) }
          d.add_action_callback('zoom') do |_c, a|
            g = focus_group or next
            Builder.highlight(g, JSON.parse(a)['slot'])
          end
          d.add_action_callback('restock') do |_c, _a|
            if Project.instructor?
              operation('Restock Yard') { Yard.restock }
              send_yard
            end
          end
          d.show
        end

        def tool
          @tool
        end

        def activate_tool
          klass = Project.settings['guided'] ? GuidedTool : InstallTool
          @tool = klass.new unless @tool.instance_of?(klass)
          Sketchup.active_model.select_tool(@tool)
        end

        def focus_wall(id)
          @focus_wall = id
          refresh_yard
        end

        def focus_group
          g = @focus_wall && Builder.find_wall(@focus_wall)
          g ||= Builder.selected_walls.first || Builder.all_walls.first
          @focus_wall = g && Builder.params_of(g)['id']
          g
        end

        def building_state
          g = focus_group
          return nil unless g
          level = Builder.params_of(g)['level']
          walls = Builder.level_walls(level)
          return nil if walls.empty?
          order = Builder.dtp_order.select { |id| walls.any? { |w| Builder.params_of(w)['id'] == id } }
          checks = Builder.interlock(level)
          { 'level' => level, 'walls' => walls.size, 'placed' => order, 'blockers' => Builder.dtp_blockers(level),
            'joints' => checks.size, 'ok' => checks.count { |c| c['ok'] },
            'results' => @show_interlock ? checks.map { |c| { 'ok' => c['ok'], 'text' => c['text'] } } : nil }
        end

        def top_view
          Views.plan(Builder.all_walls.map { |w| w.transformation.origin.z }.min.to_f)
        end

        def refresh_yard
          send_yard if @yard&.visible?
        end

        def wall_state(g)
          return nil unless g
          p = Builder.params_of(g)
          slots = Builder.work_slots(p)
          framed = slots.count { |s| Inspector.slot_done?(s, (p['entries'] || {})[s.id]) }
          li = p['last_inspection']
          ws = Builder.work_slots(p)
          e = p['entries'] || {}
          done = ->(list) { list.count { |sl| Inspector.slot_done?(sl, e[sl.id]) } }
          plates = ws.select { |sl| sl.phase == 'plates' }
          unit = ws.select { |sl| sl.phase == 'opening' }
          com = ws.select { |sl| sl.phase == 'commons' }
          dtp = ws.select { |sl| sl.phase == 'dtp' }
          steps = [
            [STEP_NAMES[0], "#{done.call(plates)} of #{plates.size} cut and set", done.call(plates) == plates.size],
            [STEP_NAMES[1], "#{p['openings'].size} opening#{p['openings'].size == 1 ? '' : 's'} laid out", done.call(plates) == plates.size && (p['openings'].any? || done.call(com) > 0)],
            [STEP_NAMES[2], unit.empty? ? 'no openings' : "#{done.call(unit)} of #{unit.size} pieces", unit.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }],
            [STEP_NAMES[3], "#{(p['marks'] || []).size} marks, #{done.call(com)} of #{com.size} nailed", com.any? && com.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }],
            [STEP_NAMES[4], dtp.empty? ? 'single top plate' : (done.call(dtp) == dtp.size ? 'on' : 'after every wall stands (building step below)'), dtp.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }]
          ]
          { 'id' => p['id'], 'type' => p['type'], 'level' => p['level'], 'framed' => framed, 'total' => slots.size,
            'steps' => steps.map { |n, t, ok| { 'name' => n, 'text' => t, 'done' => ok } },
            'inspection' => li && { 'summary' => li['summary'], 'passed' => li['correct'] == li['total'],
                                    'issues' => li['issues'] } }
        end

        def send_yard
          y = Yard.data
          fmt = ->(pc) { pc.merge('length_text' => len_text(pc['length'])) }
          h = YardLogic.hand(y)
          js(@yard, 'load', {
               'wall' => wall_state(focus_group),
               'mode' => (@tool&.mode || :nail).to_s,
               'guided' => !!Project.settings['guided'],
               'building' => building_state,
               'stock' => y['stock'], 'cut_text' => y['cut'] ? len_text(y['cut']) : '',
               'use_offcuts' => !!y['use_offcuts'],
               'hand' => h && fmt.call(h),
               'cart' => y['cart'].reject { |c| h && c['id'] == h['id'] }.map(&fmt),
               'piles' => y['piles'].sort_by { |pl| [Framing::ACTUAL[pl['size']], pl['label'].include?('precut') ? 0 : 1, pl['length']] },
               'offcuts' => y['offcuts'].sort_by { |o| [o['size'], -o['length']] }.map(&fmt),
               'stats' => Yard.stats,
               'kerf_text' => Framing.fmt_in(Project.settings['kerf'] || YardLogic::KERF),
               'instructor' => Project.instructor? && Project.locked?
             })
        end

        # ---------------- project setup ----------------

        def open_setup
          if @setup&.visible?
            send_setup
            @setup.bring_to_front
            return
          end
          @setup = make('Wall Framer - Project Setup', 'setup.html', 900, 760, 'setup')
          d = @setup
          d.add_action_callback('ready') { |_c, _a| send_setup }
          d.add_action_callback('close') { |_c, _a| d.close }
          d.add_action_callback('save_setup') { |_c, a| save_setup(JSON.parse(a)) }
          d.add_action_callback('unlock') do |_c, a|
            ok = Project.unlock(JSON.parse(a)['pw'])
            send_setup
            js(d, 'setStatus', ok ? 'Unlocked.' : 'Wrong password.')
          end
          d.add_action_callback('set_password') do |_c, a|
            if Project.instructor?
              pw = JSON.parse(a)['pw']
              Project.set_password(pw)
              Project.unlock(pw) unless pw.to_s.empty?
              send_setup
              js(d, 'setStatus', pw.to_s.empty? ? 'Lock removed.' : 'Password set. Save the model to keep it.')
            end
          end
          d.show
        end

        def send_setup
          dat = Project.data
          js(@setup, 'load', {
               'levels' => dat['levels'].map { |l| { 'name' => l['name'], 'elev_text' => len_text(l['elev']) } },
               'wall_types' => dat['wall_types'].map { |t| t.merge('height_text' => len_text(t['height'])) },
               'header_table' => dat['header_table'].map { |w, s| { 'width_text' => w.to_f >= 9999 ? 'any' : len_text(w), 'size' => s } },
               'settings' => dat['settings'],
               'kerf_text' => Framing.fmt_in(dat['settings']['kerf'] || YardLogic::KERF),
               'feedback_levels' => Inspector::LEVELS.to_a,
               'sizes' => Framing::SIZES,
               'instructor' => Project.instructor?,
               'locked' => Project.locked?
             })
        end

        def save_setup(data)
          s = Project.settings
          unless Project.instructor? || s['students_edit_setup']
            js(@setup, 'showErrors', ['Setup is locked by your instructor.'])
            return
          end
          errs = []
          levels = data['levels'].map do |l|
            name = l['name'].to_s.strip
            errs << 'Every level needs a name.' if name.empty?
            { 'name' => name, 'orig' => l['orig'].to_s, 'elev' => parse_required(l['elev_text'], "#{name} elevation", errs) }
          end
          types = data['wall_types'].map do |t|
            name = t['name'].to_s.strip
            errs << 'Every wall type needs a name.' if name.empty?
            { 'name' => name, 'orig' => t['orig'].to_s, 'stud' => t['stud'], 'spacing' => t['spacing'].to_f,
              'height' => parse_required(t['height_text'], "#{name} height", errs),
              'top_plates' => t['top_plates'].to_i, 'function' => t['function'], 'bearing' => t['bearing'] == 'true' }
          end
          errs << 'Need at least one level.' if levels.empty?
          errs << 'Need at least one wall type.' if types.empty?
          errs << 'Level names must be unique.' if levels.map { |l| l['name'] }.uniq.size != levels.size
          errs << 'Wall type names must be unique.' if types.map { |t| t['name'] }.uniq.size != types.size
          types.each do |t|
            next unless t['height']
            errs << "#{t['name']}: overall height is too short." if Framing.stud_length(t) < 24
          end
          used_types = Builder.all_walls.map { |w| Builder.params_of(w)['type'] }.uniq
          used_levels = Builder.all_walls.map { |w| Builder.params_of(w)['level'] }.uniq
          kept_t = types.map { |t| t['orig'].empty? ? t['name'] : t['orig'] }
          kept_l = levels.map { |l| l['orig'].empty? ? l['name'] : l['orig'] }
          (used_types - kept_t).each { |t| errs << "Wall type #{t} is used by walls - can't delete it." }
          (used_levels - kept_l).each { |l| errs << "Level #{l} has walls on it - can't delete it." }

          hdr = nil
          if Project.instructor? && data['header_table']
            hdr = data['header_table'].map do |h|
              w = h['width_text'].to_s.strip.downcase == 'any' ? 9999.0 : parse_required(h['width_text'], 'Header table width', errs)
              [w, h['size']]
            end
            errs << 'Header table needs at least one row.' if hdr.empty?
          end
          unless errs.empty?
            js(@setup, 'showErrors', errs.uniq)
            return
          end

          operation('Project Setup') do
            Project.update do |d|
              d['levels'] = levels.map { |l| { 'name' => l['name'], 'elev' => l['elev'] } }
              d['wall_types'] = types.map { |t| t.reject { |k, _| k == 'orig' } }
              d['header_table'] = hdr.sort_by(&:first) if hdr
              if Project.instructor? && data['settings']
                st = data['settings'].dup
                k = Framing.parse_len(st.delete('kerf_text'))
                st['kerf'] = k if k && k >= 0 && k < 0.5
                d['settings'] = d['settings'].merge(st)
              end
            end
            # renames + propagate changes to existing walls
            Builder.all_walls.each do |w|
              p = Builder.params_of(w)
              lv = levels.find { |l| (l['orig'].empty? ? l['name'] : l['orig']) == p['level'] }
              ty = types.find { |t| (t['orig'].empty? ? t['name'] : t['orig']) == p['type'] }
              p['level'] = lv['name'] if lv
              Builder.apply_type(p, ty.reject { |k, _| k == 'orig' }) if ty
              Builder.set_params(w, p)
              if lv
                o = w.transformation.origin
                dz = lv['elev'].to_f - o.z.to_f
                w.transform!(Geom::Transformation.translation([0, 0, dz])) if dz.abs > 1e-6
              end
              Builder.rebuild(w)
            end
          end
          send_setup
          js(@setup, 'showErrors', [])
          send_frame if @frame&.visible?
        end

        # ---------------- takeoff ----------------

        def open_takeoff
          if @takeoff&.visible?
            send_takeoff
            @takeoff.bring_to_front
            return
          end
          @takeoff = make('Wall Framer - Takeoff', 'takeoff.html', 760, 680, 'takeoff')
          d = @takeoff
          d.add_action_callback('ready') { |_c, _a| send_takeoff }
          d.add_action_callback('save_takeoff') do |_c, a|
            rows = JSON.parse(a)['rows']
            Project.update { |dd| dd['takeoff'] = rows }
            js(d, 'setStatus', 'Saved.')
          end
          d.add_action_callback('check_takeoff') { |_c, a| check_takeoff(JSON.parse(a)['rows']) }
          d.add_action_callback('auto_cutlist') { |_c, _a| WallFramer.export_cut_list }
          d.show
        end

        def send_takeoff
          s = Project.settings
          js(@takeoff, 'load', { 'rows' => Project.data['takeoff'] || [], 'sizes' => Framing::SIZES,
                                 'allow_auto' => s['auto_cutlist'] || Project.instructor?,
                                 'wall_count' => Builder.all_walls.size })
        end

        def expected_cut_list
          table = Project.header_table
          Framing.cut_list(Builder.expected_members_all)
        end

        def check_takeoff(rows)
          level = Project.settings['takeoff_feedback']
          res = Takeoff.check(rows, expected_cut_list, level: level)
          Project.update do |d|
            d['takeoff'] = rows
            d['takeoff_log'] << { 'time' => Time.now.strftime('%Y-%m-%d %H:%M'), 'score' => res['score'] }
            d['takeoff_score'] = res['score']
          end
          js(@takeoff, 'result', res)
        end
      end
    end
  end
end
