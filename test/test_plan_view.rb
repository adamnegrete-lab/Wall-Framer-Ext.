require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
V = Sketchup.active_model.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
UI.answers[:msg] = IDYES
start_cam = V.camera
chk(start_cam.perspective?, 'starts in a 3D perspective view')
t = DrawWallTool.new('Level 1', 'EXT 2x6'); Sketchup.active_model.select_tool(t)
chk(!V.camera.perspective? && V.camera.eye.z > V.camera.target.z + 1000 && V.camera.up.y == 1, 'Place Walls switches to a plan (top, orthographic) view')
texts = []; V.define_singleton_method(:draw_text) { |_p, tx, *_| texts << tx }
t.onLButtonDown(0, 0, 0, V); t.onKeyDown(9,0,0,V); t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
t.onKeyDown(9,0,0,V); t.onMouseMove(0, 192, 80, V); t.onUserText("12'", V)
texts.clear; t.draw(V)
chk(texts.include?('W-101') && texts.include?('W-102'), 'wall IDs labeled on the plan')
chk(texts.include?('W-102 butts into W-101'), "corners labeled: #{texts.grep(/butts/).join(', ')}")
t.onCancel(0, V)
chk(V.camera.perspective? && V.camera.eye.x == -500, 'Esc goes back to the 3D view you had')
chk(Dialogs.tool.is_a?(GuidedTool), 'and picks up the Frame tool')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
