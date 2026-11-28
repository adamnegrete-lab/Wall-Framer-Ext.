# Instructor menu: test house, fill a wall, frame a floor, reset a wall (password-gated).
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
Project.set_password('test'); Project.unlock('test')
Instructor.draw_test_house
ws = Builder.all_walls
chk(ws.size >= 5, "test house drawn: #{ws.map { |w| Builder.params_of(w)['id'] }}")
w1 = Builder.find_wall('W-101')
chk(Builder.params_of(w1)['openings'].any?, 'W-101 has its window')
M.selection.clear; M.selection.add(w1)
Instructor.fill_wall
chk(Builder.stage(Builder.params_of(w1)) == 'framed', "fill this wall -> framed (#{Builder.stage(Builder.params_of(w1))})")
Instructor.reset_wall
chk(Builder.params_of(w1)['entries'].to_h.empty?, 'reset this wall -> empty')
Instructor.frame_floor
st = Builder.all_walls.map { |w| Builder.stage(Builder.params_of(w)) }.tally
chk(st.keys == ['framed'], "frame every wall on this floor: #{st}")
puts($f ? 'SOME FAILED' : 'ALL PASSED')
