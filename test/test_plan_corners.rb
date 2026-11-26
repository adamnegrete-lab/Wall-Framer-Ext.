require_relative '../src/dmacc_wall_framer/corners'
C = DMACC::WallFramer::Corners
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
w = ->(id, p1, p2, run, d = 5.5) { { 'id' => id, 'p1' => p1, 'p2' => p2, 'depth' => d, 'run' => run } }
# bunkhouse drawn on the outside face, counterclockwise, untrimmed
walls = [w.('S', [0,0], [192,0], 'through'), w.('E', [192,0], [192,144], 'butt'),
         w.('N', [192,144], [0,144], 'through'), w.('W', [0,144], [0,0], 'butt'),
         w.('C', [138.5,0], [138.5,144], nil, 3.5)]
out, corners = C.resolve(walls)
len = ->(id) { (out[id]['e'] - out[id]['s']).round(3) }
puts '   ' + out.map { |k, v| "#{k}: #{v['s']}..#{v['e']}" }.join('  ')
chk(len.('S') == 192 && len.('N') == 192 && len.('E') == 133 && len.('W') == 133, 'S/N run through 16\', E/W butt 11\'-1"')
chk(out['E']['s'] == 5.5 && out['E']['e'] == 138.5, 'E trimmed at both ends')
chk(out['C']['s'] == 5.5 && out['C']['e'] == 138.5, 'closet wall tees in and butts at both ends automatically')
chk(corners.count { |c| c['status'] == 'ok' } == 4 && corners.count { |c| c['status'] == 'tee' } == 2, 'four corners ok, two tees')
walls2 = walls.map { |x| x.merge('run' => nil) }
_, c2 = C.resolve(walls2); chk(c2.count { |c| c['status'] == 'unset' } == 4, 'nothing set = four unset corners')
walls3 = walls.map { |x| x['id'] == 'E' ? x.merge('run' => 'through') : x }
o3, c3 = C.resolve(walls3)
chk(c3.select { |c| c['status'] == 'conflict' }.map { |c| c['walls'] }.sort == [%w[E N], %w[E S]], "conflicts flagged: #{c3.select { |c| c['status'] == 'conflict' }.map { |c| c['walls'].join('/') }}")
# pinwheel is fine too: each wall through at one end? per-wall setting -> one only through. S through + E butt only
walls4 = [w.('S', [0,0], [192,0], 'through'), w.('E', [192,0], [192,144], nil)]
o4, c4 = C.resolve(walls4); chk(o4['E']['s'] == 5.5 && c4.first['status'] == 'ok', 'one wall set decides its partner')
# right turn (framing outside the turn) extends instead of trims
walls5 = [w.('A', [0,0], [100,0], 'through'), w.('B', [100,0], [100,-80], 'butt')]
o5, _ = C.resolve(walls5); chk(o5['A']['e'] == 105.5 && o5['B']['s'] == 0.0, "gap corner: A extends to cover it (#{o5['A']['e']})")
puts($f ? 'SOME FAILED' : 'ALL PASSED')
