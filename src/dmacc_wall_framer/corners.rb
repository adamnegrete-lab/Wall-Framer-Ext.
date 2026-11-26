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
