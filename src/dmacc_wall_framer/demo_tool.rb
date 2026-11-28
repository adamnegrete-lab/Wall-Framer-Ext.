module DMACC
  module WallFramer
    # Demo tool (cat's paw): hover a framing member, click to pull it. Pulling
    # something another piece rests on asks first. Also takes off double plate
    # pieces. Esc = Frame.
    class DemoTool < GuidedTool
      def activate
        super
        @hit = nil
        Sketchup.status_text = 'DEMO: hover a piece and click to pull it. Esc goes back to framing.'
      end

      def onUserText(_text, _view)
        UI.beep
      end

      def onCancel(_reason, _view)
        WallFramer.frame_tool
      end

      def onMouseMove(_flags, x, y, view)
        pick(view, x, y)
        update_ui
        view.invalidate
      end

      # @hit = [:piece, group, slot] | [:dtp, group, span]
      def pick(view, x, y)
        ray = view.pickray(x, y)
        @hit = nil
        face = nil
        Builder.all_walls.each do |g|
          p = Builder.params_of(g)
          h = wall_hit(g, p, ray)
          face = [h[0], g, p, h[1], h[2]] if h && (face.nil? || h[0] < face[0])
        end
        # double plate pieces, seen from above
        top = Builder.all_walls.map { |g| top_hit(g, ray) }.compact.min_by { |h| h[1] }
        if top && (face.nil? || top[1] <= face[0] + 0.5) && (sp = Builder.dtp_piece_at(top[0], top[2]))
          @hit = [:dtp, top[0], sp]
          return focus(Builder.params_of(top[0])['id'])
        end
        return unless face
        _, g, p, lx, lz = face
        focus(p['id'])
        e = p['entries'] || {}
        # a double plate piece, seen from the side
        if lz >= p['height'].to_f - Framing::T && (sp = Builder.dtp_piece_at(g, lx))
          @hit = [:dtp, g, sp]
          return
        end
        slots = Builder.work_slots(p).select { |s| s.id != 'TP:2' && Inspector.complete?(e[s.id]) }
        slot = Framing.slot_at(slots, lx, lz)
        @hit = [:piece, g, slot] if slot
      end

      def onLButtonDown(_flags, x, y, view)
        Builder.close_edits
        pick(view, x, y)
        unless @hit
          UI.beep
          Sketchup.status_text = 'Nothing nailed there.'
          return
        end
        kind, g, what = @hit
        case kind
        when :dtp then take_off_dtp(g, (what['a'] + what['b']) / 2.0)
        when :piece then demo_piece(g, what)
        end
        @hit = nil
        Dialogs.refresh_yard
        Dialogs.refresh_frame
        view.invalidate
      end

      # ---------- pulling ----------

      PLATES = %w[BP TP:1].freeze

      def demo_piece(g, slot)
        p = Builder.params_of(g)
        more = Builder.resting_on(p, slot)
        dtp = PLATES.include?(slot.id) && Builder.dtp_piece_at(g, p['length'].to_f / 2.0)
        unless more.empty? && !dtp
          n = more.size + (dtp ? 1 : 0)
          what = more.size == 1 ? "The #{more.first.label}" : "#{more.size} pieces"
          what = more.empty? ? 'The double plate' : "#{what} and the double plate" if dtp
          verb = PLATES.include?(slot.id) ? (n == 1 ? 'is on' : 'are on') : (n == 1 ? 'rests on' : 'rest on')
          return unless UI.messagebox("#{what} #{verb} the #{slot.label}. Pull #{n == 1 ? 'both' : 'them all'}?", MB_YESNO) == IDYES
        end
        model = Sketchup.active_model
        model.start_operation("Demo #{slot.label}", true)
        Builder.remove_dtp(g) if dtp
        pulled = (more + [slot]).flat_map { |s| pull_all(g, s) }
        model.commit_operation
        Sketchup.status_text = "Pulled #{slot.label}#{more.empty? ? '' : " + #{more.size} more"} (#{pulled.size} board#{pulled.size == 1 ? '' : 's'})."
      end

      # Every board in a slot (all header plies, every backing block).
      def pull_all(g, slot)
        return Builder.remove_backing(g, slot.id) if slot.kind == :backing
        out = []
        while (pc = Builder.remove_piece(g, slot.id))
          out << pc
        end
        out
      end

      def hit_label
        kind, g, what = @hit
        case kind
        when :dtp then "#{Builder.params_of(g)['id']} double plate piece ##{what['n']}"
        else what.label
        end
      end

      # ---------- drawing ----------

      def draw(view)
        fg = @focus && Builder.find_wall(@focus)
        draw_wall_label(view, fg, Builder.params_of(fg)) if fg
        return unless @hit
        kind, g, what = @hit
        p = Builder.params_of(g)
        d = Framing.depth(p)
        case kind
        when :dtp
          z = p['height'].to_f
          draw_box(view, g.transformation, [what['a'], 0, z - Framing::T], [what['b'], d, z], 'red', 4)
          at = Geom::Point3d.new((what['a'] + what['b']) / 2.0, d, z)
        else
          x0, z0, x1, z1 = Framing.slot_box(what)
          draw_box(view, g.transformation, [x0, 0, z0], [x1, d, z1], 'red', 4)
          at = Geom::Point3d.new((x0 + x1) / 2.0, 0, z1)
        end
        view.draw_text(view.screen_coords(at.transform(g.transformation)), "  Click to pull: #{hit_label}")
      end

      def update_ui
        Sketchup.vcb_label = ''
        Sketchup.status_text = @hit ? "DEMO: click to pull #{hit_label}. Esc goes back to framing." : 'DEMO: hover a piece and click to pull it. Esc goes back to framing.'
      end
    end
  end
end
