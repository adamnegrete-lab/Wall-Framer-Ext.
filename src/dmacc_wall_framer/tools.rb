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
        # Snapped to a real point (endpoint, midpoint, intersection): use it exactly.
        if @ip.valid? && @ip.degrees_of_freedom.zero?
          @snap = :point
          return on_level(@ip.position)
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
        g = Builder.create_wall(@start, pt, @level, @type)
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

      SNAP_COLORS = { x: 'red', y: 'green', prev: 'magenta', perp: 'magenta', lock: 'black', point: 'black', guide: 'black' }.freeze

      def draw(view)
        draw_ids(view)
        @ip.draw(view) if @ip.valid? && @snap == :point
        return unless @start && @end
        dir = @end - @start
        dir.z = 0
        return if dir.length.zero?
        view.line_width = @snap && @snap != :point ? 3 : 2
        view.drawing_color = SNAP_COLORS[@snap] || 'black'
        view.draw(GL_LINES, @start, @end)
        left = Z_AXIS * dir.normalize
        left.length = @depth
        view.drawing_color = 'gray'
        view.line_stipple = '-'
        view.draw(GL_LINE_LOOP, [@start, @end, @end.offset(left), @start.offset(left)])
        view.line_stipple = ''
        closing = @first && @end.distance(@first_pt) <= CLOSE_TOL ? '  (closes the loop)' : ''
        label = "  #{@type}: #{Framing.fmt_len(dir.length.to_f)}#{closing}"
        label += "  |  #{snap_name}" if @snap && @snap != :point
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
          perp: 'square to last wall', lock: 'locked (Shift)', guide: 'on guide/edge' }[@snap]
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
            "#{@type} on #{@level}: lay out walls like the floor plan. Click the start point - draw on the outside face line; framing builds to the LEFT."
          end
      end
    end
  end
end
