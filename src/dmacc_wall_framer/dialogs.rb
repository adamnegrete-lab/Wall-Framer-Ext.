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

        def open_frame(wall, center: nil, row: nil)
          @frame_wall = Builder.params_of(wall)['id']
          @prefill = center
          @goto_row = row
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
          d.add_action_callback('save_entries') { |_c, a| save_entries(JSON.parse(a)['entries']) }
          d.add_action_callback('inspect') { |_c, _a| Project.settings['guided'] ? inspect_focus_level : request_inspection(nil) }
          d.add_action_callback('frame_next') { |_c, _a| frame_next }
          d.add_action_callback('continue') do |_c, _a|
            g = frame_group or next
            focus_wall(Builder.params_of(g)['id'])
            activate_tool
            Views.table(g) if Builder.on_table?(g) # back to looking straight down on the table
            Sketchup.status_text = "Back to framing #{Builder.params_of(g)['id']} - click a piece or type in the cut list."
          end
          d.add_action_callback('go_frame') { |_c, _a| open_yard; Sketchup.active_model.select_tool(InstallTool.new) }
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
            js(@frame, 'setStatus', "Not built yet - check: #{left.first(3).map { |r| "#{r['label']} (#{r['note']})" }.join('; ')}")
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

        def group_name(slot)
          if slot.opening then "Opening #{slot.opening}"
          elsif slot.kind == :horizontal then 'Plates'
          else 'Studs on layout'
          end
        end

        STEP_NAMES = ['1. Plates', '2. Lay out openings', '3. Frame openings (kings, jacks, header, sill)', '4. Lay out + nail studs (and tee backing)',
                      '6. Double top plate', '5. Cripples + header blocks (on your layout)'].freeze

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
            'pos_mode' => 'center',
            'guided' => !!s['guided'],
            'hdr_flat' => Framing::HDR_FLAT, 'hdr_rfi' => Framing::HDR_RFI,
            'prefill' => @prefill && { 'x_text' => len_text(Framing.layout_dist(p, @prefill)) },
            'openings' => p['openings'].map do |o|
              ans = o['rfi_new'] && (Project.data['rfis'] || []).find { |r| r['n'] == o['rfi_new'] }
              { 'mark' => o['mark'], 'type' => o['type'],
                'x_text' => len_text(Framing.layout_dist(p, o['x'].to_f + o['width'].to_f / 2.0)),
                'width_text' => len_text(o['width']), 'height_text' => len_text(Framing.ro_height(o)),
                'sill_text' => o['type'] == 'Window' ? len_text(o['height']) : '',
                'header' => ans ? Framing::HDR_PICK : Framing.header_choice(o['header']),
                'plies' => ans ? nil : o['plies'],
                'rfi_note' => ans && "RFI ##{ans['n']} answered: #{ans['answer']} - pick the header and plies from the answer, then save." }
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
            'header_choices' => Framing.header_choices,
            'inspection' => p['last_inspection'],
            'allow_apply' => s['feedback'] == 'fix',
            'cutlist' => CutList.rows(p),
            'corner_opts' => CutList::CORNERS, 'backing_opts' => CutList::BACKING, 'oc_opts' => CutList::OCS,
            'stud_sizes' => %w[2x4 2x6],
            'stage' => Builder.stage(p), 'next' => next_hint(p),
            'on_table' => Builder.on_table?(group),
            'ready_to_build' => ready_to_build?(p),
            'header_tables' => Project.sfpa_tables,
            'start_side' => Framing.from_end?(p) ? 'right' : 'left',
            'goto_row' => @goto_row
          }
        end

        def send_frame
          g = frame_group or return
          js(@frame, 'load', frame_state(g))
          @prefill = nil
          @goto_row = nil
        end

        def save_openings(data)
          g = frame_group or return
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
            errs << "#{name}: pick the header from the plans or general notes - if it isn't called out, submit an RFI." unless hdr
            plies = o['plies'].to_i
            errs << "#{name}: pick the header plies from the plans (the (2) in \"(2) 2x10\")." if Framing::SIZES.include?(hdr) && plies.zero?
            mark = o['mark'].to_s.strip.upcase
            op = { 'mark' => mark, 'type' => o['type'], 'x' => x, 'width' => w,
                   'header' => hdr }.merge(h && head ? Framing.opening_from_ro(o['type'], h, head) : {})
            op['plies'] = plies if Framing::SIZES.include?(hdr)
            # an RFI still out (or answered but not updated yet) stays with the opening
            old = p['openings'].find { |q| q['mark'] == mark }
            %w[jacks rfi rfi_new].each { |k| op[k] = old[k] if old && old['header'] == hdr && hdr == Framing::RFI && old.key?(k) }
            op['jacks'] = old['jacks'] if old && old['jacks'] && old['header'] == hdr
            op
          end
          # marks must be unique across the whole model (they match the schedules)
          others = Builder.all_walls.reject { |w| w == g }.flat_map { |w| Builder.params_of(w)['openings'].map { |o| o['mark'] } }
          ops.each { |o| errs << "#{o['mark']} is already used on another wall." if others.include?(o['mark']) }
          # an opening that's already framed can't move or disappear from here
          e = p['entries'] || {}
          framed = Builder.work_slots(p).select { |sl| sl.opening && Inspector.complete?(e[sl.id]) }.map(&:opening).uniq
          framed = [] if Project.settings['guided'] # the cut list pulls and re-nails them where the opening moved
          framed.each do |mk|
            was = p['openings'].find { |o| o['mark'] == mk }
            now = ops.find { |o| o['mark'] == mk }
            same = now && %w[type x width height sill header plies].all? { |k| (was[k].is_a?(Numeric) ? (was[k].to_f - now[k].to_f).abs < 1e-3 : was[k] == now[k]) }
            errs << "#{mk} is already framed - pull its pieces with the Demo tool before changing or removing it." unless same
          end
          if errs.empty?
            test = p.merge('openings' => ops)
            errs = Framing.validate(test, Project.header_table)
          end
          unless errs.empty?
            js(@frame, 'openingErrors', errs)
            return
          end
          guided = Project.settings['guided']
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
          unsent = ops.find { |op| op['header'] == Framing::RFI && !op['rfi'] }
          held = ops.select { |op| op['header'] == Framing::RFI }.map { |op| op['mark'] }
          if guided
            operation('Cut List') { CutList.apply(g) } # rows already typed for these openings go in
            Sketchup.status_text = if ops.empty? then "#{p['id']}: no openings - on to the studs."
                                   elsif held.any? then "#{p['id']}: openings saved. #{held.join(', ')} on hold for an RFI - frame the others."
                                   else "#{p['id']}: openings saved. Fill in the cut list: kings, jacks, header, sill."
                                   end
            @tool.announce(g, before) if @tool.respond_to?(:announce) && Builder.find_wall(p['id'])
            send_frame
            js(@frame, 'afterOps', nil)
          else
            send_frame
            js(@frame, 'afterOps', nil)
          end
          refresh_yard
          Sketchup.active_model.active_view.invalidate
          open_rfi(p['id'], unsent['mark']) if unsent
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
          if bad.empty?
            "#{level} passed inspection - every wall."
          else
            "#{level}: #{bad.size} of #{res.size} walls have problems (red in the model): #{bad.map { |r| r['wall_id'] || r['summary'].split(':').first }.join(', ')}. Fix them and request again."
          end
        end

        def inspect_focus_level
          g = focus_group or return 'Place some walls first.'
          unless Project.settings['guided'] # advanced mode: one wall at a time, as before
            operation('Request Inspection') { inspect_group(g) }
            refresh_yard
            refresh_frame
            return Builder.params_of(g)['last_inspection'] && Builder.params_of(g)['last_inspection']['summary']
          end
          msg = inspect_level(Builder.params_of(g)['level'])
          Sketchup.status_text = msg
          js(@yard, 'setStatus', msg) if @yard&.visible?
          js(@frame, 'setStatus', msg) if @frame&.visible?
          refresh_yard
          refresh_frame
          msg
        end

        # Frame Wall form: move on to the next wall in order (stands this one up first if it's framed).
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
                    "Every wall on #{lv} is framed and standing. Next: double top plates (Framing Panel), then request inspection. The next floor opens after that."
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

        # ---------------- RFI form ----------------

        def open_rfi(wall_id, mark)
          g = Builder.find_wall(wall_id) or return
          p = Builder.params_of(g)
          o = p['openings'].find { |x| x['mark'] == mark } or return
          @rfi.close if @rfi&.visible?
          d = make('Request for Information', 'rfi.html', 760, 560, 'rfi')
          @rfi = d
          title = Sketchup.active_model.title.to_s
          d.add_action_callback('ready') do |_c, _a|
            js(d, 'load', { 'n' => Project.data['rfis'].size + 1, 'project' => title.empty? ? '(unsaved model)' : title,
                            'date' => Time.now.strftime('%m/%d/%Y'), 'wall' => "#{wall_id} (#{p['type']})", 'mark' => mark,
                            'type' => o['type'],
                            'ro' => "#{len_text(o['width'])} wide x #{len_text(Framing.ro_height(o))} high",
                            'question' => "Checked the plans, schedules and general notes - no header size is called out for #{mark}. " \
                                          'What header (size and plies) should be used?' })
          end
          d.add_action_callback('submit') do |_c, a|
            q = JSON.parse(a)['question'].to_s.strip
            n = nil
            operation('Submit RFI') do
              n = Project.submit_rfi(wall_id, mark, q)
              gg = Builder.find_wall(wall_id)
              pp = Builder.params_of(gg)
              pp['openings'] = pp['openings'].map { |x| x['mark'] == mark ? x.merge('rfi' => n) : x }
              Builder.set_params(gg, pp)
            end
            d.close
            msg = "RFI ##{n} submitted. #{mark} is on hold until the answer comes back - keep working on other openings and walls."
            Sketchup.status_text = msg
            refresh_frame
            js(@frame, 'setStatus', msg) if @frame&.visible?
            refresh_yard
          end
          d.add_action_callback('cancel') { |_c, _a| d.close }
          d.show
          d
        end

        # RFIs that just got their answers: tell the student, and the opening is off hold.
        def notify_rfis(done)
          return if done.nil? || done.empty?
          # No pop-up: it would land in the middle of someone's clicking. The answer goes to
          # Job Notes (badge) and the opening is tagged until they click it and read it.
          marks = done.map { |r| "#{r['mark']}" }.join(', ')
          Sketchup.status_text = "RFI answered for #{marks} - see Job Notes in the Framing panel, or click the opening."
          refresh_frame
          refresh_yard
          Sketchup.active_model.active_view.invalidate
        end

        # Job Notes: RFIs, inspections, instructor notes - newest first.
        def job_notes
          d = Project.data
          seen = d['notes_seen_at'].to_f
          items = []
          (d['rfis'] || []).each do |r|
            at = (r['answered_at'] || r['at']).to_i
            items << { 'kind' => 'RFI', 'at' => at, 'unseen' => !!r['answer'] && at > seen,
                       'title' => "RFI ##{r['n']} - #{r['wall']} #{r['mark']} - #{r['answer'] ? 'answered' : 'waiting on answer'}",
                       'lines' => ["Q: #{r['question']}"] + (r['answer'] ? ["A: #{r['answer']}"] : ["#{r['mark']} is on hold until the answer comes back."]) }
          end
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
              hdr = o['header'] == Framing::RFI ? 'header: RFI out' : "header #{Framing.header_label(o)}"
              { 'mark' => o['mark'], 'wall' => p['id'],
                'text' => "#{o['mark']} #{o['type'].downcase} (#{p['id']}) - RO #{len_text(o['width'])} x #{len_text(Framing.ro_height(o))}#{head}, #{hdr}" }
            end
          end.sort_by { |x| x['mark'] }
        end

        def walls_list
          Builder.all_walls.map do |w|
            p = Builder.params_of(w)
            held = p['openings'].select { |o| o['header'] == Framing::RFI }.map { |o| o['mark'] }
            { 'id' => p['id'], 'level' => p['level'], 'type' => p['type'], 'stage' => Builder.stage(p), 'held' => held }
          end.sort_by { |x| [x['level'], x['id']] }
        end

        # For the Framing panel. Students see status only; the instructor sees time left.
        def rfi_state
          delay = (Project.settings['rfi_delay_min'] || 32).to_f * 60
          inst = Project.instructor?
          (Project.data['rfis'] || []).map do |r|
            left = [(r['at'].to_i + delay - Time.now.to_i) / 60.0, 0].max.ceil
            { 'n' => r['n'], 'wall' => r['wall'], 'mark' => r['mark'], 'question' => r['question'],
              'answer' => r['answer'],
              'status' => if r['answer'] then 'answered'
                          elsif inst then ((why = Project.rfi_stuck_reason(r)) ? "stuck: #{why}" : "answers itself in #{left} min")
                          else 'submitted - awaiting response'
                          end,
              'can_answer' => inst && !r['answer'] }
          end
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
          d.add_action_callback('answer_rfi') do |_c, a|
            next unless Project.instructor?
            args = JSON.parse(a)
            n = args['n'].to_i
            done = nil
            operation('Answer RFI') do
              if args['text'].to_s.strip.empty?
                done = Project.release_rfis(n)
              else
                done = Project.answer_rfi_manual(n, args['header'], args['plies'].to_i, args['text'])
              end
            end
            js(d, 'setStatus', "No span table row covers RFI ##{n} - type an answer with a header size.") if done.empty?
            notify_rfis(done)
            send_yard
          end
          d.add_action_callback('edit_opening') do |_c, a|
            g = focus_group or next
            activate_tool
            mark = JSON.parse(a)['mark']
            next send_yard unless Builder.params_of(g)['openings'].any? { |o| o['mark'] == mark }
            open_frame(g)
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
            activate_tool
            open_frame(g)
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
                                       .map { |o| { 'mark' => o['mark'], 'answered' => !!o['rfi_new'] } },
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
          y = Yard.data
          fmt = ->(pc) { pc.merge('length_text' => len_text(pc['length'])) }
          h = YardLogic.hand(y)
          js(@yard, 'load', {
               'wall' => wall_state(focus_group),
               'mode' => (@tool&.mode || :nail).to_s,
               'guided' => !!Project.settings['guided'],
               'building' => building_state,
               'rfis' => rfi_state,
               'framing_table' => !!Project.settings['framing_table'],
               'notes' => job_notes,
               'walls' => walls_list,
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
          d.add_action_callback('import_sfpa') do |_c, _a|
            next js(d, 'showErrors', ['Only the instructor can import header tables.']) unless Project.instructor?
            path = UI.openpanel('Header tables (WallFramer_SFPA_headers.json)', '', 'Header tables|*.json||')
            next unless path
            begin
              operation('Import Header Tables') { Project.import_sfpa(path) }
              send_setup
              js(d, 'setStatus', 'Header tables imported. RFIs on bearing walls answer from them now.')
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
