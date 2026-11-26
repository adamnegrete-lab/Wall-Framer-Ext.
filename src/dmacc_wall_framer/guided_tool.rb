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
        'Jack Stud' => 'RO height minus the bottom plate',
        'Header' => 'measure between the kings',
        'Rough Sill' => 'fits between the jacks',
        'Common Stud' => 'same as your kings',
        'Cripple under' => 'pull the RO down from the top of the jack to find the sill, then measure plate to sill',
        'Header block' => 'measure from the top of the header to the top plate'
      }.freeze

      def activate
        @mode = :guided unless @mode == :dtp
        @last = {} # last value typed per role - just press Enter to repeat
        super
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
        plate = Builder.all_walls.map { |g| plate_point(view, x, y, g, Builder.params_of(g), ray) }.compact.min_by { |h| h[4] }
        plate = nil if plate && !%w[openings commons].include?(Builder.stage(plate[1]))
        # Anywhere on the bottom plate's face counts too (not just its top edge)
        # At the openings step a click anywhere on the wall works (the pop-up asks the distance)
        if face && %w[openings commons].include?(Builder.stage(face[2])) &&
           (face[4] <= Framing::T + 2.5 || Builder.stage(face[2]) == 'openings')
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

      # ---------- clicking ----------

      def onLButtonDown(_flags, x, y, view)
        pick(view, x, y)
        if @mode == :dtp
          click_dtp
        elsif @mark
          g, p, lx, guide, _t, pen = @mark
          before = Builder.stage(p)
          if pen || guide
            # on a pencil mark (or a Tape Measure guide): use it
            before == 'openings' ? opening_popup(g, lx) : mark_click(g, lx)
          else
            pencil(g, reading(lx))
          end
          announce(g, before)
        elsif @target
          g, slot, p = @target
          before = Builder.stage(p)
          piece_popup(g, slot, p)
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
        unless %w[openings commons].include?(stage)
          UI.beep
          Sketchup.status_text = 'Type a tape reading during layout (openings or stud layout).'
          return
        end
        x = Framing.parse_len(text)
        unless x && x > 0
          UI.beep
          Sketchup.status_text = "Couldn't read \"#{text}\" - try 48 or 4' 0\"."
          return
        end
        before = stage
        if stage == 'openings'
          pencil(g, x)
        else
          mark_click(g, x)
          announce(g, before)
        end
        view.invalidate
      end

      # Not on a guide: ask for the tape reading instead of guessing a click.
      def stud_mark_popup(g)
        p = Builder.params_of(g)
        sp = p['spacing'].to_f
        res = UI.inputbox(["Stud center from wall start (your #{sp == sp.round ? sp.round : sp}\" O.C. layout)"],
                          [@last['layout'] || ''], [''], "Stud layout mark - #{p['id']}")
        return unless res
        x = Framing.parse_len(res[0])
        unless x && x > 0
          UI.messagebox("Couldn't read \"#{res[0]}\". Try 16, 32, or 2' 8\".")
          return
        end
        @last['layout'] = res[0]
        mark_click(g, x)
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
        tip = Project.settings['popup_tips'] && TIPS[tip_key(slot)] ? " (#{TIPS[tip_key(slot)]})" : ''
        title = "#{slot.label} - #{p['id']}"
        sizes = role == 'Header' ? '2x6|2x8|2x10|2x12' : '2x4|2x6'
        defaults = @last[role] || [role == 'Header' ? '2x8' : p['stud'], '', '2']
        defaults = [defaults[0], defaults[1], defaults[2]]
        defaults[0] = p['stud'] if role != 'Header' && !sizes.split('|').include?(defaults[0])
        prompts = ['Lumber size', "Cut length#{tip}"]
        lists = [sizes, '']
        vals = [defaults[0], defaults[1]]
        if role == 'Header'
          prompts << 'Plies (pieces nailed together)'
          lists << '1|2|3'
          vals << defaults[2]
        end
        loop do
          res = UI.inputbox(prompts, vals, lists, title)
          return unless res
          len = Framing.parse_len(res[1])
          unless len && len > 0
            UI.messagebox("Couldn't read the cut length \"#{res[1]}\". Try 81, 6' 9\", or 92 5/8.")
            vals = res
            next
          end
          plies = role == 'Header' ? res[2].to_i : 1
          model = Sketchup.active_model
          model.start_operation("Nail #{role}", true)
          err = Builder.nail_supplied(g, slot, res[0], len, plies)
          model.commit_operation
          if err
            UI.messagebox(err)
            return
          end
          @last[role] = [res[0], res[1], res[2] || '2']
          Sketchup.status_text = "Nailed #{plies > 1 ? "#{plies} x " : ''}#{res[0]} x #{Framing.fmt_len(len)} - #{slot.label}."
          break
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def tip_key(slot)
        return 'Cripple under' if slot.label.include?('under sill')
        return 'Header block' if slot.label.include?('header block')
        slot.expected['role']
      end

      def opening_popup(g, center = nil)
        p = Builder.params_of(g)
        prompts = ['Centerline from wall start (tape hooked on the arrow end)', 'Mark (from the plans)', 'Type',
                   'Rough opening width', 'RO top height (from subfloor)', 'Sill height (windows only)', 'Header (per plans)']
        vals = [center ? Framing.fmt_len(center) : '', '', 'Window', '', '', '', 'Not shown']
        lists = ['', '', 'Window|Door', '', '', '', (['Not shown'] + Framing::SIZES).join('|')]
        title = "Lay out an opening - #{p['id']}"
        loop do
          res = UI.inputbox(prompts, vals, lists, title)
          return unless res
          errs = []
          center = Framing.parse_len(res[0])
          res = res[1..]
          w = Framing.parse_len(res[2])
          h = Framing.parse_len(res[3])
          sill = res[1] == 'Window' ? Framing.parse_len(res[4]) : 0.0
          errs << "Couldn't read the centerline distance." unless center && center > 0
          errs << 'Enter the mark from the plans (W1, D2...).' if res[0].strip.empty?
          errs << "Couldn't read the RO width." unless w && w > 0
          errs << "Couldn't read the RO height." unless h && h > 0
          errs << "Couldn't read the sill height." if res[1] == 'Window' && sill.nil?
          mark = res[0].strip.upcase
          used = Builder.all_walls.flat_map { |x| Builder.params_of(x)['openings'].map { |o| o['mark'] } }
          errs << "#{mark} is already used." if used.include?(mark)
          if errs.empty?
            op = { 'mark' => mark, 'type' => res[1], 'x' => center - w / 2.0, 'width' => w, 'height' => h,
                   'sill' => sill || 0.0, 'header' => res[5] }
            test = p.merge('openings' => p['openings'] + [op])
            errs = Framing.validate(test, Project.header_table)
          end
          unless errs.empty?
            UI.messagebox("Fix these:\n\n" + errs.join("\n"))
            vals = [center ? Framing.fmt_len(center) : ''] + res
            next
          end
          model = Sketchup.active_model
          model.start_operation('Add Opening', true)
          p = Builder.params_of(g)
          p['openings'] = p['openings'] + [op]
          Builder.set_params(g, p)
          Builder.rebuild(g)
          model.commit_operation
          more = UI.messagebox("#{mark} is laid out.\n\nAnother opening in #{p['id']}?", MB_YESNO)
          Builder.set_flag(g, 'openings_done', true) unless more == IDYES
          Dialogs.refresh_yard
          Dialogs.refresh_frame
          break
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
          r = UI.messagebox("Plates are set on #{id}.\n\nNext: find your opening centerlines. Hook your tape on the wall start " \
                            "(the arrow end): hover the bottom plate (outlined in blue) and the tape pulls out with a reading. Type your plan dimension and press Enter " \
                            "(or click) to pencil-mark the centerline, then click the pencil mark to lay out the opening.\n\n" \
                            "Does #{id} have any openings?", MB_YESNO)
          if r != IDYES
            Builder.set_flag(g, 'openings_done', true)
            announce(g, 'openings')
          end
        when 'units'
          UI.messagebox("Openings are laid out on #{id}.\n\nNext: build each opening unit. Kings first, then jacks " \
                        "(nailed to the kings), the header, the sill, then cripples and header blocks. Click each piece's spot on the wall.")
        when 'commons'
          UI.messagebox("#{id}: next, lay out your common studs. Hook the tape on the wall start and type each stud center " \
                        '(16, 32, 48... or 24, 48...) and press Enter to mark an X. Then click each stud to cut and nail it.')
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
        model = Sketchup.active_model
        model.start_operation('Pull Piece', true)
        piece = Builder.remove_piece(group, slot.id)
        if piece
          Yard.change do |y|
            y['offcuts'] << { 'id' => YardLogic.new_id(y, 'O'), 'size' => piece['size'], 'length' => piece['length'].to_f }
          end
        end
        model.commit_operation
        Sketchup.status_text = piece ? "Pulled #{desc(piece)} - it went on the offcut pile. Click the spot to nail a new one." : 'Nothing there.'
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
          if %w[openings commons].include?(Builder.stage(fp))
            draw_box(view, fg.transformation, [0, 0, 0], [fp['length'].to_f, Framing.depth(fp), Framing::T], 'blue', @mark ? 3 : 2)
          end
        end
        if @mark
          g, p, x, guide, _t, pen = @mark
          snapped = guide || pen
          d = Framing.depth(p)
          z = Framing::T
          tr = g.transformation
          # the tape: hooked on the wall start, pulled out along the front of the plate
          tape = [[0, -0.5, z + 0.1], [x, -0.5, z + 0.1]].map { |c| Geom::Point3d.new(*c).transform(tr) }
          view.line_width = 6
          view.drawing_color = Sketchup::Color.new(240, 200, 0)
          view.draw(GL_LINES, tape)
          hook = [[0, -0.5, z + 0.1], [0, 1.5, z + 0.1]].map { |c| Geom::Point3d.new(*c).transform(tr) }
          view.line_width = 4
          view.drawing_color = 'black'
          view.draw(GL_LINES, hook)
          pts = [[x, -3, z], [x, d + 3, z]].map { |c| Geom::Point3d.new(*c).transform(tr) }
          view.line_width = 3
          view.drawing_color = snapped ? 'magenta' : 'blue'
          view.draw(GL_LINES, pts)
          view.draw_text(view.screen_coords(tape[1]), "  #{Framing.fmt_len(reading(x))}", size: 14, bold: true) rescue
            view.draw_text(view.screen_coords(tape[1]), "  #{Framing.fmt_len(reading(x))}")
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
        return if @target || @mark
        g = @focus && Builder.find_wall(@focus)
        unless g
          Sketchup.status_text = 'Hover a wall to start framing it.'
          return
        end
        p = Builder.params_of(g)
        nxt = Builder.next_slots(p).first(3).map(&:label)
        Sketchup.status_text =
          case Builder.stage(p)
          when 'plates' then "#{p['id']}: cut and set the plates - click the bottom plate spot, then the top plate."
          when 'openings' then "#{p['id']}: pull the tape along the bottom plate (blue). Type your plan dimension + Enter (or click) for a pencil mark, then click the mark to lay out the opening."
          when 'units' then "#{p['id']}: build the opening units. Next: #{nxt.join(', ')}."
          when 'commons' then "#{p['id']}: stud layout - type each reading + Enter (16, 32, 48...) to mark an X, then click each stud to nail it."
          else "#{p['id']} is framed. Request an inspection from the Framing panel."
          end
      end
    end
  end
end
