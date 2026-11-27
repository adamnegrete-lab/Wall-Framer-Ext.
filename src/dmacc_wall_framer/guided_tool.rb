module DMACC
  module WallFramer
    # Pop-up framing. The student works right on the wall, in job-site order:
    #   plates -> opening centerlines -> opening units -> stud layout + commons
    # Click a piece's spot, a SketchUp pop-up asks for the cut length, the board
    # comes out of the yard (offcuts first) and gets nailed in where they can see it.
    class GuidedTool < InstallTool
      TIPS = {
        'Bottom Plate' => 'measure the chalk line on the deck',
        'Top Plate' => 'same as the bottom plate',
        'King Stud' => 'kings run plate to plate',
        'Header' => 'measure between the kings',
        'Rough Sill' => 'fits between the jacks',
        'Common Stud' => 'same as your kings',
        'Cripple under' => 'plate to bottom of sill',
        'Header block' => 'header to top plate'
      }.freeze

      def activate
        @mode = :guided unless @mode == :dtp
        @last ||= {} # last value typed per role - just press Enter to repeat
        super
        Dialogs.notify_rfis(Project.release_rfis)
        g = Dialogs.focus_group
        @focus = g && Builder.params_of(g)['id'] # pick up where you left off
        update_ui
      end

      def set_mode(m)
        m = m.to_sym
        @mode = m == :dtp ? :dtp : :guided
        @mark = nil
        update_ui
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end

      def onKeyDown(*)
        false
      end

      # ---------- picking ----------

      def pick(view, x, y)
        return super if @mode == :dtp
        ray = view.pickray(x, y)
        @target = nil
        @mark = nil
        @pile = nil
        @dtp = nil
        face = nil
        Builder.all_walls.each do |g|
          p = Builder.params_of(g)
          hit = wall_hit(g, p, ray)
          face = [hit[0], g, p, hit[1], hit[2]] if hit && (face.nil? || hit[0] < face[0])
        end
        @corner = nil
        # Stud step: click near either end of the wall to choose its corner assembly
        if face && Builder.stage(face[2]) == 'commons'
          _, cg, cp, clx, = face
          reach = [24.0, cp['length'].to_f / 4].min
          end_name = if clx <= reach then 'start'
                     elsif clx >= cp['length'].to_f - reach then 'end'
                     end
          if end_name
            @corner = [cg, cp, end_name]
            focus(cp['id'])
            return
          end
        end
        # Openings are entered in the Openings form (it stays open beside the Tape Measure),
        # so the plate no longer takes tape readings / pencil marks.
        plate = nil
        slot = nil
        if face
          _, g, p, lx, lz = face
          focus(p['id'])
          slot = Framing.slot_at(Builder.work_slots(p), lx, lz)
        end
        if plate && (slot.nil? || face.nil? || plate[4] <= face[0] + 0.5 || Builder.stage(plate[1]) == 'openings' ||
                     face[4] <= Framing::T + 2.5)
          @mark = plate
          snap_pencil
          focus(plate[1]['id'])
        elsif slot
          @target = [face[1], slot, face[2]]
          focus(face[2]['id'])
        end
      end

      PENCIL_SNAP = 1.5 # inches

      # @mark = [group, params, x, on_guide, t, pencil_x_or_nil]
      def snap_pencil
        g, p, x, guide, t = @mark
        pen = (p['pencil'] || []).map(&:to_f).min_by { |m| (m - x).abs }
        pen = nil if pen && (pen - x).abs > PENCIL_SNAP
        x = pen if pen
        @mark = [g, p, x, guide, t, pen]
      end

      def reading(x)
        (x.to_f * 16).round / 16.0
      end

      # A spot on the wall (from the start) rounded to the 1/16 on the tape,
      # with the tape hooked on the layout end.
      def tape_snap(p, lx)
        Framing.from_end?(p) ? p['length'].to_f - reading(p['length'].to_f - lx) : reading(lx)
      end

      # Tape reading (from the layout end) -> spot on the wall (from the start).
      def from_tape(p, t)
        Framing.from_end?(p) ? p['length'].to_f - t : t
      end

      # ---------- clicking ----------

      def onLButtonDown(_flags, x, y, view)
        Builder.close_edits
        pick(view, x, y)
        fg = @focus && Builder.find_wall(@focus)
        # A wall you start framing goes to the framing table first (frame it flat, then stand it up)
        if @mode != :dtp && fg && to_table?(fg)
          to_table(fg)
          return
        end
        if @mode != :dtp && fg && Builder.stage(Builder.params_of(fg)) == 'openings'
          Dialogs.open_frame(fg)
          Sketchup.status_text = "#{@focus}: enter its openings from the plans in the Openings form (or click 'No openings in this wall')."
          return
        end
        if @mode != :dtp && table_mode? && (row = click_row)
          g, key = row
          Dialogs.open_frame(g, row: key)
          Sketchup.status_text = "#{Builder.params_of(g)['id']}: type it in the cut list - it goes in as soon as you press Enter."
          update_ui
          view.invalidate
          return
        end
        if @mode == :dtp
          click_dtp
        elsif @corner
          g, p, end_name = @corner
          before = Builder.stage(p)
          corner_popup(g, end_name)
          announce(g, before)
        elsif @mark
          g, p, lx, guide, _t, pen = @mark
          before = Builder.stage(p)
          if pen || guide
            # on a pencil mark (or a Tape Measure guide): use it
            before == 'openings' ? opening_popup(g, lx) : mark_click(g, lx)
          else
            pencil(g, tape_snap(p, lx))
          end
          announce(g, before)
        elsif @target && Builder.stage(@target[2]) == 'corners'
          UI.beep
          Sketchup.status_text = "#{@target[2]['id']}: set the corners first - click the Corners tool."
        elsif @target
          g, slot, p = @target
          before = Builder.stage(p)
          op = slot.opening && p['openings'].find { |o| o['mark'] == slot.opening }
          if op && op['rfi_new']
            read_rfi_answer(g, op)
          elsif op && op['header'] == Framing::RFI && !op['rfi']
            Dialogs.open_rfi(p['id'], op['mark'])
          elsif slot.kind == :backing
            tee_popup(g, slot, p)
          elsif king_needs_mark?(p, slot)
            header_mark_popup(g, slot, p)
          else
            piece_popup(g, slot, p)
          end
          announce(g, before)
        end
        update_ui
        view.invalidate
      end

      # Pieces are cut and placed from the Frame Wall form's cut list.
      def table_mode?
        Project.settings['guided']
      end

      # [group, cut-list row] for what's under the cursor
      def click_row
        if @corner
          g, _p, end_name = @corner
          return [g, "corner:#{end_name}"]
        end
        return nil unless @target
        g, slot, p = @target
        op = slot.opening && p['openings'].find { |o| o['mark'] == slot.opening }
        return nil if op && (op['rfi_new'] || (op['header'] == Framing::RFI && !op['rfi'])) # RFI flow first
        key = CutList.row_for(p, slot.id)
        key && [g, key]
      end

      def pencil(g, x)
        model = Sketchup.active_model
        model.start_operation('Pencil Mark', true)
        msg, err = Builder.add_pencil(g, x)
        model.commit_operation
        UI.beep if err
        stage = Builder.stage(Builder.params_of(g))
        nxt = stage == 'openings' ? 'Click the mark to lay out the opening on it.' : 'Click the mark to put a stud on it.'
        Sketchup.status_text = err || "#{msg} #{nxt}"
      end

      FRAMING_STAGES = %w[plates openings units commons cripples].freeze

      def to_table?(g)
        Project.settings['framing_table'] && !Builder.on_table?(g) && FRAMING_STAGES.include?(Builder.stage(Builder.params_of(g)))
      end

      def to_table(g)
        id = Builder.params_of(g)['id']
        back = Builder.table_walls.map { |w| Builder.params_of(w)['id'] }
        m = Sketchup.active_model
        m.start_operation("#{id} to the Framing Table", true)
        Builder.lay_down(g)
        m.commit_operation
        Views.table(g)
        focus(id)
        Sketchup.status_text = "#{id} is on the framing table, lying flat with the bottom plate toward you. Frame it, then stand it up." +
                               (back.empty? ? '' : " (#{back.join(', ')} went back on its line, unfinished.)")
        Dialogs.open_frame(g) if table_mode? || Builder.stage(Builder.params_of(g)) == 'openings'
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end

      # Raise it and set it on its chalk line.
      def stand_up(g)
        id = Builder.params_of(g)['id']
        m = Sketchup.active_model
        m.start_operation("Stand Up #{id}", true)
        Builder.stand_up(g)
        m.commit_operation
        Views.restore
        rest = Builder.all_walls.reject { |w| Builder.stage(Builder.params_of(w)) == 'framed' }.map { |w| Builder.params_of(w)['id'] }
        Sketchup.status_text = "#{id} is standing on its line. " +
                               (rest.empty? ? 'Every wall is up - double top plates next.' : "Next wall: click one to bring it to the table (#{rest.first(4).join(', ')}).")
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end

      # Nothing in the Frame tool takes a typed number now (openings go in the Openings form).
      def onUserText(text, view)
        g = @focus && Builder.find_wall(@focus)
        return super if @mode == :dtp || g.nil?
        UI.beep
        Sketchup.status_text = Builder.stage(Builder.params_of(g)) == 'openings' ? 'Openings go in the Openings form - click the wall to open it.' : 'Nothing to type here - click a spot on the wall.'
      end

      CORNERS = {
        'single' => 'Single stud (this wall butts into another, or a free end)',
        'L' => 'L-corner post (another wall butts into this end)'
      }.freeze

      def corner_popup(g, end_name)
        Builder.refresh_corner_needs(Builder.params_of(g)['level'])
        p = Builder.params_of(g)
        where = end_name == 'start' ? 'wall start' : 'wall end'
        cur = CORNERS[(p['corners'] || {})[end_name]] || CORNERS['single']
        res = UI.inputbox(["Corner assembly at the #{where}"], [cur], [CORNERS.values.join('|')], "Corner - #{p['id']}")
        return unless res
        p['corners'] = (p['corners'] || {}).merge(end_name => CORNERS.key(res[0]))
        Builder.set_params(g, p)
        other = end_name == 'start' ? 'end' : 'start'
        unless p['corners'][other]
          Sketchup.status_text = "#{p['id']}: now click the other end of the wall for its corner assembly."
          Builder.rebuild(g)
          return
        end
        oc = UI.inputbox(['Stud layout (on center)'], [(p['oc'] || 16).to_f == 19.2 ? '19.2' : (p['oc'] || 16).to_i.to_s],
                         ['16|19.2|24'], "Stud layout - #{p['id']}")
        return Builder.rebuild(g) unless oc
        model = Sketchup.active_model
        model.start_operation('Lay Out and Nail Studs', true)
        p = Builder.params_of(g)
        p['oc'] = oc[0].to_f
        Builder.set_params(g, p)
        err = Builder.auto_frame_commons(g)
        model.commit_operation
        if err
          UI.messagebox(err)
        else
          n = (Builder.params_of(g)['marks'] || []).size
          Sketchup.status_text = "#{p['id']}: #{n} commons laid out at #{oc[0]}\" O.C. and nailed, with the corner assemblies."
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      # Not on a guide: ask for the tape reading instead of guessing a click.
      def stud_mark_popup(g)
        p = Builder.params_of(g)
        sp = p['spacing'].to_f
        res = UI.inputbox(["Stud center from #{tape_end(p)} (your #{sp == sp.round ? sp.round : sp}\" O.C. layout)"],
                          [@last['layout'] || ''], [''], "Stud layout mark - #{p['id']}")
        return unless res
        x = Framing.parse_len(res[0])
        unless x && x > 0
          UI.messagebox("Couldn't read \"#{res[0]}\". Try 16, 32, or 2' 8\".")
          return
        end
        @last['layout'] = res[0]
        mark_click(g, from_tape(p, x))
      end

      def mark_click(g, lx)
        model = Sketchup.active_model
        model.start_operation('Layout Mark', true)
        msg, err = Builder.toggle_mark(g, lx - Framing::T / 2.0)
        model.commit_operation
        UI.beep if err
        Sketchup.status_text = err || "#{msg} Click the mark's stud on the wall to cut and nail it."
        Dialogs.refresh_yard
      end

      def piece_popup(g, slot, p)
        if occupied?(p, slot)
          Sketchup.status_text = "#{slot.label} is already nailed - pull it with the Demo tool."
          return
        end
        if (why = Builder.gate_reason(p, slot))
          UI.beep
          Sketchup.status_text = why
          return
        end
        role = slot.expected['role']
        header = role == 'Header'
        tip = tip_for(slot, p)
        title = "#{slot.label} - #{p['id']}"
        defaults = @last[role] || [header ? '' : p['stud'], '', '2']
        prompts = []
        lists = []
        vals = []
        if header
          # The size was set from the plans when the opening was laid out - only the cut is asked here.
          op = p['openings'].find { |o| o['mark'] == slot.opening }
          prompts << "Cut length - #{Framing.header_label(op)}#{tip}"
          lists << ''
          vals << defaults[1]
        else
          sizes = '2x4|2x6'
          size = sizes.split('|').include?(defaults[0]) ? defaults[0] : p['stud']
          tip = plate_tip(p, slot) || tip
          prompts << 'Lumber size' << "Cut length#{tip}"
          lists << sizes << ''
          vals << size << defaults[1]
        end
        loop do
          res = UI.inputbox(prompts, vals, lists, title)
          return unless res
          size = header ? slot.expected['size'] : res[0]
          len_s = header ? res[0] : res[1]
          len = Framing.parse_len(len_s)
          unless len && len > 0
            UI.messagebox("Couldn't read the cut length \"#{len_s}\". Try 81, 6' 9\", or 92 5/8.")
            vals = res
            next
          end
          if Framing.plate?(slot) && len > Framing::STOCK_MAX + 1e-6
            UI.messagebox("Longest plate stock is 16'. Splice the plate: cut the first piece to land the splice " \
                          'centered on a stud (from the arrow end), then click the plate again for the rest.')
            vals = res
            next
          end
          plies = header ? slot.plies.to_i : 1
          model = Sketchup.active_model
          model.start_operation("Nail #{role}", true)
          err = Builder.nail_supplied(g, slot, size, len, plies)
          model.commit_operation
          if err
            UI.messagebox(err)
            return
          end
          @last[role] = header ? [size, res[0]] : [res[0], res[1]]
          more = Framing.plate?(slot) && (Builder.params_of(g)['entries'][slot.id] || {})['full'] == false
          Sketchup.status_text = "Nailed #{plies > 1 ? "#{plies} x " : ''}#{size} x #{Framing.fmt_len(len)} - #{slot.label}." +
                                 (more ? ' Spliced - click the plate again for the next piece.' : '')
          break
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      # Plates over 16' get spliced: first piece from the arrow end, then the rest.
      def plate_tip(p, slot)
        return nil unless Framing.plate?(slot) && p['length'].to_f > Framing::STOCK_MAX
        e = (p['entries'] || {})[slot.id]
        if e && (e['pieces'] || []).any?
          ' - next piece, from the splice toward the opposite end'
        else
          " - longest stock is 16'. Splice it: first piece from the arrow end, splice centered on a stud"
        end
      end

      def tip_for(slot, p)
        return '' unless Project.settings['popup_tips'] && TIPS[tip_key(slot)]
        " (#{TIPS[tip_key(slot)]})"
      end

      # A nailed king on an opening with no header mark yet: mark the header height on it.
      def king_needs_mark?(_p, _slot)
        false # header marks on the kings are retired - students work out jack length from the head height
      end

      def header_mark_popup(g, slot, p)
        op = p['openings'].find { |o| o['mark'] == slot.opening }
        prompt = "Header height for #{slot.opening} - bottom of the header, measured from the subfloor"
        cur = (p['hdr_marks'] || {})[slot.opening]
        loop do
          res = UI.inputbox([prompt], [cur ? Framing.fmt_len(cur.to_f) : (@last['hdr_mark'] || '')], [''], "Mark the kings - #{slot.opening}")
          return unless res
          z = Framing.parse_len(res[0])
          unless z && z > Framing::T && z < p['height'].to_f
            UI.messagebox("Couldn't read \"#{res[0]}\" as a height on this wall. Try 82 1/2 or 6' 10 1/2\".")
            next
          end
          @last['hdr_mark'] = res[0]
          return if cur && (cur.to_f - z).abs < 1e-6
          model = Sketchup.active_model
          model.start_operation('Mark Header Height', true)
          p = Builder.params_of(g)
          jacks = Builder.work_slots(p).select { |s| s.opening == slot.opening && s.expected['role'] == 'Jack Stud' && occupied?(p, s) }
          if cur && jacks.any? &&
             UI.messagebox("#{slot.opening}'s jacks were cut to the old mark. Pull them and re-cut?", MB_YESNO) == IDYES
            pulled = jacks.map { |s| Builder.remove_piece(g, s.id) }.compact
            Yard.change { |y| pulled.each { |pc| y['offcuts'] << { 'id' => YardLogic.new_id(y, 'O'), 'size' => pc['size'], 'length' => pc['length'].to_f } } }
            p = Builder.params_of(g)
          end
          p['hdr_marks'] = (p['hdr_marks'] || {}).merge(slot.opening => z)
          Builder.set_params(g, p)
          Builder.rebuild(g)
          model.commit_operation
          jl = z - Framing::T
          Sketchup.status_text = "#{slot.opening}: header height marked on the kings at #{Framing.fmt_len(z)}. " \
                                 "Your jacks run from the top of the bottom plate up to the mark."
          Dialogs.refresh_frame
          return jl
        end
      end

      # The RFI answer, read when the student goes back to the opening.
      def read_rfi_answer(g, op)
        # the answer shows on the opening's row in the Openings tab (and stays in Job Notes)
        Sketchup.status_text = "RFI ##{op['rfi_new']} is answered - update #{op['mark']} in the Openings tab with the header from the answer."
        Dialogs.open_frame(g)
        Dialogs.refresh_yard
      end

      # Tags on openings: on hold (RFI out) / RFI answered (click to read)
      def draw_opening_tags(view, g, p)
        p['openings'].each do |o|
          txt = if o['rfi_new'] then "#{o['mark']}: RFI answered - click to update"
                elsif o['header'] == Framing::RFI then "#{o['mark']}: ON HOLD - #{o['rfi'] ? "RFI ##{o['rfi']} out" : 'RFI not sent'}"
                end
          next unless txt
          pt = Geom::Point3d.new(o['x'].to_f + o['width'].to_f / 2.0, 0, o['height'].to_f + 6).transform(g.transformation)
          begin
            view.draw_text(view.screen_coords(pt), txt, size: 14, bold: true, color: o['rfi_new'] ? 'green' : 'red', align: TextAlignCenter)
          rescue StandardError
            view.draw_text(view.screen_coords(pt), txt)
          end
        end
      end

      BACKING = {
        'ladder' => 'Ladder blocking (flat blocks between the studs)',
        'channel' => '3-stud channel (two studs flanking the partition)'
      }.freeze

      def tee_popup(g, slot, p)
        if occupied?(p, slot)
          Sketchup.status_text = "#{slot.label} is in - pull it with the Demo tool."
          return
        end
        if (why = Builder.gate_reason(p, slot))
          UI.beep
          Sketchup.status_text = why
          return
        end
        oc = (Project.settings['ladder_oc'] || 24).to_f
        res = UI.inputbox(["Backing for the #{slot.id.sub('TEE:', '')} partition (ladder blocks at #{oc == oc.round ? oc.round : oc}\" O.C.)"],
                          [BACKING[@last['backing'] || 'ladder']], [BACKING.values.join('|')], "Partition backing - #{p['id']}")
        return unless res
        kind = BACKING.key(res[0]) || 'ladder'
        @last['backing'] = kind
        model = Sketchup.active_model
        model.start_operation('Partition Backing', true)
        err = Builder.install_tee(g, slot.id.sub('TEE:', ''), kind)
        model.commit_operation
        if err
          UI.messagebox(err)
        else
          Sketchup.status_text = "#{BACKING[kind].split(' (').first} is in behind the #{slot.id.sub('TEE:', '')} partition."
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def tip_key(slot)
        return 'Cripple under' if slot.label.include?('under sill')
        return 'Header block' if slot.label.include?('header block')
        slot.expected['role']
      end

      PLY_PICK = '--'
      HDR_PICK = Framing::HDR_PICK
      HDR_FLAT = Framing::HDR_FLAT
      HDR_RFI = Framing::HDR_RFI

      def header_choices
        Framing.header_choices
      end

      def header_value(choice)
        Framing.header_from_choice(choice)
      end

      def tape_end(p)
        Framing.from_end?(p) ? 'the layout end (tape hooked on the opposite end of the wall)' : 'wall start (tape hooked on the arrow end)'
      end

      # Two pop-ups: what it is, then what the plans say about it (doors have no head height).
      # edit: the mark of an opening already laid out - its pop-ups open with what was entered.
      def opening_popup(g, center = nil, edit: nil)
        p = Builder.params_of(g)
        old = edit && p['openings'].find { |o| o['mark'] == edit }
        return if edit && !old
        title = old ? "Edit #{edit} - #{p['id']}" : "Lay out an opening - #{p['id']}"
        center = old['x'].to_f + old['width'].to_f / 2.0 if old
        v1 = [center ? Framing.fmt_len(Framing.layout_dist(p, center)) : '', old ? old['mark'] : '', old ? old['type'] : (@last['otype'] || 'Window')]
        loop do
          r1 = UI.inputbox(["Centerline from #{tape_end(p)}", 'Mark (from the plans)', 'Type'], v1, ['', '', 'Window|Door'], title)
          return unless r1
          c = Framing.parse_len(r1[0])
          mark = r1[1].strip.upcase
          errs = []
          errs << "Couldn't read the centerline distance." unless c && c > 0 && c < p['length'].to_f
          errs << 'Enter the mark from the plans (W1, D2...).' if mark.empty?
          used = Builder.all_walls.flat_map { |x| Builder.params_of(x)['openings'].map { |o| o['mark'] } } - [edit]
          errs << "#{mark} is already used." if used.include?(mark)
          unless errs.empty?
            UI.messagebox("Fix these:\n\n" + errs.join("\n"))
            v1 = r1
            next
          end
          type = r1[2]
          @last['otype'] = type
          center = Framing.from_end?(p) ? p['length'].to_f - c : c
          return if opening_details(g, p, mark, type, center, title, old) != :back
          v1 = r1
        end
      end

      def opening_details(g, p, mark, type, center, title, old = nil)
        win = type == 'Window'
        dflt_hdr = !p['bearing'] && !win ? HDR_FLAT : HDR_PICK
        prompts = ['Rough opening width',
                   win ? 'Rough opening height (sill to header)' : 'Rough opening height (subfloor to header)']
        vals = old ? [Framing.fmt_len(old['width'].to_f), Framing.fmt_len(Framing.ro_height(old))] : ['', '']
        lists = ['', '']
        if win
          prompts << 'Head height - bottom of header from subfloor'
          vals << (old && old['type'] == 'Window' ? Framing.fmt_len(old['height'].to_f) : (@last['head'] || '82 1/2'))
          lists << ''
        end
        prompts << 'Header (from the plans / general notes)' << 'Header plies (from the plans)'
        # an answered RFI: the student fills in the header from the answer
        old_hdr = old && !(old['header'] == Framing::RFI && old['rfi_new']) ? Framing.header_choice(old['header']) : nil
        vals << (old_hdr || dflt_hdr) << (old && old['plies'] && old_hdr ? old['plies'].to_s : PLY_PICK)
        lists << header_choices.join('|') << ([PLY_PICK] + %w[1 2 3]).join('|')
        loop do
          res = UI.inputbox(prompts, vals, lists, "#{mark} (#{type}) - #{title}")
          return :back unless res
          w = Framing.parse_len(res[0])
          h = Framing.parse_len(res[1])
          head = win ? Framing.parse_len(res[2]) : h
          hdr = header_value(res[-2])
          plies = res[-1].to_i
          errs = []
          errs << "Couldn't read the RO width." unless w && w > 0
          errs << "Couldn't read the RO height." unless h && h > 0
          errs << "Couldn't read the head height." if win && head.nil?
          errs << "Pick the header size from the plans or general notes. If it isn't called out, don't assume - pick \"#{HDR_RFI}\"." unless hdr
          if Framing::SIZES.include?(hdr) && plies.zero?
            errs << 'Pick the number of header plies from the plans (the (2) in "(2) 2x10").'
          end
          if errs.empty?
            op = { 'mark' => mark, 'type' => type, 'x' => center - w / 2.0, 'width' => w,
                   'header' => hdr }.merge(Framing.opening_from_ro(type, h, head))
            op['plies'] = plies if Framing::SIZES.include?(hdr)
            @last['head'] = res[2] if win
            others = p['openings'].reject { |o| old && o['mark'] == old['mark'] }
            test = p.merge('openings' => others + [op])
            errs = Framing.validate(test, Project.header_table)
          end
          unless errs.empty?
            UI.messagebox("Fix these:\n\n" + errs.join("\n"))
            vals = res
            next
          end
          model = Sketchup.active_model
          if old
            # keep the RFI number only if it's still waiting on an RFI
            op['rfi'] = old['rfi'] if hdr == Framing::RFI && old['rfi'] && !old['rfi_new']
            model.start_operation("Edit #{old['mark']}", true)
            p = Builder.params_of(g)
            p['openings'] = p['openings'].map { |o| o['mark'] == old['mark'] ? op : o }
            Builder.set_params(g, p)
            Builder.rebuild(g)
            model.commit_operation
            Sketchup.status_text = hdr == Framing::RFI ? "#{mark} updated - still on hold." : "#{mark} updated#{old['header'] == Framing::RFI ? ' - off hold, frame it' : ''}."
            Dialogs.refresh_yard
            Dialogs.refresh_frame
            Dialogs.open_rfi(p['id'], mark) if hdr == Framing::RFI && !op['rfi']
            return :done
          end
          model.start_operation('Add Opening', true)
          p = Builder.params_of(g)
          p['openings'] = p['openings'] + [op]
          Builder.set_params(g, p)
          Builder.rebuild(g)
          model.commit_operation
          rfi = hdr == Framing::RFI
          held = rfi ? "Next you'll write the RFI for #{mark}'s header. #{mark} is on hold until the answer comes back.\n\n" : ''
          more = UI.messagebox("#{mark} is laid out.\n\n#{held}Another opening in #{p['id']}? " \
                               '(You can always right-click the wall to finish openings or remove one.)', MB_YESNO)
          Builder.set_flag(g, 'openings_done', true) unless more == IDYES
          Dialogs.refresh_yard
          Dialogs.refresh_frame
          Dialogs.open_rfi(p['id'], mark) if rfi
          return :done
        end
      end

      # One message when a wall moves to its next stage.
      # Stage changes show in the status bar and the Frame Wall form - no pop-ups.
      def announce(g, before)
        p = Builder.params_of(g)
        after = Builder.stage(p)
        return if after == before
        id = p['id']
        Sketchup.status_text = case after
                               when 'openings' then "Plates are set on #{id}. Next: enter its doors and windows from the plans (Openings tab)."
                               when 'units' then "#{id}: openings are in. Fill in the cut list for each opening - kings, jacks, header, sill."
                               when 'commons' then "#{id}: next, the corners, the stud spacing and the common stud length in the cut list."
                               when 'cripples' then "#{id}: studs are in. Cripples and header blocks land on your layout - fill in their lengths."
                               when 'framed'
                                 if Builder.on_table?(g)
                                   "#{id} is framed. Click Build and stand wall, then Frame next wall."
                                 else
                                   "#{id} is framed. Inspection opens once every wall on the level is framed, standing and double-plated."
                                 end
                               else Sketchup.status_text
                               end
        Dialogs.open_frame(g) if after == 'openings'
        Dialogs.refresh_frame
        Dialogs.refresh_yard
      end

      def menu_items(menu, flags = nil, x = nil, y = nil, view = nil)
        pick(view, x, y) if view && x
        return super(menu, flags, nil, nil, nil) if @mode == :dtp
        if @mark && @mark[5]
          g, = @mark
          pen = @mark[5]
          menu.add_item("Erase pencil mark at #{Framing.fmt_len(pen)}") do
            m = Sketchup.active_model
            m.start_operation('Erase Pencil Mark', true)
            Builder.remove_pencil(g, pen)
            m.commit_operation
          end
        end
        if @target && @target[1].opening && editable?(@target[2], @target[1].opening)
          g, slot, = @target
          menu.add_item("Edit opening #{slot.opening}") { Dialogs.open_frame(g) }
        end
        super(menu, flags, nil, nil, nil)
        wall_items(menu)
      end

      # Openings: finish, remove one, or go back and add one.
      def wall_items(menu)
        g = @focus && Builder.find_wall(@focus) or return
        p = Builder.params_of(g)
        stage = Builder.stage(p)
        id = p['id']
        e = p['entries'] || {}
        ws = Builder.work_slots(p)
        if stage == 'openings'
          menu.add_item("Enter openings for #{id}") { Dialogs.open_frame(g) }
        end
        if Builder.on_table?(g)
          if stage == 'framed'
            menu.add_item("Stand #{id} up and set it on its line") { stand_up(g) }
          else
            menu.add_item("Put #{id} back on its line (unfinished)") { stand_up(g) }
          end
        end
        if %w[openings units].include?(stage)
          p['openings'].each do |o|
            framed = ws.any? { |s| s.opening == o['mark'] && Inspector.complete?(e[s.id]) }
            next if framed
            menu.add_item("Remove opening #{o['mark']} from #{id}") { remove_opening(g, o['mark']) }
          end
        end
        if stage == 'units' && ws.none? { |s| s.phase == 'commons' && Inspector.complete?(e[s.id]) }
          menu.add_item("Add or change openings on #{id}") { Dialogs.open_frame(g) }
        end
      end

      # Openings can be edited until any piece of them is framed.
      def editable?(p, mark)
        e = p['entries'] || {}
        Builder.work_slots(p).none? { |s| s.opening == mark && Inspector.complete?(e[s.id]) }
      end

      def finish_openings(g)
        before = Builder.stage(Builder.params_of(g))
        m = Sketchup.active_model
        m.start_operation('Done With Openings', true)
        Builder.set_flag(g, 'openings_done', true)
        m.commit_operation
        announce(g, before)
        update_ui
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def remove_opening(g, mark)
        return unless UI.messagebox("Remove #{mark} from #{Builder.params_of(g)['id']}?", MB_YESNO) == IDYES
        m = Sketchup.active_model
        m.start_operation("Remove #{mark}", true)
        p = Builder.params_of(g)
        p['openings'] = p['openings'].reject { |o| o['mark'] == mark }
        (p['hdr_marks'] || {}).delete(mark)
        p['openings_done'] = false if p['openings'].empty?
        Builder.set_params(g, p)
        Builder.rebuild(g)
        m.commit_operation
        Sketchup.status_text = "#{mark} removed."
        update_ui
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def pull(group, slot)
        if slot.id == 'TP:2' # never pulled as one piece here - see add_dtp_items
          UI.beep
          Sketchup.status_text = 'Right-click the double plate and pick the piece to take off.'
          return
        end
        model = Sketchup.active_model
        model.start_operation('Pull Piece', true)
        pieces = slot.kind == :backing ? Builder.remove_backing(group, slot.id) : [Builder.remove_piece(group, slot.id)].compact
        unless pieces.empty?
          Yard.change do |y|
            pieces.each do |piece|
              y['offcuts'] << { 'id' => YardLogic.new_id(y, 'O'), 'size' => piece['size'], 'length' => piece['length'].to_f }
            end
          end
        end
        model.commit_operation
        Sketchup.status_text = if pieces.empty? then 'Nothing there.'
                               elsif pieces.size > 1 then "Pulled the #{slot.label} (#{pieces.size} pieces) - they went on the offcut pile."
                               else "Pulled #{desc(pieces.first)} - it went on the offcut pile. Click the spot to nail a new one."
                               end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
        Sketchup.active_model.active_view.invalidate
      end

      # ---------- drawing ----------

      def draw(view)
        return draw_dtp(view) if @mode == :dtp
        fg = @focus && Builder.find_wall(@focus)
        if fg
          fp = Builder.params_of(fg)
          # the wall you're working on
          draw_box(view, fg.transformation, [0, 0, 0], [fp['length'].to_f, Framing.depth(fp), fp['height'].to_f], 'blue', 1)
          # on the table the big label becomes the layout-start tag (SketchUp's own wall ID stays)
          draw_wall_label(view, fg, fp) unless Builder.on_table?(fg) # on the table the LAYOUT START label is in the model
          draw_opening_tags(view, fg, fp)
          if %w[openings commons].include?(Builder.stage(fp))
            draw_box(view, fg.transformation, [0, 0, 0], [fp['length'].to_f, Framing.depth(fp), Framing::T], 'blue', @mark ? 3 : 2)
          end
        end
        if @corner
          g, p, end_name = @corner
          d = Framing.depth(p)
          len = p['length'].to_f
          x0 = end_name == 'start' ? 0.0 : len - 12.0
          draw_box(view, g.transformation, [x0, 0, 0], [x0 + 12.0, d, p['height'].to_f], 'magenta', 3)
          chosen = (p['corners'] || {})[end_name]
          txt = "#{end_name == 'start' ? 'Wall start' : 'Wall end'} corner - click to choose the corner assembly"
          txt += " (now: #{chosen == 'L' ? 'L-corner post' : 'single stud'})" if chosen
          view.draw_text(view.screen_coords(Geom::Point3d.new(x0 + 6, 0, p['height'].to_f).transform(g.transformation)), "  #{txt}")
          return
        end
        if @mark
          g, p, x, guide, _t, pen = @mark
          snapped = guide || pen
          d = Framing.depth(p)
          z = Framing::T
          tr = g.transformation
          # the tape: hooked on the layout end (arrow), pulled out along the front of the plate
          x0 = Framing.from_end?(p) ? p['length'].to_f : 0.0
          tape = [[x0, -0.5, z + 0.1], [x, -0.5, z + 0.1]].map { |c| Geom::Point3d.new(*c).transform(tr) }
          view.line_width = 6
          view.drawing_color = Sketchup::Color.new(240, 200, 0)
          view.draw(GL_LINES, tape)
          hook = [[x0, -0.5, z + 0.1], [x0, 1.5, z + 0.1]].map { |c| Geom::Point3d.new(*c).transform(tr) }
          view.line_width = 4
          view.drawing_color = 'black'
          view.draw(GL_LINES, hook)
          pts = [[x, -3, z], [x, d + 3, z]].map { |c| Geom::Point3d.new(*c).transform(tr) }
          view.line_width = 3
          view.drawing_color = snapped ? 'magenta' : 'blue'
          view.draw(GL_LINES, pts)
          rd = Framing.fmt_len(reading(Framing.layout_dist(p, x)))
          view.draw_text(view.screen_coords(tape[1]), "  #{rd}", size: 14, bold: true) rescue
            view.draw_text(view.screen_coords(tape[1]), "  #{rd}")
          txt = if Builder.stage(p) == 'openings'
                  snapped ? 'Click: opening centered on this mark' : 'Click to pencil-mark here (or type a reading + Enter)'
                else
                  snapped ? 'Click: stud on this mark (click an X again to remove it)' : 'Click to pencil-mark here (or type a reading + Enter for a stud)'
                end
          view.draw_text(view.screen_coords(pts[1]), "  #{txt}")
        end
        return unless @target
        g, slot, p = @target
        x0, z0, x1, z1 = Framing.slot_box(slot)
        d = Framing.depth(p)
        occ = occupied?(p, slot)
        why = occ ? nil : Builder.gate_reason(p, slot)
        draw_box(view, g.transformation, [x0, 0, z0], [x1, d, z1], occ ? 'red' : (why ? 'gray' : 'lime'), 3)
        label = slot.label + if occ then ' - nailed (Demo tool to pull)'
                             elsif why then " - #{why}"
                             else ' - click to cut and nail'
                             end
        mid = Geom::Point3d.new((x0 + x1) / 2.0, 0, z1).transform(g.transformation)
        view.draw_text(view.screen_coords(mid), "  #{label}")
      end

      # Big ID over the wall you're working on.
      # On the framing table: which end the layout starts from, big enough to read from above.
      def draw_end_tags(view, g, p)
        start_x = Framing.from_end?(p) ? p['length'].to_f : 0.0
        pt = view.screen_coords(Geom::Point3d.new(start_x, 0, p['height'].to_f + 12).transform(g.transformation))
        txt = start_x.zero? ? 'LAYOUT START >' : '< LAYOUT START'
        align = start_x.zero? ? TextAlignLeft : TextAlignRight
        begin
          view.draw_text(pt, txt, size: 20, bold: true, color: 'red', align: align)
        rescue StandardError
          view.draw_text(pt, txt)
        end
      end

      def draw_wall_label(view, g, p)
        pt = view.screen_coords(Geom::Point3d.new(p['length'].to_f / 2.0, 0, p['height'].to_f + 12).transform(g.transformation))
        txt = "#{p['id']}  (#{Builder.stage(p)})"
        begin
          view.draw_text(pt, txt, size: 20, bold: true, color: 'blue', align: TextAlignCenter)
        rescue StandardError
          view.draw_text(pt, txt)
        end
      end

      def update_ui
        Sketchup.vcb_label = 'Tape'
        return super if @mode == :dtp
        return if @target || @mark || @corner
        g = @focus && Builder.find_wall(@focus)
        unless g
          Sketchup.status_text = 'Hover a wall to start framing it.'
          return
        end
        p = Builder.params_of(g)
        nxt = Builder.next_slots(p).first(3).map(&:label)
        Sketchup.status_text =
          case Builder.stage(p)
          when 'corners' then "#{p['id']}: set the corners first - click the Corners tool and decide which walls run through."
          when 'plates' then "#{p['id']}: cut and set the plates - click the bottom plate spot, then the top plate."
          when 'openings' then "#{p['id']}: enter the openings in the Openings form - click the wall to open it. The Tape Measure works while it's open."
          when 'units' then "#{p['id']}: frame the openings (kings, jacks, header, sill). Next: #{nxt.join(', ')}."
          when 'commons'
            if p['oc'] then "#{p['id']}: click each tee spot to put in partition backing (ladder blocking or a 3-stud channel)."
            else "#{p['id']}: click each end of the wall to choose its corner assembly, then pick the stud spacing - the studs lay out and nail themselves."
            end
          when 'cripples' then "#{p['id']}: cripples and header blocks, on your stud layout. Next: #{nxt.join(', ')}."
          else "#{p['id']} is framed. Click Frame next wall."
          end
      end
    end
  end
end
