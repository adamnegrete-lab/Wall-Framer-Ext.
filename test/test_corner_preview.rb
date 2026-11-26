require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
V = Sketchup.active_model.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
texts = []
V.define_singleton_method(:draw_text) { |_p, t, *_| texts << t }
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V); t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
chk(UI.messages.last.to_s.include?('RUNS THROUGH'), 'corner explanation shows after the first wall')
n = UI.messages.size
t.onMouseMove(0, 192, 144, V)  # drawing the east wall (default = butts)
texts.clear; t.draw(V)
puts '   ' + texts.join(' / ')
chk(texts.any? { |x| x.include?('W-101 runs through - this wall butts into it') }, 'corner label names the wall that runs through')
chk(texts.any? { |x| x.include?("11' 6-1/2\"") && x.include?("Tab: runs through = 12' 0\"") }, 'label shows the length both ways')
t.onKeyDown(9, 0, 0, V); texts.clear; t.draw(V)
chk(texts.any? { |x| x.include?('this wall runs through - W-101 butts into it') }, 'Tab flips the label')
t.onKeyDown(9, 0, 0, V)
t.onUserText("12'", V)
chk(UI.messages.size == n, 'explanation only shows once')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
