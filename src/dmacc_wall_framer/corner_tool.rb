module DMACC
  module WallFramer
    # Plan-view corners step. Click each wall to set whether it RUNS THROUGH its
    # corners (plates go all the way to the outside corner) or BUTTS (stops
    # against the other wall). Every corner trims or extends as you go.
    class CornerTool
      COLORS = { 'through' => 'orange', 'butt' => 'blue', nil => 'gray' }.freeze
      HELP = "Corners - which walls run through?\n\n" \
             "At every corner, one wall RUNS THROUGH: its plates go all the way to the outside corner.\n" \
             "The other wall BUTTS: it stops against the first wall, so it's shorter by that wall's thickness " \
             "(5-1/2\" for a 2x6 wall).\n\n" \
             "Click a wall to make it run through. Click it again to make it butt.\n" \
             "Orange = runs through, blue = butts, gray = not set. Walls that land on the side of another wall " \
             "(tees) butt on their own.\n\n" \
             'Check the plan notes. Usually the long walls run through and the walls between them butt.'

      def initialize(level = nil)
        @level = level
      end

      def activate
        Builder.close_edits
        @level ||= (g = Dialogs.focus_group) ? Builder.params_of(g)['level'] : Project.data['levels'].first['name']
        @elev = Project.level(@level)['elev'].to_f
        Views.save unless Views.instance_variable_get(:@saved)
        Views.plan(@elev)
        @hover = nil
        unless Sketchup.read_default('DMACC_WallFramer', 'seen_corner_help2', false)
          Sketchup.write_default('DMACC_WallFramer', 'seen_corner_help2', true)
          UI.messagebox(HELP)
        end
        update_ui
      end

      def deactivate(view)
        Views.restore
        view.invalidate
      end

      def resume(view)
        update_ui
        view.invalidate
      end

      def walls
        Builder.all_walls.select { |w| Builder.params_of(w)['level'] == @level }
      end

      # ---------- picking ----------

      def pick(view, x, y)
        ray = view.pickray(x, y)
        @hover = nil
        best = nil
        walls.each do |w|
          p = Builder.params_of(w)
          inv = w.transformation.inverse
          o = ray[0].transform(inv)
          v = ray[1].transform(inv)
          next if v.z.abs < 1e-9
          [0.0, p['height'].to_f].each do |z| # floor or top of wall
            t = (z - o.z) / v.z
            next if t <= 0
            lx = o.x + v.x * t
            ly = o.y + v.y * t
            d = Framing.depth(p)
            next unless lx >= -3 && lx <= p['length'].to_f + 3 && ly >= -3 && ly <= d + 3
            best = [t, w] if best.nil? || t < best[0]
          end
        end
        @hover = best && best[1]
      end

      def onMouseMove(_flags, x, y, view)
        pick(view, x, y)
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        pick(view, x, y)
        return unless @hover
        p = Builder.params_of(@hover)
        run = p['run'] == 'through' ? 'butt' : 'through'
        hit = Builder.affected_by_run(@hover, run).map { |id| Builder.find_wall(id) }.compact.select { |w| Builder.framed?(Builder.params_of(w)) }
        unless hit.empty?
          ids = hit.map { |w| Builder.params_of(w)['id'] }.join(', ')
          return unless UI.messagebox("Changing this corner changes the length of #{ids}, which already has framing. " \
                                      "That framing comes out (onto the offcut pile). Go ahead?", MB_YESNO) == IDYES
        end
        model = Sketchup.active_model
        model.start_operation('Set Corner', true)
        Builder.set_run(@hover, run)
        model.commit_operation
        Dialogs.refresh_yard
        update_ui
        view.invalidate
      end

      # Right-click: which end the stud layout pulls from.
      def getMenu(menu, _flags = nil, x = nil, y = nil, view = nil)
        pick(view, x, y) if view && x
        return unless @hover
        w = @hover
        p = Builder.params_of(w)
        other = Framing.from_end?(p) ? 'the wall start' : 'the wall end'
        menu.add_item("#{p['id']}: pull stud layout from #{other}") do
          if (p['oc'] || (p['marks'] || []).any?) &&
             UI.messagebox("#{p['id']}'s studs are already laid out. Changing the layout end pulls the studs, cripples " \
                           'and header blocks (onto the offcut pile). Go ahead?', MB_YESNO) != IDYES
            next
          end
          m = Sketchup.active_model
          m.start_operation('Layout End', true)
          Builder.set_layout_from(w, !Framing.from_end?(p))
          m.commit_operation
          Dialogs.refresh_yard
          Dialogs.refresh_frame
          m.active_view.invalidate
        end
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
        WallFramer.frame_tool
      end

      # ---------- drawing ----------

      def draw(view)
        _out, corners = Builder.plan_corners(@level)
        walls.each do |w|
          p = Builder.params_of(w)
          d = Framing.depth(p)
          len = p['length'].to_f
          pts = [[0, 0], [len, 0], [len, d], [0, d]].map { |x, y| Geom::Point3d.new(x, y, 0).transform(w.transformation) }
          view.line_width = w == @hover ? 6 : 4
          view.drawing_color = COLORS[p['run']]
          view.draw(GL_LINE_LOOP, pts)
          label = case p['run']
                  when 'through' then 'RUNS THROUGH'
                  when 'butt' then 'BUTTS'
                  else 'not set'
                  end
          label += "  #{Framing.fmt_len(len)}"
          label += '  <- click: ' + (p['run'] == 'through' ? 'butts' : 'runs through') if w == @hover
          c = Geom::Point3d.new(len / 2, d / 2, 0).transform(w.transformation)
          view.draw_text(view.screen_coords(c), "#{p['id']}  #{label}")
          # layout end: where the tape hooks for the stud layout
          lx = Framing.from_end?(p) ? len : 0.0
          dir = Framing.from_end?(p) ? -1 : 1
          arrow = [[lx, d / 2], [lx + dir * 18, d / 2], [lx + dir * 12, d / 2 - 3], [lx + dir * 18, d / 2], [lx + dir * 12, d / 2 + 3]]
                  .map { |ax, ay| Geom::Point3d.new(ax, ay, 0).transform(w.transformation) }
          view.line_width = 2
          view.drawing_color = 'black'
          view.draw(GL_LINE_STRIP, arrow)
          view.draw_text(view.screen_coords(arrow[1]), ' layout') if w == @hover
        end
        corners.each do |c|
          at = view.screen_coords(Geom::Point3d.new(c['at'][0], c['at'][1], @elev))
          case c['status']
          when 'conflict'
            both = Builder.params_of(Builder.find_wall(c['walls'][0]))['run'] == 'through' ? 'run through' : 'butt'
            view.drawing_color = 'red'
            view.draw_text(at, "  #{c['walls'].join(' & ')} both #{both} - one has to #{both == 'butt' ? 'run through' : 'butt'}")
          when 'unset'
            view.draw_text(at, '  ?')
          end
        end
      end

      def getExtents
        bb = Geom::BoundingBox.new
        walls.each { |w| bb.add(w.bounds) }
        bb
      end

      def update_ui
        _out, corners = Builder.plan_corners(@level)
        open = corners.count { |c| %w[unset conflict].include?(c['status']) }
        Sketchup.status_text =
          if open.zero?
            'All corners are set. Right-click a wall to pull its stud layout from the other end (the arrow shows the layout end) - line up front and back walls. Esc (or Frame) to start framing.'
          else
            "CORNERS: click a wall to make it run through, again to make it butt. #{open} corner#{open == 1 ? '' : 's'} left to settle. " \
              'Right-click a wall to pull its stud layout from the other end.'
          end
      end
    end
  end
end
