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
          errs << "#{what}: couldn't read \"#{text}\". Try 36 or 3' 0\" (feet with ', inches with \")." if v.nil?
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

        def open_frame(wall, row: nil, header_table: false)
          @frame_wall = Builder.params_of(wall)['id']
          @goto_row = row
          @show_hdr = header_table
          if @frame&.visible?
            send_frame
            @frame.bring_to_front
            return
          end
          @frame = make('Frame Wall', 'frame.html', 900, 720, 'frame')
          d = @frame
          if Builder.on_table?(wall) && !@docked && d.respond_to?(:set_position)
            d.set_size(820, 700) if d.respond_to?(:set_size)
            d.set_position(10, 110)
            @docked = true
          end
          d.add_action_callback('ready') { |_c, _a| send_frame }
          d.add_action_callback('save_openings') { |_c, a| save_openings(JSON.parse(a)) }
          d.add_action_callback('inspect') { |_c, _a| inspect_focus_level }
          d.add_action_callback('frame_next') { |_c, _a| frame_next }
          d.add_action_callback('continue') do |_c, _a|
            g = frame_group or next
            focus_wall(Builder.params_of(g)['id'])
            activate_tool
            Views.table(g) if Builder.on_table?(g) # back to looking straight down on the table
            Sketchup.status_text = "Back to framing #{Builder.params_of(g)['id']} - click a piece or type in the cut list."
          end
          d.add_action_callback('shop') { |_c, _a| (g = frame_group) && open_shop(g) }
          d.add_action_callback('zoom') { |_c, a| zoom(JSON.parse(a)['slot']) }
          d.add_action_callback('set_row') { |_c, a| set_row(JSON.parse(a)) }
          d.add_action_callback('build_stand') { |_c, _a| build_and_stand }
          d.add_action_callback('stand_up') do |_c, _a|
            g = frame_group or next
            activate_tool
            @tool.stand_up(g) if @tool.respond_to?(:stand_up) && Builder.on_table?(g)
            send_frame
          end
          d.show
        end

        # One cut-list row typed in: store it, nail what can go in, send the table back.
        def set_row(data)
          g = frame_group or return
          onto_table(g)
          before = Builder.stage(Builder.params_of(g))
          err = nil
          operation('Cut List') { err = CutList.set(g, data['key'], data['v'], data['size']) }
          g = frame_group or return
          p = Builder.params_of(g)
          js(@frame, 'rowsUpdate', 'rows' => CutList.rows(p), 'key' => data['key'], 'err' => err,
                                   'stage' => Builder.stage(p), 'on_table' => Builder.on_table?(g), 'next' => next_hint(p),
                                   'ready_to_build' => ready_to_build?(p))
          @tool.announce(g, before) if @tool.respond_to?(:announce)
          refresh_yard
          Sketchup.active_model.active_view.invalidate
        end

        def ready_to_build?(p)
          p['openings_done'] && CutList.all_filled?(CutList.rows(p))
        end

        # Every row filled: put in anything still waiting, then stand the wall up.
        def build_and_stand
          g = frame_group or return
          operation('Build Wall') { CutList.apply(g) }
          p = Builder.params_of(g)
          if Builder.stage(p) == 'framed'
            activate_tool
            if Builder.on_table?(g) && @tool.respond_to?(:stand_up)
              @tool.stand_up(g)
            end
            send_frame
            js(@frame, 'setStatus', "#{p['id']} is built and standing on its line.")
          else
            send_frame
            left = CutList.rows(p).reject { |r| %w[placed none].include?(r['state']) }
            js(@frame, 'setStatus', "Not built yet - still to fill in or fix: #{left.first(3).map { |r| r['note'].to_s.empty? ? r['label'] : "#{r['label']} (#{r['note']})" }.join('; ')}#{left.size > 3 ? " and #{left.size - 3} more" : ''}.")
          end
          refresh_yard
          Sketchup.active_model.active_view.invalidate
        end

        def next_hint(p)
          case Builder.stage(p)
          when 'corners' then 'Set the plan corners first (Corners tool).'
          when 'plates' then 'Next: cut the bottom and top plates.'
          when 'openings' then 'Next: enter the openings from the plans (Openings, below the plates), or click No openings in this wall.'
          when 'units' then 'Next: frame each opening - kings, jacks, header, sill.'
          when 'commons' then 'Next: corners, stud spacing and common studs.'
          when 'cripples' then 'Next: cripples under the sills and header blocks - they land on your layout.'
          else Builder.on_table?(Builder.find_wall(p['id'])) ? 'Framed. Click Build and stand wall, then Frame next wall.' : 'Framed.'
          end
        end

        def frame_group
          g = Builder.find_wall(@frame_wall)
          UI.messagebox("Wall #{@frame_wall} isn't in the model anymore.") unless g
          g
        end

        STEP_NAMES = ['1. Plates', '2. Openings', '3. Frame openings (kings, jacks, header, sill)', '4. Corners + studs (and tee backing)',
                      '6. Double top plate', '5. Cripples + header blocks (on your layout)'].freeze

        def frame_state(group)
          p = Builder.params_of(group)
          {
            'wall' => { 'id' => p['id'], 'type' => p['type'], 'level' => p['level'], 'stud' => p['stud'],
                        'spacing' => p['spacing'], 'length_text' => len_text(p['length']),
                        'height_text' => len_text(p['height']) },
            'pos_mode' => 'center',
            'hdr_flat' => Framing::HDR_FLAT,
            'openings' => p['openings'].map do |o|
              { 'mark' => o['mark'], 'type' => o['type'],
                'x_text' => len_text(Framing.layout_dist(p, o['x'].to_f + o['width'].to_f / 2.0)),
                'width_text' => len_text(o['width']), 'height_text' => len_text(Framing.ro_height(o)),
                'sill_text' => o['type'] == 'Window' ? len_text(o['height']) : '',
                'header' => Framing.header_choice(o['header']),
                'plies' => o['plies'] }
            end,
            'header_choices' => Framing.header_choices,
            'inspection' => p['last_inspection'],
            'cutlist' => CutList.rows(p),
            'corner_opts' => CutList::CORNERS, 'backing_opts' => CutList::BACKING, 'oc_opts' => CutList::OCS,
            'stud_sizes' => %w[2x4 2x6],
            'stage' => Builder.stage(p), 'next' => next_hint(p),
            'on_table' => Builder.on_table?(group),
            'ready_to_build' => ready_to_build?(p),
            'header_tables' => Project.sfpa_tables,
            'start_side' => Framing.from_end?(p) ? 'right' : 'left',
            'goto_row' => @goto_row,
            'show_header_table' => @show_hdr
          }
        end

        def send_frame
          g = frame_group or return
          js(@frame, 'load', frame_state(g))
          @goto_row = nil
          @show_hdr = nil
        end

        def save_openings(data)
          g = frame_group or return
          onto_table(g)
          p = Builder.params_of(g)
          len = p['length'].to_f
          errs = []
          ops = data['openings'].each_with_index.map do |o, i|
            name = o['mark'].to_s.strip.empty? ? "Opening row #{i + 1}" : o['mark'].strip
            w = parse_required(o['width_text'], "#{name} RO width", errs)
            h = parse_required(o['height_text'], "#{name} RO height", errs)
            d = parse_required(o['x_text'], "#{name} position", errs)
            head = o['type'] == 'Window' ? parse_required(o['sill_text'], "#{name} head height", errs) : h
            # position is from the arrow end, to the center or to the near edge of the RO
            x = nil
            if d && w
              near = data['pos_mode'] == 'center' ? d - w / 2.0 : d
              x = Framing.from_end?(p) ? len - near - w : near
            end
            hdr = Framing.header_from_choice(o['header'])
            errs << "#{name}: pick the header from the plans or general notes - if it isn't called out, use the Header table." unless hdr
            plies = o['plies'].to_i
            errs << "#{name}: pick the header plies from the plans (the (2) in \"(2) 2x10\")." if Framing::SIZES.include?(hdr) && plies.zero?
            mark = o['mark'].to_s.strip.upcase
            op = { 'mark' => mark, 'type' => o['type'], 'x' => x, 'width' => w,
                   'header' => hdr }.merge(h && head ? Framing.opening_from_ro(o['type'], h, head) : {})
            op['plies'] = plies if Framing::SIZES.include?(hdr)
            old = p['openings'].find { |q| q['mark'] == mark }
            op['jacks'] = old['jacks'] if old && old['jacks'] && old['header'] == hdr
            op
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
          before = Builder.stage(p)
          operation('Edit Openings') do
            p = Builder.params_of(g)
            p['openings'] = ops
            p['last_inspection'] = nil
            p['flags'] = []
            p['openings_done'] = true
            Builder.set_params(g, p)
            Builder.rebuild(g)
          end
          js(@frame, 'openingErrors', [])
          operation('Cut List') { CutList.apply(g) } # rows already typed for these openings go in
          Sketchup.status_text = ops.empty? ? "#{p['id']}: no openings - on to the studs." : "#{p['id']}: openings saved. Fill in the cut list: kings, jacks, header, sill."
          @tool.announce(g, before) if @tool.respond_to?(:announce) && Builder.find_wall(p['id'])
          send_frame
          js(@frame, 'afterOps', nil)
          refresh_yard
          Sketchup.active_model.active_view.invalidate
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
          # a catch = something nailed in wrong (or a bad splice); a piece that just isn't in yet isn't a mistake
          ents = p['entries'] || {}
          caught = full['issues'].select { |i| Inspector.complete?(ents[i.slot_id]) || i.slot_id.to_s.start_with?('SPLICE:') }
          added = Project.log_catches(p['id'], caught.map { |i| { slot_id: i.slot_id, label: i.label, message: i.message } })
          note = added.positive? ? " #{added} mistake#{added == 1 ? '' : 's'} caught by the inspector - logged for grading." : ''
          Project.log_inspection('wall' => p['id'], 'correct' => full['correct'], 'total' => full['total'],
                                 'wrong' => full['wrong'], 'blank' => full['blank'], 'summary' => "#{res['summary']}#{note}")
          res['summary'] = "#{res['summary']}#{note}"
          res
        end

        # A framing inspection covers a whole level: every wall framed, standing, double plates on.
        # Returns a message for the student.
        def inspect_level(level)
          left = Builder.level_inspection_blockers(level)
          unless left.empty?
            return "Inspection opens when all framing on #{level} is done - every wall framed and standing, " \
                   "double top plates on. Still open: #{left.first(5).join(', ')}#{left.size > 5 ? ", +#{left.size - 5} more" : ''}."
          end
          ws = Builder.all_walls.select { |w| Builder.params_of(w)['level'] == level }
          res = nil
          operation("Inspect #{level}") { res = ws.map { |w| inspect_group(w) } }
          return 'Inspection could not run.' unless res
          bad = res.select { |r| r['correct'] != r['total'] }
          laps = lap_problems(level)
          if bad.empty? && laps.empty?
            "#{level} passed inspection - every wall."
          else
            parts = []
            parts << "#{bad.size} of #{res.size} walls have problems (red in the model): #{bad.map { |r| r['wall_id'] || r['summary'].split(':').first }.join(', ')}" unless bad.empty?
            unless laps.empty?
              parts << "double top plates don't lap at #{laps.map { |c| "#{c['joint']['butt']}/#{c['joint']['through']}" }.join(', ')} " \
                       '(the wall that butts gets its double plate first - take the pieces off and set them again in order)'
            end
            "#{level}: #{parts.join('; ')}. Fix them and request again."
          end
        end

        # Corners and tees whose double plates don't lap: logged like any other catch, and the
        # double plate on the butting wall shows red.
        def lap_problems(level)
          laps = Builder.interlock(level).select { |c| c['placed'] && !c['ok'] }
          laps.group_by { |c| c['joint']['butt'] }.each do |wid, cs|
            Project.log_catches(wid, cs.map { |c| { slot_id: "LAP:#{c['joint']['through']}", label: 'Double top plate lap', message: c['text'] } })
            Project.log_inspection('wall' => wid, 'summary' => "#{wid}: double top plate doesn't lap at #{cs.map { |c| c['joint']['through'] }.join(', ')}.")
            g = Builder.find_wall(wid) or next
            p = Builder.params_of(g)
            p['flags'] = ((p['flags'] || []) + ['TP:2']).uniq
            Builder.set_params(g, p)
            Builder.rebuild(g)
          end
          laps
        end

        def inspect_focus_level
          g = focus_group or return 'Place some walls first.'
          msg = inspect_level(Builder.params_of(g)['level'])
          Sketchup.status_text = msg
          js(@yard, 'setStatus', msg) if @yard&.visible?
          js(@frame, 'setStatus', msg) if @frame&.visible?
          refresh_yard
          refresh_frame
          msg
        end

        # Frame Wall form: move on to the next wall in order (stands this one up first if it's framed).
        # Any "open the cut list" button: a wall that hasn't been framed yet goes to the framing
        # table first (same as clicking it with Frame), so nobody frames a standing wall by accident.
        def start_wall(g, header_table: false)
          activate_tool
          if @tool.respond_to?(:to_table?) && @tool.to_table?(g)
            @tool.to_table(g)
            open_frame(g, header_table: true) if header_table
          else
            focus_wall(Builder.params_of(g)['id'])
            open_frame(g, header_table: header_table)
          end
        end

        # Typing into the form for a wall that's still standing unframed: it goes to the table first.
        def onto_table(g)
          activate_tool
          @tool.to_table(g) if @tool.respond_to?(:to_table?) && @tool.to_table?(g)
        end

        def frame_next
          g = frame_group or return
          activate_tool
          if Builder.on_table?(g) && Builder.stage(Builder.params_of(g)) == 'framed' && @tool.respond_to?(:stand_up)
            @tool.stand_up(g)
          end
          nxt = Builder.next_wall_after(g)
          unless nxt
            lv = Builder.params_of(g)['level']
            left = Builder.all_walls.reject { |w| Builder.framed_and_standing?(w) }
            msg = if left.any? { |w| Builder.params_of(w)['level'] == lv }
                    "#{Builder.params_of(left.first)['id']} still needs framing."
                  elsif Builder.level_inspection_blockers(lv).any?
                    "Every wall on #{lv} is framed and standing. Next: Double Top Plates (on the Steps toolbar), then Request Inspection. The next floor opens after that."
                  else
                    "Every wall is framed and standing. Request inspection for #{lv} if you haven't."
                  end
            Sketchup.status_text = msg
            js(@frame, 'setStatus', msg)
            return
          end
          if @tool.respond_to?(:to_table) && @tool.to_table?(nxt)
            @tool.to_table(nxt)
          else
            focus_wall(Builder.params_of(nxt)['id'])
            open_frame(nxt)
          end
          send_frame
        end

        def zoom(slot_id)
          g = frame_group or return
          Builder.highlight(g, slot_id)
          js(@frame, 'setStatus', 'Highlighted in yellow in the model. It goes back to normal on the next save.')
        end

        def refresh_frame
          send_frame if @frame&.visible?
        end

        # Job Notes: inspections, instructor notes, field notes - newest first.
        def job_notes
          d = Project.data
          seen = d['notes_seen_at'].to_f
          items = []
          (d['log'] || []).last(40).each do |l|
            at = l['at'].to_i
            items << { 'kind' => 'Inspection', 'at' => at, 'unseen' => at > seen,
                       'title' => "Inspection - #{l['wall']}",
                       'lines' => [l['summary'] || "#{l['correct']}/#{l['total']} correct"] }
          end
          (d['notes'] || []).each_with_index do |n, i|
            items << { 'kind' => 'Note', 'at' => n['at'].to_f, 'unseen' => n['at'].to_f > seen, 'i' => i,
                       'title' => 'Job note', 'lines' => [n['text']] }
          end
          (d['student_notes'] || []).each_with_index do |n, i|
            items << { 'kind' => 'My note', 'at' => n['at'].to_f, 'unseen' => false, 'mine' => i,
                       'title' => 'Field note', 'lines' => [n['text']] }
          end
          items.sort_by! { |x| -x['at'] }
          items.each { |x| x['when'] = x['at'].positive? ? Time.at(x['at']).strftime('%m/%d %I:%M %p') : ''; x['at'] = x['at'].to_i }
          { 'items' => items, 'unseen' => items.count { |x| x['unseen'] }, 'plans' => plan_notes }
        end

        # What the student took off the plans for each opening (their entries, typos and all).
        def plan_notes
          Builder.all_walls.flat_map do |w|
            p = Builder.params_of(w)
            p['openings'].map do |o|
              head = o['type'] == 'Window' ? ", head height #{len_text(o['height'])}" : ''
              hdr = "header #{Framing.header_label(o)}"
              { 'mark' => o['mark'], 'wall' => p['id'],
                'text' => "#{o['mark']} #{o['type'].downcase} (#{p['id']}) - RO #{len_text(o['width'])} x #{len_text(Framing.ro_height(o))}#{head}, #{hdr}" }
            end
          end.sort_by { |x| x['mark'] }
        end

        def walls_list
          Builder.all_walls.map do |w|
            p = Builder.params_of(w)
            { 'id' => p['id'], 'level' => p['level'], 'type' => p['type'], 'stage' => Builder.stage(p), 'held' => [] }
          end.sort_by { |x| [x['level'], x['id']] }
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

        # ---------------- framing panel ----------------

        def open_yard
          if @yard&.visible?
            send_yard
            @yard.bring_to_front
            return
          end
          @yard = make('Framing', 'yard.html', 520, 820, 'yard')
          d = @yard
          d.add_action_callback('ready') { |_c, _a| send_yard }
          d.add_action_callback('tool') { |_c, _a| activate_tool }
          d.add_action_callback('dtp') do |_c, _a|
            activate_tool
            @tool.set_mode('dtp')
            top_view
            send_yard
          end
          d.add_action_callback('notes_seen') do |_c, _a|
            Project.update { |dd| dd['notes_seen_at'] = Time.now.to_f }
            send_yard
          end
          d.add_action_callback('add_my_note') do |_c, a|
            txt = JSON.parse(a)['text'].to_s.strip
            next if txt.empty?
            operation('Field Note') { Project.update { |dd| (dd['student_notes'] ||= []) << { 'text' => txt, 'at' => Time.now.to_f } } }
            send_yard
          end
          d.add_action_callback('delete_my_note') do |_c, a|
            i = JSON.parse(a)['i'].to_i
            operation('Delete Field Note') { Project.update { |dd| (dd['student_notes'] ||= []).delete_at(i) } }
            send_yard
          end
          d.add_action_callback('post_note') do |_c, a|
            next unless Project.instructor?
            txt = JSON.parse(a)['text'].to_s.strip
            next if txt.empty?
            operation('Post Job Note') { Project.update { |dd| (dd['notes'] ||= []) << { 'text' => txt, 'at' => Time.now.to_f } } }
            send_yard
          end
          d.add_action_callback('delete_note') do |_c, a|
            next unless Project.instructor?
            i = JSON.parse(a)['i'].to_i
            operation('Delete Job Note') { Project.update { |dd| (dd['notes'] ||= []).delete_at(i) } }
            send_yard
          end
          d.add_action_callback('focus') do |_c, a|
            id = JSON.parse(a)['id']
            @tool.focus(id) if @tool.respond_to?(:focus)
            focus_wall(id)
            Sketchup.active_model.active_view.invalidate
          end
          d.add_action_callback('edit_opening') do |_c, a|
            g = focus_group or next
            activate_tool
            mark = JSON.parse(a)['mark']
            next send_yard unless Builder.params_of(g)['openings'].any? { |o| o['mark'] == mark }
            start_wall(g)
            send_yard
          end
          d.add_action_callback('stand_up') do |_c, _a|
            g = focus_group or next
            activate_tool
            @tool.stand_up(g) if @tool.respond_to?(:stand_up)
            send_yard
          end
          d.add_action_callback('to_table') do |_c, _a|
            g = focus_group or next
            activate_tool
            @tool.to_table(g) if @tool.respond_to?(:to_table) && @tool.to_table?(g)
            send_yard
          end
          d.add_action_callback('remove_opening') do |_c, a|
            g = focus_group or next
            activate_tool
            @tool.remove_opening(g, JSON.parse(a)['mark']) if @tool.respond_to?(:remove_opening)
            send_yard
          end
          d.add_action_callback('openings_done') do |_c, _a|
            g = focus_group or next
            start_wall(g)
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
            inspect_focus_level
            send_yard
          end
          d.add_action_callback('shop') { |_c, _a| (g = focus_group) && open_shop(g) }
          d.add_action_callback('openings') { |_c, _a| (g = focus_group) && start_wall(g) }
          d.add_action_callback('zoom') do |_c, a|
            g = focus_group or next
            Builder.highlight(g, JSON.parse(a)['slot'])
          end
          d.show
        end

        def tool
          @tool
        end

        def activate_tool
          @tool = GuidedTool.new unless @tool.instance_of?(GuidedTool)
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
          Views.plan(Builder.all_walls.map { |w| Builder.home(w).origin.z }.min.to_f)
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
          crp = ws.select { |sl| sl.phase == 'cripples' }
          dtp = ws.select { |sl| sl.phase == 'dtp' }
          oc = Builder.open_corners(p)
          steps = [
            ['0. Corners', oc.empty? ? 'set' : "#{oc.size} to settle (Corners tool)", oc.empty?],
            [STEP_NAMES[0], "#{done.call(plates)} of #{plates.size} cut and set", done.call(plates) == plates.size],
            [STEP_NAMES[1], "#{p['openings'].size} opening#{p['openings'].size == 1 ? '' : 's'} laid out", done.call(plates) == plates.size && (p['openings'].any? || done.call(com) > 0)],
            [STEP_NAMES[2], unit.empty? ? 'no openings' : "#{done.call(unit)} of #{unit.size} pieces", unit.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }],
            [STEP_NAMES[3], "#{(p['marks'] || []).size} marks, #{done.call(com)} of #{com.size} nailed", com.any? && com.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }],
            [STEP_NAMES[5], crp.empty? ? 'none on this wall' : "#{done.call(crp)} of #{crp.size} nailed", crp.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }],
            [STEP_NAMES[4], dtp.empty? ? 'single top plate' : (done.call(dtp) == dtp.size ? 'on' : 'after every wall stands (building step below)'), dtp.all? { |sl| Inspector.slot_done?(sl, e[sl.id]) }]
          ]
          { 'id' => p['id'], 'type' => p['type'], 'level' => p['level'], 'framed' => framed, 'total' => slots.size,
            'stage' => Builder.stage(p), 'openings' => p['openings'].size,
            'on_table' => Builder.on_table?(g),
            'editable' => p['openings'].reject { |o| slots.any? { |sl| sl.opening == o['mark'] && Inspector.complete?((p['entries'] || {})[sl.id]) } }
                                       .map { |o| { 'mark' => o['mark'], 'answered' => false } },
            'removable' => if %w[openings units].include?(Builder.stage(p))
                             p['openings'].reject { |o| slots.any? { |sl| sl.opening == o['mark'] && Inspector.complete?((p['entries'] || {})[sl.id]) } }
                                          .map { |o| o['mark'] }
                           else
                             []
                           end,
            'steps' => steps.map { |n, t, ok| { 'name' => n, 'text' => t, 'done' => ok } },
            'inspection' => li && { 'summary' => li['summary'], 'passed' => li['correct'] == li['total'],
                                    'issues' => li['issues'] } }
        end

        def send_yard
          js(@yard, 'load', {
               'wall' => wall_state(focus_group),
               'mode' => (@tool&.mode || :guided).to_s,
               'guided' => true,
               'building' => building_state,
               'rfis' => [],
               'framing_table' => !!Project.settings['framing_table'],
               'notes' => job_notes,
               'walls' => walls_list,
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
          d.add_action_callback('import_sfpa') do |_c, _a|
            next js(d, 'showErrors', ['Only the instructor can import header tables.']) unless Project.instructor?
            path = UI.openpanel('Header tables (WallFramer_SFPA_headers.json)', '', 'Header tables|*.json||')
            next unless path
            begin
              operation('Import Header Tables') { Project.import_sfpa(path) }
              send_setup
              js(d, 'setStatus', 'Header tables imported. The Header table button in the Frame Wall form shows them now.')
            rescue StandardError => e
              js(d, 'showErrors', ["Couldn't import that file: #{e.message}"])
            end
          end
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
               'span_table' => (dat['span_table'] || []).map { |r| r.merge('span_text' => len_text(r['span'])) },
               'span_conditions' => dat['span_conditions'].to_s,
               'sfpa' => (t = Project.sfpa_tables) && t['source'],
               'settings' => dat['settings'],
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
          spans = nil
          if Project.instructor? && data['span_table']
            spans = data['span_table'].map do |r|
              { 'size' => r['size'], 'plies' => r['plies'].to_i, 'jacks' => [r['jacks'].to_i, 1].max,
                'span' => parse_required(r['span_text'], "Span table #{r['plies']}-#{r['size']} max span", errs) }
            end
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
              d['span_table'] = spans.sort_by { |r| [Framing::ACTUAL[r['size']].to_f, r['plies'], r['span'].to_f] } if spans
              d['span_conditions'] = data['span_conditions'].to_s.strip if Project.instructor? && data.key?('span_conditions')
              if Project.instructor? && data['settings']
                st = data['settings'].dup
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
              Builder.stand_up(w) if lv && Builder.on_table?(w)
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
