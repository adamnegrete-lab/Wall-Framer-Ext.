module DMACC
  module WallFramer
    # Place walls by clicking points. Walls chain: each new wall starts where
    # the last one ended, until you press Esc or close the loop.
    #
    #   Click        start / end of a wall
    #   Type length  exact length in the current direction (Enter)
    #   Tab          toggle this wall: RUNS THROUGH the corner / BUTTS
    #   Shift (hold) lock the current direction
    #   Esc          stop chaining
    #
    # Picked points are always dropped onto the level datum, and inference is
    # always taken from the model axes (not from the wall you just placed).
    class DrawWallTool
      SNAP_DEG = 3.0       # snap to an axis / previous wall within this angle
      CLOSE_TOL = 0.5      # end within 1/2" of the chain start = close the loop
      VK_TAB_KEY = 9

      def initialize(level_name, type_name)
        @level = level_name
        @type = type_name
        @elev = Project.level(level_name)['elev'].to_f
        @depth = Framing::ACTUAL[Project.wall_type(type_name)['stud']]
        @through = false
      end

      def activate
        Builder.close_edits
        @ip = Sketchup::InputPoint.new
        reset_chain
        update_ui
      end

      def deactivate(view)
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
        # Done placing walls - pick up the framing tool so a click on a wall frames it
        if placed && Project.settings['guided']
          Dialogs.open_yard
          Dialogs.activate_tool
          Sketchup.status_text = 'Framing: click the bottom plate spot on a wall to cut and set your plates.'
        end
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
          @hover = pt
        end
        view.tooltip = @ip.tooltip if @ip.valid? && @snap == :point
        view.invalidate
      end

      CORNER_HELP = "Corners - which wall runs through?\n\n" \
                    "At every corner, one wall RUNS THROUGH: its plates go all the way to the outside corner.\n" \
                    "The other wall BUTTS: it stops against the first wall, so it's shorter by that wall's thickness " \
                    "(5-1/2\" for a 2x6 wall).\n\n" \
                    "Check the plan notes for which walls run through. Press Tab before you click the corner to switch - " \
                    "the wall that runs through is outlined in orange, and the label shows the length you'll get either way."

      def corner_help_once
        return if Sketchup.read_default('DMACC_WallFramer', 'seen_corner_help', false)
        Sketchup.write_default('DMACC_WallFramer', 'seen_corner_help', true)
        UI.messagebox(CORNER_HELP)
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
        elsif key == VK_TAB_KEY
          @through = !@through
          update_ui
          view.invalidate
          return true
        end
        false
      end

      def onKeyUp(key, _repeat, _flags, view)
        return unless key == VK_SHIFT
        @lock = nil
        view.invalidate
      end

      # Type a length (or T / B to switch through / butt).
      def onUserText(text, view)
        s = text.strip.downcase
        if %w[t through].include?(s) || %w[b butt].include?(s)
          @through = s.start_with?('t')
          update_ui
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
        notes = []
        model.start_operation('Place Wall', true)
        g = Builder.create_wall(@start, pt, @level, @type)
        if g
          notes.concat(join(@prev, g, @through ? :next : :prev)) if @prev
          notes.concat(join(g, @first, @through ? :prev : :next)) if closing
          Builder.refresh_corner_needs(@level)
        end
        model.commit_operation
        unless g
          UI.beep
          return
        end
        @placed_any = true
        model.selection.clear
        model.selection.add(g)
        UI.messagebox("Corner not trimmed:\n" + notes.uniq.join("\n")) unless notes.empty?
        if closing
          reset_chain
          Sketchup.status_text = 'Loop closed. Click to start a new run of walls.'
        else
          @first ||= g
          @prev = g
          corner_help_once # before their first corner decision
          @start = pt
          @end = nil
          @lock = nil
          update_ui
        end
        view.invalidate
      end

      # prev's end meets nxt's start. through = :prev or :next.
      def join(prev, nxt, through)
        dp = Framing.depth(Builder.params_of(prev))
        dn = Framing.depth(Builder.params_of(nxt))
        op, who, delta = Corners.adjust(Builder.plan_dir(prev), Builder.plan_dir(nxt), dp, dn, through)
        target = who == :prev ? prev : nxt
        errs = case op
               when :shift_start then Builder.shift_start(target, delta)
               when :extend_end then Builder.extend_end(target, delta)
               else return ['Walls meet at an angle that is not square - check the corner by hand.']
               end
        errs.map { |e| "#{Builder.params_of(target)['id']}: #{e}" }
      end

      # ---------- drawing ----------

      SNAP_COLORS = { x: 'red', y: 'green', prev: 'magenta', perp: 'magenta', lock: 'black', point: 'black', guide: 'black' }.freeze

      def draw(view)
        @ip.draw(view) if @ip.valid? && @snap == :point
        return unless @start && @end
        dir = @end - @start
        dir.z = 0
        return if dir.length.zero?
        view.line_width = @snap && @snap != :point ? 3 : 2
        view.drawing_color = SNAP_COLORS[@snap] || 'black'
        view.draw(GL_LINES, @start, @end)

        pv = preview(@through)
        # previous wall (and the first wall when closing) near the shared corner
        pv[:others].each do |o|
          rect(view, o[:pts], o[:through] ? 'orange' : 'gray', o[:through] ? 4 : 2, !o[:through])
          view.draw_text(view.screen_coords(o[:label_at]), "  #{o[:label]}") if o[:label]
        end
        # this wall, trimmed or extended for its corners
        rect(view, pv[:pts], @through && pv[:corner] ? 'orange' : 'gray', @through && pv[:corner] ? 4 : 2, !(@through && pv[:corner]))

        closing = pv[:closing] ? '  (closes the loop)' : ''
        label = "  #{@type}: #{Framing.fmt_len(pv[:len])}#{closing}"
        if pv[:corner]
          alt = preview(!@through)
          label += "  |  #{@through ? 'RUNS THROUGH' : 'BUTTS'} at the corner  (Tab: #{@through ? 'butts' : 'runs through'} = #{Framing.fmt_len(alt[:len])})"
        end
        label += '  (far end is set by the next wall)' if pv[:corner] && !pv[:closing]
        label += "  |  #{snap_name}" if @snap && @snap != :point
        view.draw_text(view.screen_coords(@end), label)
      end

      def rect(view, pts, color, width, dashed)
        view.line_width = width
        view.drawing_color = color
        view.line_stipple = dashed ? '-' : ''
        view.draw(GL_LINE_LOOP, pts)
        view.line_stipple = ''
      end

      # Footprint corners: start point on the face line, unit dir, length, depth (left side)
      def footprint(o, dir, len, depth)
        d = Geom::Vector3d.new(dir.x, dir.y, 0)
        d.normalize!
        left = Z_AXIS * d
        left.length = depth
        e = o.offset(d, len)
        [o, e, e.offset(left), o.offset(left)]
      end

      # What the corners will do to this wall and its neighbors if it's placed now.
      def preview(through_self)
        dir = @end - @start
        dir.z = 0
        nd = dir.normalize
        start = @start
        len = dir.length.to_f
        others = []
        corner = false
        closing = @first && @end.distance(@first_pt) <= CLOSE_TOL
        if @prev
          pp = Builder.params_of(@prev)
          pd = @prev.transformation.xaxis
          dp = Framing.depth(pp)
          op, who, delta = Corners.adjust([pd.x, pd.y], [nd.x, nd.y], dp, @depth, through_self ? :next : :prev)
          unless op == :none
            corner = true
            plen = pp['length'].to_f
            if op == :shift_start
              start = start.offset(nd, delta)
              len -= delta
            else
              plen += delta
            end
            po = @prev.transformation.origin
            tail = [plen, 36.0].min
            pts = footprint(po.offset(pd, plen - tail), pd, tail, dp)
            others << { pts: pts, through: !through_self, label_at: @start,
                        label: through_self ? "this wall runs through - #{pp['id']} butts into it" : "#{pp['id']} runs through - this wall butts into it" }
          end
        end
        if closing
          fp = Builder.params_of(@first)
          fd = @first.transformation.xaxis
          df = Framing.depth(fp)
          op, who, delta = Corners.adjust([nd.x, nd.y], [fd.x, fd.y], @depth, df, through_self ? :prev : :next)
          unless op == :none
            corner = true
            fo = @first.transformation.origin
            flen = fp['length'].to_f
            if op == :extend_end
              len += delta
            else
              fo = fo.offset(fd, delta)
              flen -= delta
            end
            pts = footprint(fo, fd, [flen, 36.0].min, df)
            others << { pts: pts, through: !through_self, label_at: @end,
                        label: through_self ? "this wall runs through - #{fp['id']} butts into it" : "#{fp['id']} runs through - this wall butts into it" }
          end
        end
        { pts: footprint(start, nd, len, @depth), len: len, others: others, corner: corner, closing: closing }
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
        corner = @through ? 'RUNS THROUGH' : 'BUTTS'
        Sketchup.status_text =
          if @start
            "#{@type}: click the next corner or type a length. Tab = this wall #{@through ? 'BUTTS' : 'RUNS THROUGH'} instead " \
              '(the wall that runs through goes to the outside corner - orange). Shift locks direction. Click the first point to close. Esc to stop.'
          else
            "#{@type} on #{@level}: click the start point. Draw on the face line - framing builds to the LEFT."
          end
      end
    end
  end
end
