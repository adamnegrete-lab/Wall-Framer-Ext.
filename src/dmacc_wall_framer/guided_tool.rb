module DMACC
  module WallFramer
    # The Frame tool. Click a wall: it goes to the framing table and its Frame Wall
    # form opens (plates, openings, corners and studs are typed there, and go in
    # as they're typed). Click a piece: the form jumps to its row. In double top
    # plate mode, click each piece in the order it goes on.
    class GuidedTool
      FRAMING_STAGES = %w[plates openings units commons cripples].freeze

      attr_reader :mode

      def activate
        @active = true
        Builder.close_edits
        @mode = :guided unless @mode == :dtp
        @target = nil # [group, slot, params]
        @corner = nil # [group, params, 'start'|'end']
        @dtp = nil    # [group, t, lx]
        g = Dialogs.focus_group
        @focus = g && Builder.params_of(g)['id'] # pick up where you left off
        update_ui
      end

      def deactivate(view)
        @active = false
        view.invalidate
      end

      def active?
        @active
      end

      def resume(view)
        update_ui
        view.invalidate
      end

      def set_mode(m)
        @mode = m.to_sym == :dtp ? :dtp : :guided
        update_ui
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end

      def onKeyDown(*)
        false
      end

      def onUserText(_text, _view)
        UI.beep
        Sketchup.status_text = 'Nothing to type here - lengths go in the Frame Wall form.'
      end

      def onCancel(_reason, view)
        view.invalidate
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

      # Ray hits the top of a wall's first top plate -> [group, t, lx]
      def top_hit(g, ray)
        p = Builder.params_of(g)
        return nil unless p['top_plates'].to_i == 2
        inv = g.transformation.inverse
        o = ray[0].transform(inv)
        v = ray[1].transform(inv)
        return nil if v.z.abs < 1e-9
        t = (p['height'].to_f - Framing::T - o.z) / v.z
        return nil if t <= 0
        lx = o.x + v.x * t
        ly = o.y + v.y * t
        return nil if lx < -1 || lx > p['length'].to_f + 1 || ly < -1 || ly > Framing.depth(p) + 1
        [g, t, lx]
      end

      def pick(view, x, y)
        ray = view.pickray(x, y)
        @target = nil
        @corner = nil
        @dtp = nil
        if @mode == :dtp
          @dtp = Builder.dtp_level_walls.map { |g| top_hit(g, ray) }.compact.min_by { |h| h[1] }
          focus(Builder.params_of(@dtp[0])['id']) if @dtp
          return
        end
        face = nil
        Builder.all_walls.each do |g|
          p = Builder.params_of(g)
          hit = wall_hit(g, p, ray)
          face = [hit[0], g, p, hit[1], hit[2]] if hit && (face.nil? || hit[0] < face[0])
        end
        return unless face
        _, g, p, lx, lz = face
        focus(p['id'])
        # Stud step: near either end of the wall is its corner row
        if Builder.stage(p) == 'commons'
          reach = [24.0, p['length'].to_f / 4].min
          end_name = if lx <= reach then 'start'
                     elsif lx >= p['length'].to_f - reach then 'end'
                     end
          return @corner = [g, p, end_name] if end_name
        end
        slot = Framing.slot_at(Builder.work_slots(p), lx, lz)
        @target = [g, slot, p] if slot
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
        return e['full'] != false if Framing.plate?(slot)
        true
      end

      # ---------- clicking ----------

      def onMouseMove(_flags, x, y, view)
        pick(view, x, y)
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        Builder.close_edits
        pick(view, x, y)
        return click_dtp.tap { view.invalidate } if @mode == :dtp
        fg = @focus && Builder.find_wall(@focus)
        if fg && to_table?(fg)
          to_table(fg) # a wall you start framing goes to the framing table first
          return view.invalidate # keep its status line
        elsif fg && Builder.stage(Builder.params_of(fg)) == 'corners'
          UI.beep
          Sketchup.status_text = "#{@focus}: set the corners first - click the Corners tool."
        elsif (row = click_row)
          g, key = row
          Dialogs.open_frame(g, row: key)
          Sketchup.status_text = "#{Builder.params_of(g)['id']}: type it in the Frame Wall form - it goes in as soon as you press Enter."
        elsif @target && @target[1].id == 'TP:2'
          Sketchup.status_text = 'Double top plates go on with the Double Top Plates tool, once every wall on the floor is up.'
        elsif fg
          Dialogs.open_frame(fg)
        end
        update_ui
        view.invalidate
      end

      # [group, cut-list row] for what's under the cursor
      def click_row
        if @corner
          g, _p, end_name = @corner
          return [g, "corner:#{end_name}"]
        end
        return nil unless @target
        g, slot, p = @target
        key = CutList.row_for(p, slot.id)
        key && [g, key]
      end

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
        Dialogs.open_frame(g)
        Sketchup.status_text = "#{id} is on the framing table, lying flat with the bottom plate toward you." +
                               (back.empty? ? '' : " (#{back.join(', ')} went back on its line, unfinished.)") +
                               ' Fill in the Frame Wall form.'
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
        Sketchup.status_text = "#{id} is standing on its line. Click Frame next wall in the Frame Wall form."
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end

      # One status line when a wall moves to its next stage (no pop-ups).
      def announce(g, before)
        p = Builder.params_of(g)
        after = Builder.stage(p)
        return if after == before
        id = p['id']
        Sketchup.status_text = case after
                               when 'openings' then "Plates are set on #{id}. Next: its doors and windows from the plans (Openings)."
                               when 'units' then "#{id}: openings are in. Fill in the cut list for each opening - kings, jacks, header, sill."
                               when 'commons' then "#{id}: next, the corners, the stud spacing and the common stud length."
                               when 'cripples' then "#{id}: studs are in. Cripples and header blocks land on your layout - fill in their lengths."
                               when 'framed'
                                 Builder.on_table?(g) ? "#{id} is framed. Click Build and stand wall, then Frame next wall." : "#{id} is framed."
                               else Sketchup.status_text
                               end
        Dialogs.refresh_frame
        Dialogs.refresh_yard
      end

      def remove_opening(g, mark)
        return unless UI.messagebox("Remove #{mark} from #{Builder.params_of(g)['id']}?", MB_YESNO) == IDYES
        m = Sketchup.active_model
        m.start_operation("Remove #{mark}", true)
        p = Builder.params_of(g)
        p['openings'] = p['openings'].reject { |o| o['mark'] == mark }
        p['openings_done'] = false if p['openings'].empty?
        Builder.set_params(g, p)
        CutList.apply(g)
        m.commit_operation
        Sketchup.status_text = "#{mark} removed."
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      # ---------- double top plates ----------

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
          if UI.messagebox("Take off #{id} double plate piece ##{on['n']} (#{Framing.fmt_len(on['b'] - on['a'])})?", MB_YESNO) == IDYES
            take_off_dtp(g, (on['a'] + on['b']) / 2.0)
          end
          return
        end
        model = Sketchup.active_model
        model.start_operation('Double Top Plate', true)
        err = Builder.place_dtp(g, lx)
        model.commit_operation
        if err == 'SPLICE'
          err = nil
          return unless dtp_splice_popup(g, lx)
        end
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

      # A double plate run longer than 16': the student picks the splice. A bad splice gets a hint.
      def dtp_splice_popup(g, lx)
        sp = Builder.dtp_preview(g, lx) or return false
        p = Builder.params_of(g)
        len = sp['b'] - sp['a']
        title = "Splice the double plate - #{p['id']}"
        loop do
          cuts = []
          while len - cuts.sum > Framing::STOCK_MAX + 1e-6
            left = len - cuts.sum
            prompt = cuts.empty? ? "This run is #{Framing.fmt_len(len)} - longest stock is 16'. First piece, from the layout start" :
                                   "Next piece (#{Framing.fmt_len(left)} of the run left)"
            res = UI.inputbox([prompt], [@last_dtp_cut || ''], [''], title)
            return false unless res
            c = Framing.parse_len(res[0])
            unless c && c.positive? && c < left
              UI.messagebox("Couldn't use \"#{res[0]}\" - try 16' or 12' 8\".")
              next
            end
            @last_dtp_cut = res[0]
            cuts << c
          end
          cuts << len - cuts.sum
          m = Sketchup.active_model
          m.start_operation('Double Top Plate', true)
          err = Builder.place_dtp(g, lx, cuts)
          m.commit_operation
          return true unless err
          UI.messagebox("Not there:\n\n#{err}\n\nTry the splice again.")
        end
      end

      def take_off_dtp(g, at)
        m = Sketchup.active_model
        m.start_operation('Remove Double Plate', true)
        rec = Builder.remove_dtp(g, at)
        m.commit_operation
        Sketchup.status_text = rec ? "Took off #{Builder.params_of(g)['id']} double plate piece ##{rec['n']}." : 'No double plate there.'
        Dialogs.refresh_yard
        Dialogs.refresh_frame
        m.active_view.invalidate
      rescue StandardError => e
        m.abort_operation rescue nil
        UI.messagebox("Couldn't take that double plate off: #{e.message}")
      end

      # ---------- drawing ----------

      def draw(view)
        return draw_dtp(view) if @mode == :dtp
        fg = @focus && Builder.find_wall(@focus)
        if fg
          fp = Builder.params_of(fg)
          draw_box(view, fg.transformation, [0, 0, 0], [fp['length'].to_f, Framing.depth(fp), fp['height'].to_f], 'blue', 1)
          draw_wall_label(view, fg, fp) unless Builder.on_table?(fg) # on the table the LAYOUT START label is in the model
        end
        if @corner
          g, p, end_name = @corner
          d = Framing.depth(p)
          x0 = end_name == 'start' ? 0.0 : p['length'].to_f - 12.0
          draw_box(view, g.transformation, [x0, 0, 0], [x0 + 12.0, d, p['height'].to_f], 'magenta', 3)
          txt = "#{end_name == 'start' ? 'Layout start' : 'Opposite end'} corner - click for its row in the form"
          view.draw_text(view.screen_coords(Geom::Point3d.new(x0 + 6, 0, p['height'].to_f).transform(g.transformation)), "  #{txt}")
          return
        end
        return unless @target
        g, slot, p = @target
        x0, z0, x1, z1 = Framing.slot_box(slot)
        occ = occupied?(p, slot)
        why = occ ? nil : Builder.gate_reason(p, slot)
        draw_box(view, g.transformation, [x0, 0, z0], [x1, Framing.depth(p), z1], occ ? 'red' : (why ? 'gray' : 'lime'), 3)
        label = slot.label + (occ ? ' - in (click for its row)' : why ? " - #{why}" : ' - click for its row')
        view.draw_text(view.screen_coords(Geom::Point3d.new((x0 + x1) / 2.0, 0, z1).transform(g.transformation)), "  #{label}")
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
        Builder.dtp_free(g).each { |a, b| draw_box(view, g.transformation, [a, 0, z - Framing::T], [b, d, z], 'yellow', 1) }
        placed = Builder.dtp_piece_at(g, lx)
        sp = placed || Builder.dtp_preview(g, lx)
        return unless sp
        draw_box(view, g.transformation, [sp['a'], 0, z - Framing::T], [sp['b'], d, z], placed ? 'red' : 'orange', 3)
        nxt = Builder.dtp_seq.count { |r| (w = Builder.find_wall(r['wall'])) && Builder.params_of(w)['level'] == p['level'] } + 1
        msg = placed ? "piece ##{placed['n']} is on (click to take it off)" : "click to set this piece (##{nxt}) - #{Framing.fmt_len(sp['b'] - sp['a'])}"
        view.draw_text(view.screen_coords(Geom::Point3d.new((sp['a'] + sp['b']) / 2.0, d, z).transform(g.transformation)), "  #{p['id']}: #{msg}")
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

      # Big ID over the wall you're working on.
      def draw_wall_label(view, g, p)
        pt = view.screen_coords(Geom::Point3d.new(p['length'].to_f / 2.0, 0, p['height'].to_f + 12).transform(g.transformation))
        txt = "#{p['id']}  (#{Builder.stage(p)})"
        begin
          view.draw_text(pt, txt, size: 20, bold: true, color: 'blue', align: TextAlignCenter)
        rescue StandardError
          view.draw_text(pt, txt)
        end
      end

      def getExtents
        bb = Geom::BoundingBox.new
        Builder.all_walls.each { |w| bb.add(w.bounds) if w.respond_to?(:bounds) }
        bb
      end

      def update_ui
        Sketchup.vcb_label = ''
        if @mode == :dtp
          return if @dtp
          Sketchup.status_text = 'DOUBLE TOP PLATES: click each piece in the order it goes on. The first plate at a corner or tee laps over it - ' \
                                 'and splits the wall it laps into into separate pieces. Click a piece that is on to take it off.'
          return
        end
        return if @target || @corner
        g = @focus && Builder.find_wall(@focus)
        unless g
          Sketchup.status_text = 'Click a wall to start framing it.'
          return
        end
        p = Builder.params_of(g)
        Sketchup.status_text =
          case Builder.stage(p)
          when 'corners' then "#{p['id']}: set the corners first - click the Corners tool and decide which walls run through."
          when 'framed' then "#{p['id']} is framed. Click Frame next wall in the Frame Wall form."
          else "#{p['id']}: fill in the Frame Wall form - click a piece to jump to its row."
          end
      end
    end
  end
end
