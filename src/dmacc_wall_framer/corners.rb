# Pure-Ruby corner logic for chained walls (no SketchUp API).
#
# Walls are drawn on one face line and frame to the LEFT of the pick
# direction. Where two walls meet at a square corner, one wall "runs through"
# the corner and the other "butts" into it.
#   - Left turn  (framing on the inside of the turn): the walls overlap by a
#     wall-depth square, so one of them gets shorter.
#   - Right turn (framing on the outside of the turn): there's a gap square,
#     so one of them gets longer.
module DMACC
  module WallFramer
    module Corners
      SQUARE_TOL = 0.02 # |cos(angle)| below this = square corner (~1 degree)

      module_function

      # prev_dir / next_dir: [x, y] unit-ish vectors of the two walls in plan.
      # Returns one of:
      #   [:shift_start, wall, delta]  move that wall's start forward by delta
      #                                (negative = backward / longer)
      #   [:extend_end,  wall, delta]  change that wall's length at its end
      #   [:none, nil, 0]              not a square corner - leave it
      # wall is :prev or :next.
      # through: which wall runs through the corner, :prev or :next.
      def adjust(prev_dir, next_dir, d_prev, d_next, through)
        px, py = unit(prev_dir)
        nx, ny = unit(next_dir)
        dot = px * nx + py * ny
        return [:none, nil, 0.0] if dot.abs > SQUARE_TOL
        left = (px * ny - py * nx) > 0
        if through == :prev
          left ? [:shift_start, :next, d_prev] : [:extend_end, :prev, d_next]
        else
          left ? [:extend_end, :prev, -d_next] : [:shift_start, :next, -d_prev]
        end
      end

      def unit(v)
        l = Math.sqrt(v[0]**2 + v[1]**2)
        [v[0] / l, v[1] / l]
      end
    end
  end
end

module DMACC
  module WallFramer
    # Plan-first corners: walls are drawn as layout lines (untrimmed); each wall
    # is then set to RUN THROUGH or BUTT, and every corner is resolved from that.
    module Corners
      JOIN_TOL = 1.0 # endpoints within 1" = the walls meet at a corner

      module_function

      # walls: [{'id','p1'=>[x,y],'p2'=>[x,y],'depth','run'=>'through'|'butt'|nil}]
      # Returns { id => {'s'=>start, 'e'=>end} } (distances along the layout line
      # from p1) and a list of corners with their status.
      def resolve(walls)
        info = walls.to_h do |w|
          len = Math.hypot(w['p2'][0] - w['p1'][0], w['p2'][1] - w['p1'][1])
          u = [(w['p2'][0] - w['p1'][0]) / len, (w['p2'][1] - w['p1'][1]) / len]
          [w['id'], w.merge('len' => len, 'u' => u, 'n' => [-u[1], u[0]])]
        end
        out = info.transform_values { |w| { 's' => 0.0, 'e' => w['len'] } }
        corners = []
        seen = {}
        info.each_value do |w|
          [['start', w['p1'], 0.0], ['end', w['p2'], w['len']]].each do |end_name, pt, _|
            partner = nil
            pend = nil
            info.each_value do |o|
              next if o['id'] == w['id']
              if close(o['p1'], pt) then partner = o; pend = 'start'
              elsif close(o['p2'], pt) then partner = o; pend = 'end'
              end
              break if partner
            end
            if partner
              ope = pend == 'start' ? partner['p1'] : partner['p2']
              near = [ope, [ope[0] + partner['n'][0] * partner['depth'], ope[1] + partner['n'][1] * partner['depth']]]
              a, b = near.map { |q| along(w, q) }.minmax
              m = w['run']
              o = partner['run']
              key = [w['id'], partner['id']].sort
              status =
                if m.nil? && o.nil? then 'unset'
                elsif m == o then 'conflict'
                else 'ok'
                end
              unless seen[key]
                seen[key] = true
                corners << { 'walls' => key, 'at' => pt, 'status' => status,
                             'through' => status == 'ok' ? (m == 'through' || (m.nil? && o == 'butt') ? w['id'] : partner['id']) : nil }
              end
              next unless status == 'ok'
              through = m == 'through' || (m.nil? && o == 'butt')
              if end_name == 'end'
                out[w['id']]['e'] = through ? b : a
              else
                out[w['id']]['s'] = through ? a : b
              end
            elsif (o = tee_host(info, w, pt))
              # tee: this wall ends against the side of another - it always butts
              pts = footprint(o).map { |q| along(w, q) }
              lo, hi = pts.minmax
              # stop at the near face of the wall it lands on
              end_name == 'end' ? out[w['id']]['e'] = lo : out[w['id']]['s'] = hi
              corners << { 'walls' => [w['id'], o['id']], 'at' => pt, 'status' => 'tee', 'through' => o['id'] }
            end
          end
        end
        [out, corners]
      end

      def close(a, b)
        Math.hypot(a[0] - b[0], a[1] - b[1]) <= JOIN_TOL
      end

      def along(w, q)
        (q[0] - w['p1'][0]) * w['u'][0] + (q[1] - w['p1'][1]) * w['u'][1]
      end

      def footprint(o)
        d = o['depth']
        [o['p1'], o['p2']].flat_map { |p| [p, [p[0] + o['n'][0] * d, p[1] + o['n'][1] * d]] }
      end

      # Another wall whose footprint this point sits on (not at its ends).
      def tee_host(info, w, pt)
        info.values.find do |o|
          next false if o['id'] == w['id']
          x = along(o, pt)
          y = (pt[0] - o['p1'][0]) * o['n'][0] + (pt[1] - o['p1'][1]) * o['n'][1]
          x > JOIN_TOL && x < o['len'] - JOIN_TOL && y >= -JOIN_TOL && y <= o['depth'] + JOIN_TOL
        end
      end
    end
  end
end
