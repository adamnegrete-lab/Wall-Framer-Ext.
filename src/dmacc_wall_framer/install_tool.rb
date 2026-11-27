module DMACC
  module WallFramer
    # Carpentry tool. Works like a framer with a saw stop:
    #
    #   Pick a stock         panel list, or click a lumber pile in the model
    #   Type a length        sets the saw stop (sticky). "full" clears it.
    #                        "o" toggles offcuts-first.
    #   Click a layout mark  pulls a board, cuts it to the stop, nails it in
    #   Right-click a piece  pull it back out (it goes in your hand; the next
    #                        click nails that piece instead of a new one)
    #   Esc                  set the piece in your hand down on the cart
    class InstallTool
      MODES = %i[nail layout opening dtp].freeze
      MODE_NAMES = { nail: 'Nail', layout: 'Mark stud layout', opening: 'Mark opening centerline', dtp: 'Double top plates' }.freeze

      attr_reader :mode

      def activate
        Builder.close_edits
        @target = nil   # [group, slot, params]
        @pile = nil     # [id, label, t]
        @mark = nil     # [group, params, x] in layout / opening mode
        @focus = nil
        @mode ||= :nail
        update_ui
      end

      def set_mode(m)
        @mode = m.to_sym if MODES.include?(m.to_sym)
        @mark = nil
        update_ui
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end

      def onKeyDown(key, _repeat, _flags, _view)
        return false unless key == 9 # Tab cycles modes
        set_mode(MODES[(MODES.index(@mode) + 1) % MODES.size])
        true
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        update_ui
        view.invalidate
      end

      def yard
        Yard.data
      end

      # ---------- picking ----------

      # Ray in a wall's local space hits its middle plane -> [t, x, z]
      def wall_hit(group, params, ray)
        inv = group.transformation.inverse
        p = ray[0].transform(inv)
        v = ray[1].transform(inv)
        return nil if v.y.abs < 1e-6
        mid = Framing.depth(params) / 2.0
        t = (mid - p.y) / v.y
        return nil if t <= 0
        x = p.x + v.x * t
        z = p.z + v.z * t
        return nil if x < -1 || x > params['length'].to_f + 1 || z < -1 || z > params['height'].to_f + 1
        [t, x, z]
      end

      def pick(view, x, y)
        ray = view.pickray(x, y)
        @target = nil
        @pile = nil
        @mark = nil
        @dtp = nil
        if @mode == :dtp
          hits = Builder.all_walls.map { |g| top_hit(g, ray) }.compact
          @dtp = hits.min_by { |h| h[1] }
          focus(Builder.params_of(@dtp[0])['id']) if @dtp
          return
        end
        if @mode != :nail
          hits = Builder.all_walls.map { |g| plate_point(view, x, y, g, Builder.params_of(g), ray) }.compact
          @mark = hits.min_by { |h| h[4] }
          focus(@mark[1]['id']) if @mark
          return
        end
        best = nil
        Builder.all_walls.each do |g|
          p = Builder.params_of(g)
          hit = wall_hit(g, p, ray)
          next unless hit
          best = [hit[0], g, p, hit[1], hit[2]] if best.nil? || hit[0] < best[0]
        end
        pile = Yard.pile_at(ray)
        if pile && (best.nil? || pile[2] < best[0])
          @pile = pile
          return
        end
        return unless best
        _, g, p, lx, lz = best
        focus(p['id'])
        if @mode == :nail
          slot = Framing.slot_at(Builder.work_slots(p), lx, lz)
          @target = [g, slot, p] if slot
        end
      end

      # Ray hits the top of a wall's first top plate -> [group, t]
      def top_hit(g, ray)
        p = Builder.params_of(g)
        return nil unless p['top_plates'].to_i == 2
        inv = g.transformation.inverse
        o = ray[0].transform(inv)
        v = ray[1].transform(inv)
        return nil if v.z.abs < 1e-9
        ztop = p['height'].to_f - Framing::T
        t = (ztop - o.z) / v.z
        return nil if t <= 0
        lx = o.x + v.x * t
        ly = o.y + v.y * t
        d = Framing.depth(p)
        return nil if lx < -1 || lx > p['length'].to_f + 1 || ly < -1 || ly > d + 1
        [g, t, lx]
      end

      # Where on the top of the bottom plate the cursor is, along the wall.
      # Snaps to Tape Measure guides and real points when the cursor is on one.
      def plate_point(view, sx, sy, g, p, ray)
        inv = g.transformation.inverse
        d = Framing.depth(p)
        len = p['length'].to_f
        @ip ||= Sketchup::InputPoint.new
        @ip.pick(view, sx, sy)
        if @ip.valid? && @ip.degrees_of_freedom <= 1
          lp = @ip.position.transform(inv)
          if lp.y > -2 && lp.y < d + 2 && lp.z > -2 && lp.z < Framing::T + 2 && lp.x >= -0.5 && lp.x <= len + 0.5
            return [g, p, lp.x.to_f, true, ray[0].distance(@ip.position)]
          end
        end
        o = ray[0].transform(inv)
        v = ray[1].transform(inv)
        return nil if v.z.abs < 1e-9
        t = (Framing::T - o.z) / v.z
        return nil if t <= 0
        lx = o.x + v.x * t
        ly = o.y + v.y * t
        return nil if lx < 0 || lx > len || ly < -6 || ly > d + 6
        [g, p, lx, false, t]
      end

      # The framing panel follows the wall you're working on.
      def focus(wall_id)
        return if wall_id == @focus
        @focus = wall_id
        Dialogs.focus_wall(wall_id)
      end

      def occupied?(params, slot)
        e = (params['entries'] || {})[slot.id]
        return false unless Inspector.complete?(e)
        return (e['pieces'] || []).size >= slot.plies.to_i if slot.id.start_with?('HDR:')
        true
      end

      # ---------- events ----------

      def onMouseMove(_flags, x, y, view)
        pick(view, x, y)
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        pick(view, x, y)
        if @mode == :dtp
          click_dtp
        elsif @pile
          choose_pile(@pile[0])
        elsif @mode != :nail
          click_mark
        elsif @target
          nail(view)
        end
        view.invalidate
      end

      def click_dtp
        unless @dtp
          UI.beep
          Sketchup.status_text = 'Click the top of a wall.'
          return
        end
        g, _t, lx = @dtp
        # Clicking a piece that's already on: take it off (asks first)
        if (on = Builder.dtp_piece_at(g, lx))
          id = Builder.params_of(g)['id']
          len = Framing.fmt_len(on['b'] - on['a'])
          if UI.messagebox("Take off #{id} double plate piece ##{on['n']} (#{len})?", MB_YESNO) == IDYES
            take_off_dtp(g, (on['a'] + on['b']) / 2.0)
          end
          return
        end
        model = Sketchup.active_model
        model.start_operation('Double Top Plate', true)
        err = Builder.place_dtp(g, lx)
        model.commit_operation
        id = Builder.params_of(g)['id']
        if err
          UI.beep
          Sketchup.status_text = err
        else
          sp = Builder.dtp_piece_at(g, @dtp[2])
          left = Builder.dtp_free(g).size
          Sketchup.status_text = "#{id} double plate piece on (##{sp ? sp['n'] : '?'})." +
                                 (left.positive? ? " #{left} more piece#{left == 1 ? '' : 's'} to go on #{id}." : '') +
                                 ' Click a piece that is on to take it off.'
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def plates_in?(p)
        e = p['entries'] || {}
        Inspector.complete?(e['BP']) && Inspector.complete?(e['TP:1'])
      end

      def click_mark
        unless @mark
          UI.beep
          Sketchup.status_text = 'Point at the top of a bottom plate.'
          return
        end
        g, p, x, = @mark
        if Project.settings['jobsite_order'] && !plates_in?(p)
          UI.beep
          Sketchup.status_text = 'Plates first - lay out on the plates once they are cut and set.'
          return
        end
        if @mode == :opening
          Dialogs.open_frame(g, center: x)
          Sketchup.status_text = "Opening centerline at #{Framing.fmt_len(x)} - fill in the opening from the plans."
          return
        end
        model = Sketchup.active_model
        model.start_operation('Layout Mark', true)
        msg, err = Builder.toggle_mark(g, x - Framing::T / 2.0) # mark = stud center; slot = left edge
        model.commit_operation
        UI.beep if err
        Sketchup.status_text = err || msg
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def choose_pile(id)
        if %w[OFFCUTS CART].include?(id)
          Yard.change { |y| y['use_offcuts'] = true } if id == 'OFFCUTS'
          Sketchup.status_text = id == 'OFFCUTS' ? 'Offcuts first is ON.' : 'Pick a cut piece from the framing panel.'
        else
          label = nil
          Yard.change do |y|
            y['stock'] = id
            label = YardLogic.find(y['piles'], id)['label']
          end
          Sketchup.status_text = "Stock: #{label}. Type a cut length (or nail it full length)."
        end
        Dialogs.refresh_yard
      end

      def nail(view)
        g, slot, p = @target
        if occupied?(p, slot)
          UI.beep
          Sketchup.status_text = "#{slot.label} is already nailed - right-click it to pull it."
          return
        end
        if (why = Builder.gate_reason(p, slot))
          UI.beep
          Sketchup.status_text = why
          return
        end
        model = Sketchup.active_model
        model.start_operation('Nail In Piece', true)
        err = nil
        piece = nil
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        Yard.change do |y|
          piece = YardLogic.hand(y)
          piece, err = YardLogic.refill(y, kerf) unless piece
        end
        unless err
          err = Builder.install_piece(g, slot.id, piece)
          if err
            # couldn't nail it (occupied) - keep the piece in hand
          else
            Yard.change { |y| YardLogic.install(y, piece['id']) }
          end
        end
        model.commit_operation
        if err
          UI.beep
          Sketchup.status_text = err
        else
          Sketchup.status_text = "Nailed #{desc(piece)} - #{slot.label}."
        end
        Dialogs.refresh_yard
        Dialogs.refresh_frame
        view.invalidate
      end

      # Typed text sets the saw stop (or a command)
      def onUserText(text, view)
        s = text.strip.downcase
        if %w[o off offcut offcuts].include?(s)
          on = nil
          Yard.change { |y| on = y['use_offcuts'] = !y['use_offcuts'] }
          Sketchup.status_text = "Offcuts first is #{on ? 'ON' : 'OFF'}."
        elsif %w[full f 0 -].include?(s)
          Yard.change { |y| y['cut'] = nil }
          Sketchup.status_text = 'Saw stop cleared - boards go in full length.'
        else
          len = Framing.parse_len(text)
          unless len && len > 0
            UI.beep
            Sketchup.status_text = "Couldn't read \"#{text}\" - try 81 or 6' 9\". Type full to clear, o for offcuts."
            return
          end
          set_cut(len)
        end
        Dialogs.refresh_yard
        update_ui
        view.invalidate
      end

      # Set the stop. A piece already in hand gets cut to it too.
      def set_cut(len)
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        msg = nil
        model = Sketchup.active_model
        model.start_operation('Set Saw Stop', true)
        Yard.change do |y|
          y['cut'] = len
          h = YardLogic.hand(y)
          if h && h['length'] > len + YardLogic::MATCH
            _, off, err = YardLogic.cut(y, h['id'], len, kerf)
            msg = err || "Cut the piece in hand.#{off ? " Offcut #{Framing.fmt_len(off['length'])} to the offcut pile." : ''}"
          end
        end
        model.commit_operation
        Sketchup.status_text = "Saw stop at #{Framing.fmt_len(len)}. #{msg}"
      end

      def onCancel(_reason, view)
        if YardLogic.hand(yard)
          Yard.change { |y| y['hand'] = nil }
          Sketchup.status_text = 'Piece set down on the cart.'
          Dialogs.refresh_yard
        end
        view.invalidate
      end

      def getMenu(menu, flags = nil, x = nil, y = nil, view = nil)
        menu_items(menu, flags, x, y, view)
      rescue StandardError => e
        puts "Wall Framer right-click menu: #{e.class}: #{e.message}\n  #{e.backtrace.first(4).join("\n  ")}"
        nil
      end

      def menu_items(menu, _flags = nil, x = nil, y = nil, view = nil)
        pick(view, x, y) if view && x
        if @mode == :dtp && @dtp
          g, _t, lx = @dtp
          add_dtp_items(menu, g, lx)
          return
        end
        return unless @target
        g, slot, p = @target
        e = (p['entries'] || {})[slot.id]
        return unless Inspector.complete?(e)
        if slot.id == 'TP:2'
          add_dtp_items(menu, g, nil) # double plates come off piece by piece
          return
        end
        menu.add_item("Pull this piece out (#{slot.label})") { pull(g, slot) }
      end

      # Right-click on a double plate: the piece under the cursor, or (if none is
      # right there) every piece on that wall. The piece is fixed now, at the
      # right-click - by the time a menu item is clicked the cursor is on the menu.
      def add_dtp_items(menu, g, lx)
        p = Builder.params_of(g)
        spans, = Builder.dtp_spans(p['level'])
        list = spans[p['id']] || []
        hit = lx && list.find { |sp| lx >= sp['a'] - 0.5 && lx <= sp['b'] + 0.5 }
        (hit ? [hit] : list).each do |sp|
          at = (sp['a'] + sp['b']) / 2.0
          menu.add_item("Take off #{p['id']} double plate piece ##{sp['n']} (#{Framing.fmt_len(sp['b'] - sp['a'])})") do
            take_off_dtp(g, at)
          end
        end
      end

      def take_off_dtp(g, at)
        m = Sketchup.active_model
        m.start_operation('Remove Double Plate', true)
        rec = Builder.remove_dtp(g, at)
        m.commit_operation
        Sketchup.status_text = rec ? "Took off #{Builder.params_of(g)['id']} double plate piece ##{rec['n']} - the board went back on the cart." : 'No double plate there.'
        Dialogs.refresh_yard
        Dialogs.refresh_frame
        m.active_view.invalidate
      rescue StandardError => e
        m.abort_operation rescue nil
        UI.messagebox("Couldn't take that double plate off: #{e.message}")
      end

      def pull(group, slot)
        model = Sketchup.active_model
        model.start_operation('Pull Piece', true)
        Yard.change { |y| y['hand'] = nil } # anything in hand goes back on the cart
        piece = Builder.remove_piece(group, slot.id)
        Yard.change { |y| YardLogic.return_piece(y, piece) } if piece
        model.commit_operation
        Sketchup.status_text = piece ? "Pulled #{desc(piece)} - it's in your hand. Click a mark to re-nail it, or Esc." : 'Nothing there.'
        Dialogs.refresh_yard
        Dialogs.refresh_frame
        Sketchup.active_model.active_view.invalidate
      end

      # ---------- drawing ----------

      def draw(view)
        if @pile
          a, b = Yard.box_of(@pile[0])
          draw_box(view, nil, a, b, 'blue') if a
          view.draw_text(view.screen_coords(Geom::Point3d.new(*b)), "  #{@pile[1]} - click to use this stock")
        end
        return draw_dtp(view) if @mode == :dtp
        draw_mark(view) if @mode != :nail
        return unless @target
        g, slot, p = @target
        x0, z0, x1, z1 = Framing.slot_box(slot)
        d = Framing.depth(p)
        occ = occupied?(p, slot)
        why = occ ? nil : Builder.gate_reason(p, slot)
        nxt = why ? nil : YardLogic.next_piece(yard)
        color = occ ? 'red' : why ? 'gray' : (nxt ? 'lime' : 'gray')
        draw_box(view, g.transformation, [x0, 0, z0], [x1, d, z1], color, 3)
        if nxt && !occ
          e = { 'role' => slot.expected['role'], 'size' => nxt['size'], 'length' => nxt['length'] }
          if slot.id.start_with?('HDR:')
            have = ((p['entries'] || {})[slot.id] || {})['pieces'] || []
            e['pieces'] = have + [nxt]
          end
          Framing.members_for_entry(p, slot, e).last(1).each do |m|
            draw_box(view, g.transformation, [m.x, m.y, m.z], [m.x + m.dx, m.y + m.dy, m.z + m.dz], 'orange', 2)
          end
        end
        label = slot.label
        label += if occ then ' - nailed (right-click to pull)'
                 elsif why then " - #{why}"
                 elsif nxt then " <- #{desc(nxt)}"
                 else ' - pick a stock first'
                 end
        mid = Geom::Point3d.new((x0 + x1) / 2.0, 0, z1).transform(g.transformation)
        view.draw_text(view.screen_coords(mid), "  #{label}")
      end

      def draw_dtp(view)
        level = @dtp ? Builder.params_of(@dtp[0])['level'] : (Project.data['levels'].first || {})['name']
        spans, = Builder.dtp_spans(level)
        # order numbers on every piece that's on
        spans.each do |id, list|
          g = Builder.find_wall(id) or next
          p = Builder.params_of(g)
          list.each do |sp|
            c = Geom::Point3d.new((sp['a'] + sp['b']) / 2.0, Framing.depth(p) / 2.0, p['height'].to_f).transform(g.transformation)
            view.draw_text(view.screen_coords(c), "##{sp['n']}")
          end
        end
        return unless @dtp
        g, _t, lx = @dtp
        p = Builder.params_of(g)
        d = Framing.depth(p)
        z = p['height'].to_f
        # the separate pieces still to go on this wall
        Builder.dtp_free(g).each do |a, b|
          draw_box(view, g.transformation, [a, 0, z - Framing::T], [b, d, z], 'yellow', 1)
        end
        placed = Builder.dtp_piece_at(g, lx)
        sp = placed || Builder.dtp_preview(g, lx)
        return unless sp
        draw_box(view, g.transformation, [sp['a'], 0, z - Framing::T], [sp['b'], d, z], placed ? 'red' : 'orange', 3)
        nxt = Builder.dtp_seq.count { |r| (w = Builder.find_wall(r['wall'])) && Builder.params_of(w)['level'] == p['level'] } + 1
        msg = placed ? "piece ##{placed['n']} is on (click to take it off)" : "click to set this piece (##{nxt}) - #{Framing.fmt_len(sp['b'] - sp['a'])}"
        mid = Geom::Point3d.new((sp['a'] + sp['b']) / 2.0, d, z).transform(g.transformation)
        view.draw_text(view.screen_coords(mid), "  #{p['id']}: #{msg}")
      end

      def draw_mark(view)
        return unless @mark
        g, p, x, snapped = @mark
        d = Framing.depth(p)
        z = Framing::T
        tr = g.transformation
        pts = [[x, -3, z], [x, d + 3, z]].map { |c| Geom::Point3d.new(*c).transform(tr) }
        view.line_width = 3
        view.drawing_color = snapped ? 'magenta' : 'blue'
        view.draw(GL_LINES, pts)
        txt = @mode == :layout ? 'Stud mark' : 'Opening centerline'
        txt += snapped ? ' (on guide)' : ''
        txt += " - #{Framing.fmt_len(x)} from start" if Project.settings['tape_readout']
        view.draw_text(view.screen_coords(pts[1]), "  #{txt}")
      end

      def draw_box(view, tr, a, b, color, width = 2)
        pts = [[a[0], a[1], a[2]], [b[0], a[1], a[2]], [b[0], b[1], a[2]], [a[0], b[1], a[2]],
               [a[0], a[1], b[2]], [b[0], a[1], b[2]], [b[0], b[1], b[2]], [a[0], b[1], b[2]]].map do |c|
          pt = Geom::Point3d.new(*c)
          tr ? pt.transform(tr) : pt
        end
        segs = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
        view.line_width = width
        view.drawing_color = color
        view.draw(GL_LINES, segs.flat_map { |i, j| [pts[i], pts[j]] })
      end

      def getExtents
        bb = Geom::BoundingBox.new
        Builder.all_walls.each { |w| bb.add(w.bounds) if w.respond_to?(:bounds) }
        bb
      end

      def desc(piece)
        "#{piece['size']} x #{Framing.fmt_len(piece['length'])}"
      end

      def saw_text
        y = yard
        pile = YardLogic.find(y['piles'], y['stock'])
        h = YardLogic.hand(y)
        parts = []
        parts << "In hand: #{desc(h)}" if h
        parts << "Stock: #{pile ? pile['label'] : 'none'}"
        parts << "Saw stop: #{y['cut'] ? Framing.fmt_len(y['cut']) : 'full length'}"
        parts << 'Offcuts first' if y['use_offcuts']
        parts.join(' | ')
      end

      def update_ui
        Sketchup.vcb_label = 'Saw stop'
        Sketchup.vcb_value = yard['cut'] ? Framing.fmt_len(yard['cut']) : ''
        return if @pile || @target || @mark || @dtp
        Sketchup.status_text =
          case @mode
          when :layout then 'MARK STUD LAYOUT: click the top of the bottom plate where each common stud centers (snap to Tape Measure guides). Click a mark again to remove it. Tab = next mode.'
          when :opening then 'MARK OPENING: click the opening centerline on the bottom plate (snap to a Tape Measure guide), then fill in the opening. Tab = next mode.'
          when :dtp then 'DOUBLE TOP PLATES: click each piece in the order it goes on. The first plate at a corner or tee laps over it - and splits the wall it laps into into separate pieces. Click a piece that is on to take it off.'
          else "NAIL: #{saw_text}. Click a layout mark to nail. Type a length to set the stop (full = no cut, o = offcuts first). Tab = next mode."
          end
      end
    end
  end
end
