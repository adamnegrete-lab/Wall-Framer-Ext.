module DMACC
  module WallFramer
    # Camera helpers: plan (top) view for laying out walls, and back to 3D.
    module Views
      class << self
        def save
          c = Sketchup.active_model.active_view.camera
          @saved = [c.eye.clone, c.target.clone, c.up.clone, c.perspective?]
        rescue StandardError
          @saved = nil
        end

        def restore
          return unless @saved
          eye, target, up, persp = @saved
          cam = Sketchup::Camera.new(eye, target, up)
          cam.perspective = persp
          Sketchup.active_model.active_view.camera = cam
          @saved = nil
        rescue StandardError
          nil
        end

        # Straight down on a wall lying on the framing table, bottom plate toward you.
        def table(g)
          save unless @saved
          p = Builder.params_of(g)
          len = p['length'].to_f
          h = p['height'].to_f
          c = Geom::Point3d.new(len / 2.0, 0, h / 2.0).transform(g.transformation)
          view = Sketchup.active_model.active_view
          cam = Sketchup::Camera.new(Geom::Point3d.new(c.x, c.y, c.z + 3000), c, Y_AXIS)
          cam.perspective = false
          cam.height = [len, h].max * 1.25 if cam.respond_to?(:height=)
          view.camera = cam
        rescue StandardError => e
          puts "table view: #{e.message}"
        end

        # Orthographic view straight down, like a floor plan.
        def plan(elev = 0.0)
          view = Sketchup.active_model.active_view
          walls = Builder.all_walls
          bb = Geom::BoundingBox.new
          walls.each { |w| bb.add(w.bounds) }
          c = walls.empty? || bb.empty? ? Geom::Point3d.new(0, 0, elev) : bb.center
          cam = Sketchup::Camera.new(Geom::Point3d.new(c.x, c.y, elev + 3000), Geom::Point3d.new(c.x, c.y, elev), Y_AXIS)
          cam.perspective = false
          view.camera = cam
          if walls.empty?
            cam.height = 480 if cam.respond_to?(:height=) # about 40' across
          else
            view.zoom(walls)
            cam = view.camera
            cam.height = cam.height * 1.4 if cam.respond_to?(:height=) # leave room to draw past the walls
          end
        rescue StandardError => e
          puts "plan view: #{e.message}"
        end
      end
    end
  end
end
