# One-page form extras: header table, layout start label, Build and stand, Continue framing, Frame next wall.
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
require_relative 'cut_student'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V)
[[100, 0, "16'"], [192, 80, "12'"], [50, 144, "16'"], [0, 70, "12'"]].each { |x, y, l| t.onMouseMove(0, x, y, V); t.onUserText(l, V) }
id = ->(n) { Builder.find_wall(n) }
Builder.set_run(id.('W-101'), 'through'); Builder.set_run(id.('W-103'), 'through')
Builder.resolve_layout('Level 1'); Builder.refresh_corner_needs
Dialogs.open_yard; Dialogs.activate_tool; tool = Dialogs.tool; tool.activate
w1 = id.('W-101')
tool.to_table(w1)
label = ->(g) { g.entities.to_a.any? { |e| e.respond_to?(:name) && e.name.to_s.include?('LAYOUT START') } }
chk(label.(w1), 'LAYOUT START label is in the model while the wall is on the table')
fd = CutStudent.frame_dialog; fd.fire('ready')
st = fd.last('load')
chk(st['header_tables'] && st['header_tables']['roof'].size == st['header_tables']['openings'].size, 'header table ships with the form (no import needed)')
chk(st['header_choices'].none? { |c| c.include?('RFI') }, 'no RFI option in the header list')
chk(st['start_side'] == 'left', 'form says which end the layout starts from')
chk(!st['ready_to_build'], 'Build and stand wall hidden while rows are empty')
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [] })
CutStudent.fill(w1)
fd.fire('ready')
chk(fd.last('load')['ready_to_build'], 'every row filled -> Build and stand wall offered')
fd.fire('build_stand')
chk(!Builder.on_table?(w1) && Builder.framed_and_standing?(w1), 'Build and stand wall: framed and standing on its line')
chk(!label.(w1), 'label comes off when it stands up')
# Frame next wall: counterclockwise from W-101
fd.fire('frame_next'); fd.fire('ready')
chk(fd.last('load')['wall']['id'] == 'W-102' && Builder.on_table?(id.('W-102')), "Frame next wall -> W-102 on the table (#{fd.last('load')['wall']['id']})")
# tape, then Continue framing puts the table view back
DMACC::WallFramer.tape_tool
called = false
Views.define_singleton_method(:table) { |_g| called = true }
fd.fire('continue')
chk(called && Dialogs.tool.is_a?(GuidedTool), 'Continue framing: back in the Frame tool, looking down on the table')
# half-framed wall: Frame next wall puts it back unfinished and moves on
fd.fire('frame_next'); fd.fire('ready')
chk(fd.last('load')['wall']['id'] == 'W-103' && !Builder.on_table?(id.('W-102')), 'unfinished wall goes back on its line, next one comes up')
# level inspection gate
chk(Dialogs.inspect_level('Level 1').include?('W-102 (not framed)'), 'inspection lists what is still open')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
