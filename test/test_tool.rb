require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
DMACC::WallFramer::Project.update { |d| d['settings']['jobsite_order'] = false; d['settings']['student_layout'] = false }
include DMACC::WallFramer
V = Sketchup.active_model.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
# click SW corner (exact vertex), then slightly-off clicks near corners (hand clicks are never exact)
Sketchup::InputPoint::VERTS << [0, 0]
t.onLButtonDown(0, 0, 0, V)
t.onKeyDown(9, 0, 0, V)                 # Tab -> S runs through
t.onMouseMove(0, 100, 1.3, V)           # hand is ~0.7 deg off red - snaps
chk(t.instance_variable_get(:@snap) == :x, 'snaps to red axis')
t.onUserText("16'", V)
t.onKeyDown(9, 0, 0, V)                 # E butts
t.onMouseMove(0, 193.0, 80, V)          # off by ~0.7 deg - snaps square to last wall / green
chk(%i[y perp].include?(t.instance_variable_get(:@snap)), "snaps to green/square (#{t.instance_variable_get(:@snap)})")
t.onUserText("12'", V)
t.onKeyDown(9, 0, 0, V)                 # N runs through
t.onMouseMove(0, 50, 145, V)
t.onUserText("16'", V)
t.onKeyDown(9, 0, 0, V)                 # W butts
t.onMouseMove(0, 0.2, 0.1, V)
Sketchup::InputPoint::VERTS << [0, 0]
t.onLButtonDown(0, 0.2, 0.1, V)         # click near first point -> closes loop
walls = Builder.all_walls.map { |w| p = Builder.params_of(w); o = w.transformation.origin; x = w.transformation.xaxis
  [p['id'], [o.x.round(3), o.y.round(3), o.z.round(3)], [x.x.round(3), x.y.round(3)], p['length'].round(3)] }
walls.each { |w| p w }
exp = [[[0,0],[1,0],192],[[192,5.5],[0,1],133],[[192,144],[-1,0],192],[[0,138.5],[0,-1],133]]
chk(walls.size == 4, '4 walls placed in one chain')
walls.zip(exp).each { |w, e| chk(w[1][0..1] == e[0].map(&:to_f) && w[2] == e[1].map(&:to_f) && w[3] == e[2], "#{w[0]} matches plan #{e.inspect}") }
chk(walls.all? { |w| w[1][2] == 0.0 }, 'all on level datum even though cursor was 40" up a wall face')
chk(t.instance_variable_get(:@start).nil?, 'chain reset after closing loop')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
