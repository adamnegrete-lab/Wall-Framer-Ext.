module DMACC
  module WallFramer
    # Lay out walls in plan view, like the floor plan. Walls chain: each new
    # wall starts where the last one ended, until you press Esc or close the
    # loop. Corners are decided afterward with the Corners tool.
    #
    #   Click        start / end of a wall
    #   Type length  exact length in the current direction (Enter)
    #   Shift (hold) lock the current direction
    #   Esc          done - go set the corners
    #
    # Picked points are always dropped onto the level datum, and inference is
    # always taken from the model axes (not from the wall you just placed).
    class DrawWallTool
      SNAP_DEG = 3.0       # snap to an axis / previous wall within this angle
      CLOSE_TOL = 0.5      # end within 1/2" of the chain start = close the loop

      def initialize(level_name, type_name)
        @level = level_name
        @type = type_name
        @elev = Project.level(level_name)['elev'].to_f
        @depth = Framing::ACTUAL[Project.wall_type(type_name)['stud']]
      end

      def activate
        Builder.close_edits
        Views.save
        Views.plan(@elev) # lay walls out like the floor plan
        @ip = Sketchup::InputPoint.new
        reset_chain
        update_ui
      end

      def deactivate(view)
        Views.restore # back to the 3D view for framing
        view.invalidate
      end

      def resume(view)
        update_ui
        view.invalidate
      end

      def reset_chain
        @start = nil
        @end = nil
        @prev = nil        # last wall group placed in this chain
        @first = nil       # first wall group of this chain
        @first_pt = nil    # where the chain started (for closing the loop)
        @lock = nil        # locked direction (Shift)
        @snap = nil        # :x, :y, :prev, :perp, :point, or nil
      end

      def onCancel(_reason, view)
        placed = !@prev.nil? || @placed_any
        reset_chain
        update_ui
        view.invalidate
        # Done laying out walls - next step is the corners (still in plan view)
        Sketchup.active_model.select_tool(CornerTool.new(@level)) if placed
      end

      # ---------- picking ----------

      def plane
        [Geom::Point3d.new(0, 0, @elev), Z_AXIS]
      end

      def on_level(pt)
        Geom::Point3d.new(pt.x, pt.y, @elev)
      end

      # Where the cursor hits the level datum plane.
      def ray_point(view, x, y)
        ray = view.pickray(x, y)
        pt = Geom.intersect_line_plane(ray, plane)
        pt ? on_level(pt) : nil
      end

      def pick(view, x, y)
        if @start
          @ip.pick(view, x, y, Sketchup::InputPoint.new(@start))
        else
          @ip.pick(view, x, y)
        end
        @snap = nil
        @face = nil
        # Snapped to a real point (endpoint, midpoint, intersection): use it exactly.
        if @ip.valid? && @ip.degrees_of_freedom.zero?
          @snap = :point
          return on_level(@ip.position)
        end
        # Near the face of a wall already drawn: pull a tape along it
        raw = ray_point(view, x, y)
        if raw && (f = face_at(raw))
          @face = f
          @snap = :face
          if @start
            dir_pt = direction_snap(raw)
            hit = @snap == :face ? nil : face_cross(f, dir_pt)
            @snap = :face
            return hit || f[:pt]
          end
          return f[:pt]
        end
        # On a guide line or edge lying on this level: use it as-is.
        if @ip.valid? && @ip.degrees_of_freedom == 1 && (@ip.position.z - @elev).abs < 0.5
          @snap = :guide
          return on_level(@ip.position)
        end
        pt = ray_point(view, x, y) || on_level(@ip.position)
        return pt unless @start
        direction_snap(pt)
      end

      # ---------- measuring off walls already drawn ----------

      FACE_TOL = 6.0

      # The wall face nearest pt (within 6"), with a tape hooked on the nearest
      # inside corner (where another wall crosses this face) or the face's end.
      def face_at(pt)
        best = nil
        Builder.all_walls.each do |w|
          p = Builder.params_of(w)
          next unless p['level'] == @level
          inv = w.transformation.inverse
          lp = pt.transform(inv)
          len = p['length'].to_f
          d = Framing.depth(p)
          next if lp.x < -1 || lp.x > len + 1
          [0.0, d].each do |yf|
            dist = (lp.y - yf).abs
            next if dist > FACE_TOL
            next if @start && (@start.transform(inv).y - yf).abs < 0.1 # not the face you started on
            best = [dist, w, p, yf, [[lp.x, 0].max, len].min] if best.nil? || dist < best[0]
          end
        end
        return nil unless best
        _, w, p, yf, lx = best
        hooks = face_hooks(w, p, yf)
        hook = hooks.min_by { |h| (h - lx).abs }
        tr = w.transformation
        { wall: w, params: p, yf: yf, lx: lx, hook: hook, reading: (lx - hook).abs, dir: lx >= hook ? 1 : -1,
          pt: on_level(Geom::Point3d.new(lx, yf, 0).transform(tr)),
          hook_pt: on_level(Geom::Point3d.new(hook, yf, 0).transform(tr)) }
      end

      # Where other walls' faces cross this face (inside corners), plus its ends.
      def face_hooks(w, p, yf)
        len = p['length'].to_f
        inv = w.transformation.inverse
        hooks = [0.0, len]
        Builder.all_walls.each do |o|
          next if o == w
          op = Builder.params_of(o)
          next unless op['level'] == @level
          olen = op['length'].to_f
          [0.0, Framing.depth(op)].each do |oy|
            a = Geom::Point3d.new(0, oy, 0).transform(o.transformation).transform(inv)
            b = Geom::Point3d.new(olen, oy, 0).transform(o.transformation).transform(inv)
            next if (b.y - a.y).abs < 1e-6 # parallel
            t = (yf - a.y) / (b.y - a.y)
            next if t < -0.01 || t > 1.01
            x = a.x + (b.x - a.x) * t
            hooks << x if x > -0.5 && x < len + 0.5
          end
        end
        hooks.uniq { |h| (h * 16).round }
      end

      # Where the line from @start (through pt) crosses the face f.
      def face_cross(f, pt)
        inv = f[:wall].transformation.inverse
        a = @start.transform(inv)
        b = pt.transform(inv)
        return nil if (b.y - a.y).abs < 1e-6
        t = (f[:yf] - a.y) / (b.y - a.y)
        return nil if t <= 0
        x = a.x + (b.x - a.x) * t
        return nil if x < -1 || x > f[:params]['length'].to_f + 1
        on_level(Geom::Point3d.new(x, f[:yf], 0).transform(f[:wall].transformation))
      end

      # Snap the direction from @start to model X/Y, the previous wall,
      # or square to the previous wall. Shift-lock overrides.
      def direction_snap(pt)
        v = pt - @start
        v.z = 0
        return pt if v.length < 0.01
        if @lock
          @snap = :lock
          return project(pt, @lock)
        end
        cands = [[:x, X_AXIS], [:y, Y_AXIS]]
        if @prev
          pd = @prev.transformation.xaxis
          cands << [:prev, Geom::Vector3d.new(pd.x, pd.y, 0)]
          cands << [:perp, Geom::Vector3d.new(-pd.y, pd.x, 0)]
        end
        best = nil
        cands.each do |name, dir|
          a = v.angle_between(dir)
          a = Math::PI - a if a > Math::PI / 2
          deg = a * 180 / Math::PI
          best = [deg, name, dir] if deg <= SNAP_DEG && (best.nil? || deg < best[0])
        end
        return pt unless best
        @snap = best[1]
        project(pt, best[2])
      end

      def project(pt, dir)
        d = dir.clone
        d.z = 0
        d.normalize!
        v = pt - @start
        len = v.x * d.x + v.y * d.y
        @start.offset(d, len)
      end

      # ---------- events ----------

      def onMouseMove(_flags, x, y, view)
        pt = pick(view, x, y)
        if @start
          @end = pt
          Sketchup.vcb_value = @start.distance(@end).to_l.to_s
        else
          @end = nil
        end
        view.tooltip = @ip.tooltip if @ip.valid? && @snap == :point
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        pt = pick(view, x, y)
        if @start.nil?
          @start = pt
          @first_pt = pt
          update_ui
        else
          finish_wall(pt, view)
        end
      end

      def onKeyDown(key, _repeat, _flags, view)
        if key == 9 # Tab: build the wall on the other side of the line
          @flip = !@flip
          view.invalidate
          return true
        end
        if key == VK_SHIFT && @start && @end && (@end - @start).length > 0.01
          d = @end - @start
          d.z = 0
          @lock = d.normalize
        end
        false
      end

      def onKeyUp(key, _repeat, _flags, view)
        return unless key == VK_SHIFT
        @lock = nil
        view.invalidate
      end

      def onUserText(text, view)
        if @start.nil? && @face
          d = Framing.parse_len(text)
          return UI.beep unless d && d >= 0
          f = @face
          lx = f[:hook] + f[:dir] * d
          pt = on_level(Geom::Point3d.new(lx, f[:yf], 0).transform(f[:wall].transformation))
          @start = pt
          @first_pt = pt
          @first = nil
          @prev = nil
          Sketchup.status_text = "Start set #{Framing.fmt_len(d)} from the corner on #{f[:params]['id']}. Now draw the wall across - it snaps to the far wall's face."
          view.invalidate
          return
        end
        return unless @start && @end
        len = text.to_l
        dir = @end - @start
        dir.z = 0
        return UI.beep if dir.length.zero?
        dir.length = len
        finish_wall(@start.offset(dir), view)
      rescue ArgumentError
        UI.beep
      end

      # ---------- placing ----------

      def finish_wall(pt, view)
        closing = @first && pt.distance(@first_pt) <= CLOSE_TOL
        pt = @first_pt if closing
        model = Sketchup.active_model
        model.start_operation('Place Wall', true)
        g = @flip ? Builder.create_wall(pt, @start, @level, @type) : Builder.create_wall(@start, pt, @level, @type)
        Builder.resolve_layout(@level) if g
        model.commit_operation
        unless g
          UI.beep
          return
        end
        @placed_any = true
        if closing
          reset_chain
          Sketchup.status_text = 'Loop closed. Draw more walls, or press Esc to set the corners.'
        else
          @first ||= g
          @prev = g
          @start = pt
          @end = nil
          @lock = nil
          update_ui
        end
        view.invalidate
      end

      # ---------- drawing ----------

      SNAP_COLORS = { x: 'red', y: 'green', prev: 'magenta', perp: 'magenta', lock: 'black', point: 'black', guide: 'black', face: 'orange' }.freeze

      def draw(view)
        draw_ids(view)
        @ip.draw(view) if @ip.valid? && @snap == :point
        if @face && @start.nil?
          view.line_width = 6
          view.drawing_color = Sketchup::Color.new(240, 200, 0)
          view.draw(GL_LINES, @face[:hook_pt], @face[:pt])
          view.draw_text(view.screen_coords(@face[:pt]),
                         "  #{Framing.fmt_len(@face[:reading])} from the corner on #{@face[:params]['id']} - type a reading + Enter, or click")
        end
        return unless @start && @end
        dir = @end - @start
        dir.z = 0
        return if dir.length.zero?
        view.line_width = @snap && @snap != :point ? 3 : 2
        view.drawing_color = SNAP_COLORS[@snap] || 'black'
        view.draw(GL_LINES, @start, @end)
        left = Z_AXIS * dir.normalize
        left.reverse! if @flip
        left.length = @depth
        view.drawing_color = 'gray'
        view.line_stipple = '-'
        view.draw(GL_LINE_LOOP, [@start, @end, @end.offset(left), @start.offset(left)])
        view.line_stipple = ''
        closing = @first && @end.distance(@first_pt) <= CLOSE_TOL ? '  (closes the loop)' : ''
        label = "  #{@type}: #{Framing.fmt_len(dir.length.to_f)}#{closing}"
        label += "  |  #{snap_name}" if @snap && @snap != :point
        label += '  |  Tab: build on the other side'
        view.draw_text(view.screen_coords(@end), label)
      end

      # Wall IDs on the plan
      def draw_ids(view)
        Builder.all_walls.each do |w|
          p = Builder.params_of(w)
          next unless p['level'] == @level
          c = Geom::Point3d.new(p['length'].to_f / 2, Framing.depth(p) / 2, 0).transform(w.transformation)
          view.draw_text(view.screen_coords(c), p['id'])
        end
      rescue StandardError
        nil
      end

      def snap_name
        { x: 'on red axis', y: 'on green axis', prev: 'parallel to last wall',
          perp: 'square to last wall', lock: 'locked (Shift)', guide: 'on guide/edge',
          face: @face ? "on #{@face[:params]['id']} face" : 'on wall face' }[@snap]
      end

      def getExtents
        bb = Geom::BoundingBox.new
        bb.add(@start) if @start
        bb.add(@end) if @end
        bb
      end

      def update_ui
        Sketchup.vcb_label = 'Length'
        Sketchup.status_text =
          if @start
            "#{@type}: click the next corner or type a length. Shift locks direction. Click the first point to close the loop. Esc when done."
          else
            "#{@type} on #{@level}: lay out walls like the floor plan. Exterior: draw on the outside face line (framing builds to the LEFT). " \
              'Interior: hover the face of a wall already drawn, type your plan dimension from the corner + Enter, then draw across.'
          end
      end
    end
  end
end
