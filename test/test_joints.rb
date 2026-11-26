require_relative '../src/dmacc_wall_framer/joints'
J = DMACC::WallFramer::Joints
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
w = ->(id, o, d, len, dep = 5.5) { {'id'=>id,'o'=>o,'dir'=>d,'len'=>len,'depth'=>dep,'elev'=>0} }
walls = [w.('S',[0,0],[1,0],192), w.('E',[192,5.5],[0,1],133), w.('N',[192,144],[-1,0],192), w.('W',[0,138.5],[0,-1],133),
         w.('C',[138.5,5.5],[0,1],133,3.5)]
js = J.find(walls)
js.each { |j| puts "   #{j['butt']} #{j['end']} -> #{j['through']} #{j['kind']} [#{j['a0']}, #{j['a1']}]" }
chk(js.size == 6, '4 corners + 2 tees found')
chk(js.any? { |j| j['butt']=='C' && j['through']=='S' && j['kind']=='tee' && j['a0']==135.0 && j['a1']==138.5 }, 'closet wall tees into S at 135-138.5')
good = %w[E W C S N]
r = J.check(walls, js, good); chk(r.all? { |x| x['ok'] }, 'butts first = all interlocked')
bad = %w[S N E W C]
r = J.check(walls, js, bad); chk(r.count { |x| !x['ok'] } == 6, 'through walls first = nothing laps')
puts '   ' + r.first['text']
seg = ->(id, ord) { J.segments(walls.find { |x| x['id']==id }, walls, js, ord) }
chk(seg.('E', good) == [[-5.5, 138.5]], "E double plate laps both corners: #{seg.('E', good)}")
chk(seg.('S', good) == [[5.5, 135.0], [138.5, 186.5]], "S double plate stops short at corners + break at the tee: #{seg.('S', good)}")
chk(seg.('S', bad) == [[0.0, 192.0]], 'S placed first runs full length')
chk(seg.('E', bad) == [[0.0, 133.0]], 'E placed after S and N just butts')
chk(J.segments(walls[0], walls, js, [], ideal: true) == seg.('S', good), 'ideal = correct interlock')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
