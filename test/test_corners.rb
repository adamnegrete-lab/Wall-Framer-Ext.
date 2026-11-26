require_relative '../src/dmacc_wall_framer/corners'
C = DMACC::WallFramer::Corners
# Simulate drawing the bunkhouse outline as one chain on the outside face, counterclockwise.
# Plan says: S through, E butt, N through, W butt.
Wl = Struct.new(:name, :start, :dir, :len, :depth, :mode)
pts = [[0,0],[192,0],[192,144],[0,144],[0,0]]
modes = %i[through butt through butt]
walls = []
pts.each_cons(2).with_index do |(a,b),i|
  d=[b[0]-a[0], b[1]-a[1]]; l=Math.hypot(*d); u=[d[0]/l,d[1]/l]
  w = Wl.new(%w[S E N W][i], a.dup, u, l, 5.5, modes[i])
  apply = lambda do |op, target, delta|
    tw = target == :prev ? walls.last : w
    if op == :shift_start then tw.start=[tw.start[0]+tw.dir[0]*delta, tw.start[1]+tw.dir[1]*delta]; tw.len-=delta
    elsif op == :extend_end then tw.len+=delta end
  end
  if walls.any?
    op,t,dl = C.adjust(walls.last.dir, w.dir, walls.last.depth, w.depth, w.mode == :through ? :next : :prev)
    apply.call(op,t,dl)
  end
  if i == 3 # closing: this wall is prev, first wall is next
    first = walls.first
    op,t,dl = C.adjust(w.dir, first.dir, w.depth, first.depth, w.mode == :through ? :prev : :next)
    tw = t == :prev ? w : first
    if op == :shift_start then tw.start=[tw.start[0]+tw.dir[0]*dl, tw.start[1]+tw.dir[1]*dl]; tw.len-=dl
    elsif op == :extend_end then tw.len+=dl end
  end
  walls << w
end
walls.each { |w| e=[w.start[0]+w.dir[0]*w.len, w.start[1]+w.dir[1]*w.len]; puts "#{w.name} #{w.mode}: #{w.start.map{_1.round(2)}} -> #{e.map{_1.round(2)}} len #{w.len}" }
exp = {'S'=>[[0,0],192],'E'=>[[192,5.5],133],'N'=>[[192,144],192],'W'=>[[0,138.5],133]}
ok = walls.all? { |w| (w.start[0]-exp[w.name][0][0]).abs<1e-6 && (w.start[1]-exp[w.name][0][1]).abs<1e-6 && (w.len-exp[w.name][1]).abs<1e-6 }
puts ok ? 'MATCHES PLAN' : 'MISMATCH'
# right turn case: walls drawn clockwise on inside face -> framing outside, gap squares
p C.adjust([1,0],[0,-1],5.5,5.5,:prev), C.adjust([1,0],[0,-1],5.5,5.5,:next), C.adjust([1,0],[1,1],5.5,5.5,:prev)
