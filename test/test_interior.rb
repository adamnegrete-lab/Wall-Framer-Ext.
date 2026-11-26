require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
UI.answers[:msg] = IDYES
t = DrawWallTool.new('Level 1', 'EXT 2x6'); M.select_tool(t)
t.onLButtonDown(0, 0, 0, V); t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
t.onMouseMove(0, 192, 80, V); t.onUserText("12'", V)
t.onMouseMove(0, 50, 144, V); t.onUserText("16'", V)
t.onMouseMove(0, 0, 70, V); t.onUserText("12'", V)
t.onCancel(0, V)
id = ->(n) { Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n } }
Builder.set_run(id.('W-101'), 'through'); Builder.set_run(id.('W-103'), 'through')
# interior closet wall: 4'-0" clear from the east wall's inside face, along the south wall
t2 = DrawWallTool.new('Level 1', 'INT 2x4'); M.select_tool(t2)
V.ray = nil
texts = []; V.define_singleton_method(:draw_text) { |_p, tx, *_| texts << tx }
t2.onMouseMove(0, 140, 6.5, V)  # cursor just inside the south wall's inside face
f = t2.instance_variable_get(:@face)
chk(f && f[:params]['id'] == 'W-101' && f[:hook] == 186.5, "tape hooked on the inside corner at the east wall (hook #{f && f[:hook]})")
texts.clear; t2.draw(V); puts '   ' + texts.grep(/from the corner/).first.to_s
chk(texts.any? { |x| x.include?("3' 10-1/2\" from the corner on W-101") }, 'live tape reading along the face')
t2.onUserText('48', V)
st = t2.instance_variable_get(:@start)
chk(st && st.x.round(3) == 138.5 && st.y.round(3) == 5.5, "typed 48 -> start exactly 4'-0\" from the corner (#{st && [st.x, st.y]})")
t2.onMouseMove(0, 138.6, 137.0, V) # drawing north, near the north wall's inside face
e = t2.instance_variable_get(:@end)
chk(e && e.x.round(3) == 138.5 && e.y.round(3) == 138.5, "end snaps to the north wall's inside face (#{e && [e.x.round(2), e.y.round(2)]})")
t2.onLButtonDown(0, 138.6, 137.0, V)
c = id.('W-105'); p = Builder.params_of(c)
o = c.transformation.origin
chk(p['length'].round(3) == 133.0 && o.x.round(3) == 138.5, "closet wall 11'-1\", framed to the west of the line (#{p['length']})")
_out, corners = Builder.plan_corners('Level 1')
chk(corners.count { |k| k['status'] == 'tee' } == 2, 'closet wall tees in at both ends')
# Tab flips the side
t3 = DrawWallTool.new('Level 1', 'INT 2x4'); M.select_tool(t3)
t3.onMouseMove(0, 100, 137.5, V); t3.onUserText('24', V) # along the north wall's inside face, from the closet wall
s3 = t3.instance_variable_get(:@start); puts "   start #{s3 && [s3.x.round(2), s3.y.round(2)]}"
t3.onKeyDown(9, 0, 0, V)
t3.onMouseMove(0, s3.x, 60, V); t3.onUserText('48', V)
w6 = id.('W-106'); chk(w6 && Builder.params_of(w6)['length'].round(2) == 48.0, 'typed length works for interior walls')
x6 = w6.transformation.xaxis; chk(x6.y.round(3) == 1.0, 'Tab built it on the other side (drawn reversed)')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
