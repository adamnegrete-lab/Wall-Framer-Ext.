# Pure-Ruby wall joints and double-top-plate interlock (no SketchUp API).
#
# A wall is a hash:
#   'id', 'o' => [x,y] (start, on the face line), 'dir' => [x,y] (unit),
#   'len', 'depth', 'elev'
# The wall body sits to the LEFT of dir (y = left normal), like the Builder.
#
# A joint is where one wall's END butts into another wall's side:
#   { 'butt' => id, 'end' => 'start'|'end', 'through' => id,
#     'a0' => x, 'a1' => x,   # where the butt wall lands, in the through wall's local x
#     'kind' => 'corner'|'tee' }
#
# Top plates: the through wall's top plate runs past the joint; the butt wall's
# stops against it. Double plates INTERLOCK when it's the other way around:
# the butt wall's double plate laps over the joint. The first double plate placed
# at a joint takes the joint - so the order students place them decides it.
module DMACC
  module WallFramer
    module Joints
      TOL = 0.25

      module_function

      def left(dir)
        [-dir[1], dir[0]]
      end

      def local(w, pt)
        dx = pt[0] - w['o'][0]
        dy = pt[1] - w['o'][1]
        l = left(w['dir'])
        [dx * w['dir'][0] + dy * w['dir'][1], dx * l[0] + dy * l[1]]
      end

      def inside?(w, pt)
        x, y = local(w, pt)
        x >= -TOL && x <= w['len'] + TOL && y >= -TOL && y <= w['depth'] + TOL
      end

      def at(w, x, y)
        l = left(w['dir'])
        [w['o'][0] + w['dir'][0] * x + l[0] * y, w['o'][1] + w['dir'][1] * x + l[1] * y]
      end

      def find(walls)
        out = []
        walls.each do |b|
          [['start', 0.0, -1.0], ['end', b['len'], 1.0]].each do |name, x, out_dir|
            probe = at(b, x + out_dir * 0.5, b['depth'] / 2.0) # just past the wall end
            walls.each do |a|
              next if a['id'] == b['id'] || (a['elev'].to_f - b['elev'].to_f).abs > 1
              next unless inside?(a, probe)
              xs = [at(b, x, 0), at(b, x, b['depth'])].map { |pt| local(a, pt)[0] }
              a0, a1 = xs.minmax
              a0 = [a0, 0.0].max
              a1 = [a1, a['len']].min
              kind = a0 <= a['depth'] + TOL || a1 >= a['len'] - a['depth'] - TOL ? 'corner' : 'tee'
              out << { 'butt' => b['id'], 'end' => name, 'through' => a['id'], 'a0' => a0, 'a1' => a1, 'kind' => kind }
              break
            end
          end
        end
        out
      end

      # Local x spans of a wall's double top plate given the placing order.
      # ideal: true = every joint laps correctly (for the cut list).
      def segments(wall, walls, joints, order, ideal: false)
        idx = ->(id) { order.index(id) || Float::INFINITY }
        by = walls.to_h { |w| [w['id'], w] }
        me = wall['id']
        x0 = 0.0
        x1 = wall['len']
        gaps = []
        joints.each do |j|
          if j['butt'] == me
            a = by[j['through']]
            lap = ideal || idx.call(me) < idx.call(j['through'])
            next unless lap && a
            j['end'] == 'start' ? x0 -= a['depth'] : x1 += a['depth']
          elsif j['through'] == me
            lapped = ideal || idx.call(j['butt']) < idx.call(me)
            gaps << [j['a0'], j['a1']] if lapped
          end
        end
        segs = [[x0, x1]]
        gaps.sort.each do |g0, g1|
          segs = segs.flat_map do |s0, s1|
            next [[s0, s1]] if g1 <= s0 || g0 >= s1
            [[s0, g0], [g1, s1]].select { |a, b| b - a > 0.01 }
          end
        end
        segs.map { |a, b| [a.round(4), b.round(4)] }
      end

      # Per-joint interlock result for the placing order.
      def check(walls, joints, order)
        joints.map do |j|
          placed = order.include?(j['butt']) && order.include?(j['through'])
          ok = placed && order.index(j['butt']) < order.index(j['through'])
          { 'joint' => j, 'placed' => placed, 'ok' => ok,
            'text' => if !placed
                        "#{j['butt']} / #{j['through']} #{j['kind']}: double plates not both on yet."
                      elsif ok
                        "#{j['butt']} / #{j['through']} #{j['kind']}: interlocked."
                      else
                        "#{j['butt']} / #{j['through']} #{j['kind']}: doesn't lap - #{j['butt']}'s top plate butts here, " \
                          "so its double plate has to go on before #{j['through']}'s to lap over the joint."
                      end }
        end
      end
      # ---------- double plates as pieces ----------
      # Students set double plates one piece at a time. A wall's plate starts as
      # one piece; once a crossing wall's double plate laps into it, the rest of
      # that wall is separate pieces (each side of the lap), set one by one.
      # seq = [{ 'wall' => id, 'x' => local x clicked }, ...] in the order set.

      def lapped_gaps(me, joints, spans)
        joints.select { |j| j['through'] == me && (spans[j['butt']] || []).any? { |s| s['lap'].include?(j['end']) } }
              .map { |j| [j['a0'], j['a1']] }
      end

      # Plate still open on a wall: [[a, b], ...] (local x, inside the wall).
      def free(w, joints, spans)
        cuts = (spans[w['id']] || []).map { |s| [s['a'], s['b']] } + lapped_gaps(w['id'], joints, spans)
        segs = [[0.0, w['len'].to_f]]
        cuts.sort.each do |g0, g1|
          segs = segs.flat_map do |s0, s1|
            next [[s0, s1]] if g1 <= s0 + 0.01 || g0 >= s1 - 0.01
            [[s0, g0], [g1, s1]].select { |a, b| b - a > 0.01 }
          end
        end
        segs
      end

      # The piece a click at x would set (with any lap past the wall end), or nil.
      def region(w, by, joints, spans, x)
        len = w['len'].to_f
        a, b = free(w, joints, spans).find { |s0, s1| x >= s0 - 0.01 && x <= s1 + 0.01 }
        return nil unless a
        laps = []
        joints.each do |j|
          next unless j['butt'] == w['id'] && (t = by[j['through']])
          start = j['end'] == 'start'
          next unless start ? a <= 0.01 : b >= len - 0.01
          covered = (spans[t['id']] || []).any? { |s| s['a'] < j['a1'] - 0.01 && s['b'] > j['a0'] + 0.01 }
          next if covered
          laps << j['end']
          start ? a -= t['depth'] : b += t['depth']
        end
        { 'a' => a.round(4), 'b' => b.round(4), 'lap' => laps }
      end

      # Replay the placing order. Returns [spans, bad] - spans: { id => [{a,b,lap,n,i}] }
      # (n = order number on this level, i = index in seq); bad = seq indexes that no longer fit.
      def replay(walls, joints, seq)
        by = walls.to_h { |w| [w['id'], w] }
        spans = {}
        bad = []
        n = 0
        seq.each_with_index do |rec, i|
          w = by[rec['wall']] or next # another level
          sp = region(w, by, joints, spans, rec['x'].to_f)
          next bad << i unless sp
          n += 1
          (spans[w['id']] ||= []) << sp.merge('n' => n, 'i' => i)
        end
        [spans, bad]
      end

      # Per-joint interlock from the pieces actually set.
      def check_spans(walls, joints, spans)
        by = walls.to_h { |w| [w['id'], w] }
        joints.map do |j|
          b = by[j['butt']]
          bs = spans[j['butt']] || []
          ts = spans[j['through']] || []
          len = b ? b['len'].to_f : 0
          butt_on = bs.any? { |s| j['end'] == 'start' ? s['a'] <= 0.01 : s['b'] >= len - 0.01 }
          thru_on = ts.any? { |s| s['a'] < j['a1'] + 1 && s['b'] > j['a0'] - 1 }
          ok_lap = bs.any? { |s| s['lap'].include?(j['end']) }
          placed = butt_on && thru_on
          ok = placed && ok_lap
          { 'joint' => j, 'placed' => placed, 'ok' => ok,
            'text' => if !placed
                        "#{j['butt']} / #{j['through']} #{j['kind']}: double plates not both on yet."
                      elsif ok
                        "#{j['butt']} / #{j['through']} #{j['kind']}: interlocked."
                      else
                        "#{j['butt']} / #{j['through']} #{j['kind']}: doesn't lap - #{j['butt']}'s top plate butts here, " \
                          "so its double plate has to go on before #{j['through']}'s piece over the joint."
                      end }
        end
      end
    end
  end
end
