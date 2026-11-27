module DMACC
  module WallFramer
    # The material yard in the model: lumber piles next to the building,
    # an offcut pile and a cart of cut pieces. Data lives in Project['yard'].
    module Yard
      DICT = 'dmacc_wf_yard'.freeze
      TAG = 'Framing - Material Yard'.freeze
      SHOW_MAX = 12   # boards drawn per pile (unlimited piles)
      ROW_GAP = 30.0
      COL_GAP = 48.0

      class << self
        # ---------- data ----------

        def data
          d = Project.data['yard']
          d ||= restock_data
          d
        end

        def save(y)
          Project.update { |d| d['yard'] = y }
        end

        def restock_data
          d = Project.data
          stud_types = d['wall_types'].map { |t| { 'stud' => t['stud'], 'stud_length' => Framing.stud_length(t) } }
          hdr = (d['header_table'].map { |_, s| s } + Builder.all_walls.flat_map do |w|
            Builder.params_of(w)['openings'].map { |o| Framing.header_for(o, Project.header_table) }
          end).uniq.select { |sz| Framing::ACTUAL[sz] } # flat headers come off the 2x4 pile; RFIs aren't sized yet
          YardLogic.default_piles(stud_types, hdr)
        end

        # Instructor: fresh yard (clears cart and offcuts)
        def restock
          y = restock_data
          y['origin'] = data['origin']
          save(y)
          redraw
        end

        def change
          y = data
          res = yield y
          save(y)
          redraw
          res
        end

        def installed_inches
          Builder.all_walls.sum do |w|
            (Builder.params_of(w)['entries'] || {}).values.sum do |e|
              e['pieces'] ? e['pieces'].sum { |p| p['length'].to_f } : 0.0
            end
          end
        end

        def stats
          YardLogic.stats(data, installed_inches)
        end

        # ---------- layout in the model ----------

        def group
          Sketchup.active_model.entities.find do |e|
            e.is_a?(Sketchup::Group) && !e.deleted? && e.get_attribute(DICT, 'yard')
          end
        end

        def origin
          walls = Builder.all_walls
          return [0.0, -120.0, 0.0] if walls.empty?
          xs = []
          ys = []
          zs = []
          walls.each do |w|
            a, b = Builder.endpoints(w)
            xs.push(a.x.to_f, b.x.to_f)
            ys.push(a.y.to_f, b.y.to_f)
            zs.push(a.z.to_f)
          end
          [xs.min, ys.min - 144.0, zs.min] # 12' in front (south) of the building
        end

        # Footprints for hit-testing: [[id, [x0,y0,z0], [x1,y1,z1], label], ...] world coords
        def layout(y = data)
          ox, oy, oz = y['origin'] || origin
          out = []
          piles = y['piles']
          col_w = (piles.map { |p| p['length'].to_f }.max || 192.0) + COL_GAP
          rows = (piles.size / 2.0).ceil
          piles.each_with_index do |p, i|
            col = i < rows ? 0 : 1
            row = i < rows ? i : i - rows
            w = 4 * Framing::ACTUAL[p['size']] + 3
            n = shown(p)
            x0 = ox + col * col_w
            y1 = oy - row * ROW_GAP
            out << [p['id'], [x0, y1 - w, oz], [x0 + p['length'].to_f, y1, oz + layers(n) * Framing::T + 3.5], p['label'], p]
          end
          # offcuts + cart in a third column
          x2 = ox + 2 * col_w
          out << ['OFFCUTS', [x2, oy - 30, oz], [x2 + 96, oy, oz + 12], 'Offcut pile', nil]
          out << ['CART', [x2, oy - 30 - ROW_GAP * 2, oz], [x2 + 96, oy - ROW_GAP * 2, oz + 12], 'Cut pieces (cart)', nil]
          out
        end

        def shown(p)
          p['qty'].nil? ? SHOW_MAX : [p['qty'].to_i, 24].min
        end

        def layers(n)
          (n / 4.0).ceil
        end

        # ---------- drawing ----------

        def redraw
          model = Sketchup.active_model
          y = data
          unless y['origin']
            y['origin'] = origin
            save(y)
          end
          g = group
          unless g
            g = model.entities.add_group
            g.set_attribute(DICT, 'yard', true)
            g.name = 'Material Yard'
          end
          g.entities.clear!
          g.layer = Builder.tag(model, TAG)
          Builder.lock(g)
          ents = g.entities
          layout(y).each do |id, a, _b, label, p|
            case id
            when 'OFFCUTS' then loose(model, ents, y['offcuts'], a, 'Offcuts')
            when 'CART' then loose(model, ents, y['cart'], a, 'Cart')
            else stack(model, ents, p, a, label)
            end
          end
          g
        end

        def board_def(model, size, len)
          key = format('Y|%s|%.3f', size, len)
          d = model.definitions.find { |x| x.get_attribute(Builder::DICT, 'key') == key }
          return d if d
          d = Builder.box_definition(model, "Lumber #{size} x #{Framing.fmt_len(len)}", key, len, Framing::ACTUAL[size], Framing::T)
          d
        end

        def wood(model)
          Builder.material(model, 'Framing - Lumber', [222, 196, 150])
        end

        def stack(model, ents, p, a, label)
          n = shown(p)
          w = Framing::ACTUAL[p['size']]
          n.times do |i|
            row = i % 4
            lay = i / 4
            t = Geom::Transformation.translation([a[0], a[1] + 1 + row * (w + 0.5), a[2] + 3.5 + lay * Framing::T])
            inst = ents.add_instance(board_def(model, p['size'], p['length'].to_f), t)
            inst.material = wood(model)
            inst.set_attribute(DICT, 'pile', p['id'])
          end
          add_stickers(model, ents, a, p['length'].to_f, 4 * (w + 0.5) + 1)
          ents.add_text(short_tag(p), Geom::Point3d.new(a[0] + 2, a[1], a[2] + 3.5 + layers(n) * Framing::T))
        end

        # "2x4 92-5/8 PC", "2x6 12'", "2x10 16' HDR" (+ count if the pile can run out)
        def short_tag(p)
          len = p['length'].to_f
          l = (len % 12).abs < 1e-6 ? "#{(len / 12).round}'" : Framing.fmt_in(len).delete('"')
          kind = if p['label'].include?('precut') then ' PC'
                 elsif p['label'].include?('header') then ' HDR'
                 else ''
                 end
          "#{p['size']} #{l}#{kind}#{p['qty'] ? " (#{p['qty']})" : ''}"
        end

        # 4x4 dunnage the bunks sit on
        def add_stickers(model, ents, a, len, depth)
          [6.0, len / 2.0, len - 9.5].each do |x|
            t = Geom::Transformation.translation([a[0] + x, a[1], a[2]])
            inst = ents.add_instance(Builder.box_definition(model, 'Dunnage 4x4', format('Y|dun|%.2f', depth), 3.5, depth, 3.5), t)
            inst.material = Builder.material(model, 'Framing - Dunnage', [120, 110, 95])
          end
        end

        def loose(model, ents, pieces, a, label)
          pieces.first(30).each_with_index do |p, i|
            t = Geom::Transformation.translation([a[0], a[1] + 1 + (i % 6) * 6, a[2] + (i / 6) * Framing::T])
            inst = ents.add_instance(board_def(model, p['size'], p['length'].to_f), t)
            inst.material = wood(model)
          end
          return if pieces.empty?
          ents.add_text("#{label} (#{pieces.size})", Geom::Point3d.new(a[0], a[1], a[2] + 4))
        end

        # ---------- hit testing ----------

        # Ray vs axis-aligned box (slab method). Returns distance or nil.
        def ray_box(p, v, a, b)
          tmin = -Float::INFINITY
          tmax = Float::INFINITY
          [[p.x, v.x, a[0], b[0]], [p.y, v.y, a[1], b[1]], [p.z, v.z, a[2], b[2]]].each do |o, d, lo, hi|
            if d.abs < 1e-12
              return nil if o < lo || o > hi
            else
              t1 = (lo - o) / d
              t2 = (hi - o) / d
              t1, t2 = t2, t1 if t1 > t2
              tmin = [tmin, t1].max
              tmax = [tmax, t2].min
              return nil if tmin > tmax
            end
          end
          tmax >= 0 ? [tmin, 0].max : nil
        end

        # [id, label, distance] of the pile under the ray, or nil
        def pile_at(ray)
          p, v = ray
          best = nil
          layout.each do |id, a, b, label, _|
            t = ray_box(p, v, a, b)
            best = [id, label, t] if t && (best.nil? || t < best[2])
          end
          best
        end

        def box_of(id)
          l = layout.find { |e| e[0] == id }
          l && [l[1], l[2]]
        end
      end
    end
  end
end
