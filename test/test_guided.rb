require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
Project.update { |d| d['settings']['framing_table'] = false } # walls stay standing in this test
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
g = Builder.create_wall(Geom::Point3d.new(0,0,0), Geom::Point3d.new(192,0,0), 'Level 1', 'EXT 2x6')
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
chk(yd.last('load')['guided'], 'panel in pop-up mode (saw/stock hidden)')
Dialogs.activate_tool; tool = Dialogs.instance_variable_get(:@tool); tool.activate
chk(tool.is_a?(GuidedTool), 'guided tool active')
face = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
down = ->(x) { V.ray = [Geom::Point3d.new(x, 2.75, 60).transform(g.transformation), Geom::Vector3d.new(0, 0, -1).transform(g.transformation)] }
require_relative 'cut_student'
UI.answers[:inputbox] = ->(*a) { raise "pop-up asked: #{a.last}" }
UI.answers[:msg] = ->(m) { raise "message box: #{m[0, 80]}" }
click = ->(s) { x0, z0, x1, z1 = Framing.slot_box(s); face.((x0 + x1) / 2, (z0 + z1) / 2); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V) }
# clicking the bottom plate opens the cut list at its row
bp = Builder.work_slots(Builder.params_of(g)).find { |s| s.id == 'BP' }; click.(bp)
fd = CutStudent.frame_dialog
chk(fd, 'clicking a piece opens the Frame Wall form')
fd.fire('ready')
chk(fd.last('load')['goto_row'] == 'plate:BP', 'at the bottom plate row')
CutStudent.fill(g, only: %w[plate:BP plate:TP:1])
chk(Builder.stage(Builder.params_of(g)) == 'openings', 'plates from the cut list -> openings stage')
chk(Sketchup.status_text.include?('Openings tab'), "told the openings are next (#{Sketchup.status_text[0, 60]})")
# typing a tape reading in the Frame tool no longer drops pencil marks
face.(10.0, 0.8); tool.onMouseMove(0,0,0,V); tool.onUserText("4'", V)
chk(Builder.params_of(g)['pencil'].to_a.empty?, 'no tape/pencil click-through')
fd.fire('ready')
st = fd.last('load')
chk(st['guided'] && st['openings'].empty?, 'form has no opening rows yet')
# a missing plies pick is caught
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [
  { 'mark' => 'W1', 'type' => 'Window', 'x_text' => "4'", 'width_text' => '36', 'height_text' => '48', 'sill_text' => '82 1/2', 'header' => '2x8', 'plies' => '--' }] })
chk(fd.last('openingErrors').any? { |e| e.include?('plies') }, 'plies required from the plans')
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [
  { 'mark' => 'W1', 'type' => 'Window', 'x_text' => "4'", 'width_text' => '36', 'height_text' => '48', 'sill_text' => '82 1/2', 'header' => '2x8', 'plies' => '3' },
  { 'mark' => 'D1', 'type' => 'Door', 'x_text' => "11'", 'width_text' => '38', 'height_text' => '82 1/2', 'sill_text' => '', 'header' => '2x10', 'plies' => '3' }] })
p = Builder.params_of(g)
chk(p['openings'].map { |o| [o['mark'], o['x']] } == [['W1', 30.0], ['D1', 113.0]], "openings from the form (centers from the arrow end): #{p['openings'].map { |o| [o['mark'], o['x']] }}")
chk(Builder.stage(p) == 'units', 'saving the form -> units stage')
chk(Sketchup.status_text.include?('cut list'), 'told to fill in the cut list next')
ops = CutList.rows(p).select { |r| r['key'] =~ /\A(king|jack|header|sill):/ }.map { |r| r['key'] }
CutStudent.fill(g, only: ops)
chk(Builder.stage(Builder.params_of(g)) == 'commons', 'opening units built from the cut list')
hdr = Builder.params_of(g)['entries']['HDR:W1']
chk(hdr && hdr['pieces'].size == 3, 'header plies come from the plans')
CutStudent.fill(g, only: %w[corner:start corner:end oc common])
p = Builder.params_of(g)
chk((p['marks'] || []).size == 5, "corners + 16\" O.C. -> #{(p['marks'] || []).size} commons laid out and nailed")
chk(Builder.stage(p) == 'cripples', 'studs in -> cripples and header blocks next')
cr = Builder.work_slots(p).select { |sl| sl.phase == 'cripples' }
on16 = ->(sl) { ((sl.x + 0.75) % 16).abs < 0.01 }
oc_ok = cr.select { |sl| sl.label.include?('header block') }.all?(&on16) && cr.count(&on16) >= 6
chk(oc_ok, "cripples land on the 16\" layout: #{cr.map { |sl| [sl.label, sl.x + 0.75] }}")
CutStudent.fill(g)
p = Builder.params_of(g)
chk(Builder.stage(p) == 'framed', 'framed from the cut list')
chk(Sketchup.status_text.include?('is framed'), 'told the wall is framed')
r = Inspector.inspect_wall(p, p['entries'], student_layout: true, table: Project.header_table)
chk(r['correct'] == r['total'] - 1, "inspection: #{r['summary']} (only the double plate is left)")
puts "   #{Yard.stats}"
chk(Yard.stats['boards_pulled'] < 30, 'offcuts reused automatically')
# a wrong length: change the jack row
fd.fire('set_row', { 'key' => 'jack:W1', 'v' => '80', 'size' => '2x6' })
p = Builder.params_of(g)
r = Inspector.inspect_wall(p, p['entries'], student_layout: true, table: Project.header_table)
chk(r['issues'].any? { |i| i.message.include?('too short') }, 'wrong jack length caught by inspection')
chk(UI.messages.empty?, "no message boxes: #{UI.messages.first(2)}")
puts($f ? 'SOME FAILED' : 'ALL PASSED')
# trade convention: window RO 36 x 48 with 82-1/2 head -> sill at 34-1/2
w1 = Builder.params_of(g)['openings'].find { |o| o['mark'] == 'W1' }
chk(w1['height'] == 82.5 && w1['sill'] == 34.5 && Framing.ro_height(w1) == 48.0, "W1 RO 36x48, head 82-1/2 -> sill #{w1['sill']}")
d1 = Builder.params_of(g)['openings'].find { |o| o['mark'] == 'D1' }
chk(d1['height'] == 82.5 && Framing.ro_height(d1) == 82.5, 'door RO height measured from the subfloor')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
