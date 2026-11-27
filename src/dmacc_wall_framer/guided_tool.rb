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
        'Jack Stud' => 'head height minus the bottom plate',
        'Header' => 'measure between the kings',
        'Rough Sill' => 'fits between the jacks',
        'Common Stud' => 'same as your kings',
        'Cripple under' => 'pull the RO down from the top of the jack to find the sill, then measure plate to sill',
        'Header block' => 'measure from the top of the header to the top plate'
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
        plate = Builder.all_walls.map { |g| plate_point(view, x, y, g, Builder.params_of(g), ray) }.compact.min_by { |h| h[4] }
        plate = nil if plate && Builder.stage(plate[1]) != 'openings'
        # Anywhere on the bottom plate's face counts too (not just its top edge)
        # At the openings step a click anywhere on the wall works (the pop-up asks the distance)
        if face && Builder.stage(face[2]) == 'openings'
          _, fg, fp, flx, = face
          snapped = plate && plate[3] && plate[0] == fg
          plate = snapped ? plate : [fg, fp, flx, false, face[0]]
        end
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
          if slot.kind == :backing
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

      # Typing a number = pull the tape exactly that far from the wall start.
      def onUserText(text, view)
        g = @focus && Builder.find_wall(@focus)
        return super if @mode == :dtp || g.nil?
        p = Builder.params_of(g)
        stage = Builder.stage(p)
        unless stage == 'openings'
          UI.beep
          Sketchup.status_text = 'Type a tape reading while laying out openings.'
          return
        end
        x = Framing.parse_len(text)
        unless x && x > 0
          UI.beep
          Sketchup.status_text = "Couldn't read \"#{text}\" - try 48 or 4' 0\"."
          return
        end
        x = from_tape(p, x)
        before = stage
        if stage == 'openings'
          pencil(g, x)
        else
          mark_click(g, x)
          announce(g, before)
        end
        view.invalidate
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
          Sketchup.status_text = "#{slot.label} is already nailed - right-click it to pull it."
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
          prompts << "Cut length#{tip}" << "Plies (pieces nailed together) - header per plans: #{Framing.header_label(op)}"
          lists << '' << '1|2|3'
          vals << defaults[1] << (op && op['header'] == Framing::FLAT ? '2' : defaults[2])
        else
          sizes = '2x4|2x6'
          size = sizes.split('|').include?(defaults[0]) ? defaults[0] : p['stud']
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
          plies = header ? res[1].to_i : 1
          model = Sketchup.active_model
          model.start_operation("Nail #{role}", true)
          err = Builder.nail_supplied(g, slot, size, len, plies)
          model.commit_operation
          if err
            UI.messagebox(err)
            return
          end
          @last[role] = header ? [size, res[0], res[1]] : [res[0], res[1], '2']
          Sketchup.status_text = "Nailed #{plies > 1 ? "#{plies} x " : ''}#{size} x #{Framing.fmt_len(len)} - #{slot.label}."
          break
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def tip_for(slot, p)
        if slot.expected['role'] == 'Jack Stud' && (z = (p['hdr_marks'] || {})[slot.opening])
          return " (your header mark on the kings is at #{Framing.fmt_len(z.to_f)} from the subfloor - " \
                 'measure from the top of the bottom plate up to the mark)'
        end
        return '' unless Project.settings['popup_tips'] && TIPS[tip_key(slot)]
        " (#{TIPS[tip_key(slot)]})"
      end

      # A nailed king on an opening with no header mark yet: mark the header height on it.
      def king_needs_mark?(p, slot)
        return false unless slot.expected['role'] == 'King Stud' && slot.opening
        return false if (p['hdr_marks'] || {})[slot.opening]
        occupied?(p, slot)
      end

      def header_mark_popup(g, slot, p)
        op = p['openings'].find { |o| o['mark'] == slot.opening }
        prompt = "Header height for #{slot.opening} - bottom of the header, measured from the subfloor"
        loop do
          res = UI.inputbox([prompt], [@last['hdr_mark'] || ''], [''], "Mark the kings - #{slot.opening}")
          return unless res
          z = Framing.parse_len(res[0])
          unless z && z > Framing::T && z < p['height'].to_f
            UI.messagebox("Couldn't read \"#{res[0]}\" as a height on this wall. Try 82 1/2 or 6' 10 1/2\".")
            next
          end
          @last['hdr_mark'] = res[0]
          model = Sketchup.active_model
          model.start_operation('Mark Header Height', true)
          p = Builder.params_of(g)
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

      BACKING = {
        'ladder' => 'Ladder blocking (flat blocks between the studs)',
        'channel' => '3-stud channel (two studs flanking the partition)'
      }.freeze

      def tee_popup(g, slot, p)
        if occupied?(p, slot)
          Sketchup.status_text = "#{slot.label} is in - right-click it to pull it."
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
        Framing.from_end?(p) ? 'the layout end (tape hooked on the far end of the wall)' : 'wall start (tape hooked on the arrow end)'
      end

      # Two pop-ups: what it is, then what the plans say about it (doors have no head height).
      def opening_popup(g, center = nil)
        p = Builder.params_of(g)
        title = "Lay out an opening - #{p['id']}"
        v1 = [center ? Framing.fmt_len(Framing.layout_dist(p, center)) : '', '', @last['otype'] || 'Window']
        loop do
          r1 = UI.inputbox(["Centerline from #{tape_end(p)}", 'Mark (from the plans)', 'Type'], v1, ['', '', 'Window|Door'], title)
          return unless r1
          c = Framing.parse_len(r1[0])
          mark = r1[1].strip.upcase
          errs = []
          errs << "Couldn't read the centerline distance." unless c && c > 0 && c < p['length'].to_f
          errs << 'Enter the mark from the plans (W1, D2...).' if mark.empty?
          used = Builder.all_walls.flat_map { |x| Builder.params_of(x)['openings'].map { |o| o['mark'] } }
          errs << "#{mark} is already used." if used.include?(mark)
          unless errs.empty?
            UI.messagebox("Fix these:\n\n" + errs.join("\n"))
            v1 = r1
            next
          end
          type = r1[2]
          @last['otype'] = type
          center = Framing.from_end?(p) ? p['length'].to_f - c : c
          return if opening_details(g, p, mark, type, center, title) != :back
          v1 = r1
        end
      end

      def opening_details(g, p, mark, type, center, title)
        win = type == 'Window'
        dflt_hdr = !p['bearing'] && !win ? HDR_FLAT : HDR_PICK
        prompts = ['Rough opening width',
                   win ? 'Rough opening height (sill to header)' : 'Rough opening height (subfloor to header)']
        vals = ['', '']
        lists = ['', '']
        if win
          prompts << 'Head height - bottom of header from subfloor'
          vals << (@last['head'] || '82 1/2')
          lists << ''
        end
        prompts << 'Header (from the plans / general notes)'
        vals << dflt_hdr
        lists << header_choices.join('|')
        loop do
          res = UI.inputbox(prompts, vals, lists, "#{mark} (#{type}) - #{title}")
          return :back unless res
          w = Framing.parse_len(res[0])
          h = Framing.parse_len(res[1])
          head = win ? Framing.parse_len(res[2]) : h
          hdr = header_value(res.last)
          errs = []
          errs << "Couldn't read the RO width." unless w && w > 0
          errs << "Couldn't read the RO height." unless h && h > 0
          errs << "Couldn't read the head height." if win && head.nil?
          errs << "Pick the header size from the plans or general notes. If it isn't called out, don't assume - pick \"#{HDR_RFI}\"." unless hdr
          if errs.empty?
            op = { 'mark' => mark, 'type' => type, 'x' => center - w / 2.0, 'width' => w,
                   'header' => hdr }.merge(Framing.opening_from_ro(type, h, head))
            @last['head'] = res[2] if win
            test = p.merge('openings' => p['openings'] + [op])
            errs = Framing.validate(test, Project.header_table)
          end
          unless errs.empty?
            UI.messagebox("Fix these:\n\n" + errs.join("\n"))
            vals = res
            next
          end
          if hdr == Framing::RFI
            q = UI.inputbox(['Your question (RFI)'],
                            ["The header size for #{mark} (#{Framing.fmt_len(w)} RO, #{p['id']}) isn't on the plans or in the general notes. What header should be used?"],
                            [''], "Request for Information - #{mark}")
            unless q
              vals = res
              next
            end
            op['rfi'] = Project.submit_rfi(p['id'], mark, q[0].to_s.strip)
          end
          model = Sketchup.active_model
          model.start_operation('Add Opening', true)
          p = Builder.params_of(g)
          p['openings'] = p['openings'] + [op]
          Builder.set_params(g, p)
          Builder.rebuild(g)
          model.commit_operation
          held = op['rfi'] ? "RFI ##{op['rfi']} is submitted. #{mark} is on hold until the answer comes back - " \
                             "keep working on other openings and walls in the meantime.\n\n" : ''
          more = UI.messagebox("#{mark} is laid out.\n\n#{held}Another opening in #{p['id']}?", MB_YESNO)
          Builder.set_flag(g, 'openings_done', true) unless more == IDYES
          Dialogs.refresh_yard
          Dialogs.refresh_frame
          return :done
        end
      end

      # One message when a wall moves to its next stage.
      def announce(g, before)
        p = Builder.params_of(g)
        after = Builder.stage(p)
        return if after == before
        id = p['id']
        case after
        when 'openings'
          r = UI.messagebox("Plates are set on #{id}.\n\nNext: find your opening centerlines. Hook your tape on the arrow end " \
                            "of the wall: hover the bottom plate (outlined in blue) and the tape pulls out with a reading. Type your plan dimension and press Enter " \
                            "(or click) to pencil-mark the centerline, then click the pencil mark to lay out the opening.\n\n" \
                            "Does #{id} have any openings?", MB_YESNO)
          if r != IDYES
            Builder.set_flag(g, 'openings_done', true)
            announce(g, 'openings')
          end
        when 'units'
          UI.messagebox("Openings are laid out on #{id}.\n\nNext: frame each opening. Kings first, then click a king and mark the " \
                        'header height on it - your jacks run from the top of the bottom plate up to that mark. Then the jacks, the header ' \
                        "and the sill. Cripples and header blocks come later - they go on your stud layout.")
        when 'commons'
          tees = (p['tee_need'] || []).map { |t| t['id'] }
          UI.messagebox("#{id}: next, the studs. Click each end of the wall and choose its corner assembly - a single stud if this " \
                        'wall butts into another, an L-corner post if another wall butts into this end. Then pick the stud spacing ' \
                        "(16, 19.2 or 24\" O.C.) - the layout pulls from the arrow end and the studs nail themselves." +
                        (tees.empty? ? '' : "\n\n#{tees.join(', ')} tee#{tees.size == 1 ? 's' : ''} into this wall - click each tee spot " \
                                             'to put in partition backing (ladder blocking or a 3-stud channel).'))
        when 'cripples'
          UI.messagebox("#{id}: studs are in.\n\nNext: cripples and header blocks. They land on your stud layout - " \
                        'click each spot above the headers and under the sills.')
        when 'framed'
          UI.messagebox("#{id} is framed.\n\nRequest an inspection from the Framing panel. Double top plates go on " \
                        'once every wall on this level is framed and standing.')
        end
        Dialogs.refresh_yard
      end

      def getMenu(menu, flags = nil, x = nil, y = nil, view = nil)
        pick(view, x, y) if view && x
        if @mark && @mark[5]
          g, = @mark
          pen = @mark[5]
          menu.add_item("Erase pencil mark at #{Framing.fmt_len(pen)}") do
            m = Sketchup.active_model
            m.start_operation('Erase Pencil Mark', true)
            Builder.remove_pencil(g, pen)
            m.commit_operation
          end
          return
        end
        super(menu, flags, nil, nil, nil)
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
        label = slot.label + if occ then ' - nailed (right-click to pull)'
                             elsif why then " - #{why}"
                             else ' - click to cut and nail'
                             end
        mid = Geom::Point3d.new((x0 + x1) / 2.0, 0, z1).transform(g.transformation)
        view.draw_text(view.screen_coords(mid), "  #{label}")
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
          when 'openings' then "#{p['id']}: pull the tape along the bottom plate (blue). Type your plan dimension + Enter (or click) for a pencil mark, then click the mark to lay out the opening."
          when 'units' then "#{p['id']}: frame the openings (kings, header mark on the kings, jacks, header, sill). Next: #{nxt.join(', ')}."
          when 'commons'
            if p['oc'] then "#{p['id']}: click each tee spot to put in partition backing (ladder blocking or a 3-stud channel)."
            else "#{p['id']}: click each end of the wall to choose its corner assembly, then pick the stud spacing - the studs lay out and nail themselves."
            end
          when 'cripples' then "#{p['id']}: cripples and header blocks, on your stud layout. Next: #{nxt.join(', ')}."
          else "#{p['id']} is framed. Request an inspection from the Framing panel."
          end
      end
    end
  end
end
