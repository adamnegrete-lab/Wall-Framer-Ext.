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
len = ->(n) { Builder.params_of(Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n })['length'].round(3) }
chk(%w[W-101 W-102 W-103 W-104].map { |n| len.(n) } == [192, 144, 192, 144], 'drawn as the floor plan lines, untrimmed')
t.onCancel(0, V)
ct = M.instance_variable_get(:@tool)
chk(ct.is_a?(CornerTool), 'Esc after drawing -> Corners step')
chk(UI.messages.any? { |m| m.include?('RUNS THROUGH') }, 'corners explained once')
texts = []; V.define_singleton_method(:draw_text) { |_p, tx, *_| texts << tx }
click = lambda do |n|
  w = Builder.all_walls.find { |x| Builder.params_of(x)['id'] == n }
  p = Builder.params_of(w)
  c = Geom::Point3d.new(p['length'].to_f / 2, 2.75, 0).transform(w.transformation)
  V.ray = [Geom::Point3d.new(c.x, c.y, 500), Geom::Vector3d.new(0, 0, -1)]
  ct.onMouseMove(0, 0, 0, V); ct.onLButtonDown(0, 0, 0, V)
end
click.('W-101'); click.('W-103')
chk(%w[W-101 W-102 W-103 W-104].map { |n| len.(n) } == [192, 133, 192, 133], 'S + N run through -> E and W butt at 11\'-1"')
chk(Sketchup.status_text.include?('All corners are set'), 'all corners settled')
click.('W-102') # make E run through too -> conflicts
texts.clear; ct.draw(V)
chk(texts.any? { |x| x.include?('W-101 & W-102 both run through') }, "conflict shown: #{texts.grep(/both/).first}")
chk(Sketchup.status_text.include?('2 corners left'), Sketchup.status_text)
g = Builder.all_walls.find { |w| Builder.params_of(w)['id'] == 'W-102' }
chk(Builder.stage(Builder.params_of(g)) == 'corners', 'framing waits until the corners are settled')
click.('W-102') # back to butts
chk(len.('W-102') == 133 && Builder.stage(Builder.params_of(g)) == 'plates', 'fixed - framing can start')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
