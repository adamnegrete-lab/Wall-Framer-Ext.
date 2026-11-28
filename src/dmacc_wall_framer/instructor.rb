module DMACC
  module WallFramer
    # Instructor shortcuts (behind the Project Setup password): skip ahead to the
    # step you want to test or demo. Students never see these.
    module Instructor
      module_function

      def ok?
        return true if Project.instructor?
        UI.messagebox('Instructor only. Unlock in Project Setup with the instructor password first.')
        false
      end

      def group_or_say
        g = Dialogs.focus_group
        UI.messagebox('Place some walls first.') unless g
        g
      end

      # Fill the wall you're on with the right answers (openings stay as entered).
      def fill_wall
        return unless ok?
        g = group_or_say or return
        p = Builder.params_of(g)
        return UI.messagebox("#{p['id']}: set the corners first (Corners tool).") if Builder.stage(p) == 'corners'
        Dialogs.operation("Instructor: Fill #{p['id']}") do
          Builder.refresh_corner_needs(p['level'])
          Builder.set_flag(g, 'openings_done', true) unless p['openings_done']
          CutList.fill(g)
        end
        done(g)
      end

      # Frame every wall on this floor: filled, standing on its line. Openings stay as
      # entered; a wall with none entered gets none. Double plates and inspection are left.
      def frame_floor
        return unless ok?
        g = group_or_say or return
        lv = Builder.params_of(g)['level']
        ws = Builder.all_walls.select { |w| Builder.params_of(w)['level'] == lv }
        open = ws.select { |w| Builder.stage(Builder.params_of(w)) == 'corners' }
        return UI.messagebox("Set the corners first (Corners tool): #{open.map { |w| Builder.params_of(w)['id'] }.join(', ')}") if open.any?
        Dialogs.operation("Instructor: Frame #{lv}") do
          Builder.refresh_corner_needs(lv)
          ws.each do |w|
            Builder.stand_up(w) if Builder.on_table?(w)
            Builder.set_flag(w, 'openings_done', true) unless Builder.params_of(w)['openings_done']
            CutList.fill(w)
          end
        end
        Views.restore
        left = ws.reject { |w| Builder.stage(Builder.params_of(w)) == 'framed' }.map { |w| Builder.params_of(w)['id'] }
        Sketchup.status_text = left.empty? ? "Every wall on #{lv} is framed and standing. Double top plates are next." : "Couldn't finish: #{left.join(', ')}."
        done(g)
      end

      # Everything framed on this wall comes out; its openings stay entered.
      def reset_wall
        return unless ok?
        g = group_or_say or return
        p = Builder.params_of(g)
        return unless UI.messagebox("Take every piece out of #{p['id']} and empty its cut list? Its openings stay entered.", MB_YESNO) == IDYES
        Dialogs.operation("Instructor: Reset #{p['id']}") do
          Builder.forget_dtp([p['id']])
          p = Builder.params_of(g)
          p['entries'] = {}
          p['cutlist'] = {}
          p['marks'] = []
          %w[oc corners last_inspection].each { |k| p.delete(k) }
          p['flags'] = []
          Builder.set_params(g, p)
          Builder.rebuild(g)
        end
        done(g)
      end

      # A small house to test with: 24' x 16', walls placed counterclockwise from the
      # front (W-101), corners set, one window, one door, one partition teeing in.
      def draw_test_house
        return unless ok?
        unless Builder.all_walls.empty?
          return UI.messagebox('Draw Test House needs an empty model - open a new one (File > New) first.')
        end
        d = Project.data
        lv = d['levels'].first['name']
        ext = (d['wall_types'].find { |t| t['function'].to_s.downcase.start_with?('ext') } || d['wall_types'].first)['name']
        int = (d['wall_types'].find { |t| t['function'].to_s.downcase.start_with?('int') } || d['wall_types'].first)['name']
        pts = [[0, 0], [288, 0], [288, 192], [0, 192]].map { |x, y| Geom::Point3d.new(x, y, 0) }
        Dialogs.operation('Instructor: Draw Test House') do
          walls = pts.each_with_index.map { |a, i| Builder.create_wall(a, pts[(i + 1) % 4], lv, ext) }
          Builder.resolve_layout(lv)
          # front and back run through, the sides butt
          walls.each_with_index { |w, i| Builder.set_run(w, i.even? ? 'through' : 'butt') }
          Builder.resolve_layout(lv)
          dep = Framing.depth(Builder.params_of(walls[0]))
          Builder.create_wall(Geom::Point3d.new(144, dep, 0), Geom::Point3d.new(144, 192 - dep, 0), lv, int)
          Builder.resolve_layout(lv)
          Builder.refresh_corner_needs(lv)
          add_opening(walls[0], 'W1', 'Window', 60, 36, 48, 82.5)
          add_opening(walls[2], 'D1', 'Door', 72, 38, 82.5, nil)
        end
        Views.plan(0)
        Sketchup.status_text = "Test house drawn: #{Builder.all_walls.map { |w| Builder.params_of(w)['id'] }.join(', ')}. Click Frame to start."
        Dialogs.refresh_yard
      end

      def add_opening(g, mark, type, center, w, h, head)
        p = Builder.params_of(g)
        hdr = p['bearing'] ? '2x10' : Framing::FLAT
        op = { 'mark' => mark, 'type' => type, 'x' => center.to_f - w / 2.0, 'width' => w.to_f, 'header' => hdr }
             .merge(Framing.opening_from_ro(type, h.to_f, (head || h).to_f))
        op['plies'] = 2 if hdr != Framing::FLAT
        p['openings'] = p['openings'] + [op]
        Builder.set_params(g, p)
        Builder.rebuild(g)
      end

      def done(g)
        Dialogs.focus_wall(Builder.params_of(g)['id']) if g && !g.deleted?
        Dialogs.refresh_frame
        Dialogs.refresh_yard
        Sketchup.active_model.active_view.invalidate
      end
    end
  end
end
