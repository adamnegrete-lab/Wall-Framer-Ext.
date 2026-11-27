# Framing table: frame flat beside the house, stand it up onto its line. Inspector catches logged for grading.
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V)
[[100, 0, "16'"], [192, 80, "12'"], [50, 144, "16'"], [0, 70, "12'"]].each { |x, y, l| t.onMouseMove(0, x, y, V); t.onUserText(l, V) }
id = ->(n) { Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n } }
Builder.set_run(id.('W-101'), 'through'); Builder.set_run(id.('W-103'), 'through')
Builder.create_wall(Geom::Point3d.new(100, 5.5, 0), Geom::Point3d.new(100, 138.5, 0), 'Level 1', 'INT 2x4')
Builder.resolve_layout('Level 1'); Builder.refresh_corner_needs
s = id.('W-101')
shape0 = Builder.wall_shape(s); joints0 = Joints.find(Builder.level_walls('Level 1').map { |w| Builder.wall_shape(w) })
Dialogs.open_yard; yd = UI::HtmlDialog.all.last
Dialogs.activate_tool; tool = Dialogs.tool; tool.activate
UI.answers[:msg] = IDYES
face = ->(g, x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
click = ->(g, x, z) { face.(g, x, z); tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V) }

# click a wall to frame it -> it goes to the table, flat, outside face up, beside the house
click.(s, 60, 50)
tr = s.transformation
chk(Builder.on_table?(s), 'clicking the wall takes it to the framing table')
chk(tr.zaxis.y > 0.99 && tr.yaxis.z < -0.99, 'lying flat: height runs along the deck, outside face up')
chk(tr.origin.x > 192 + 100, "beside the house, not on top of it (x #{tr.origin.x.round})")
chk(Builder.wall_shape(s) == shape0, 'corners, tees and spans still read its line in the house')
chk(Joints.find(Builder.level_walls('Level 1').map { |w| Builder.wall_shape(w) }) == joints0, 'joints unchanged while it is on the table')
chk(Sketchup.status_text.include?('framing table'), "told where it went: #{Sketchup.status_text[0, 70]}")
yd.fire('ready'); Dialogs.focus_wall('W-101'); yd.fire('ready')
chk(yd.last('load')['wall']['on_table'], 'panel knows it is on the table')
# framing on the table: clicking the plate opens the cut list there; the row nails it
bp = Builder.work_slots(Builder.params_of(s)).find { |x| x.id == 'BP' }
x0, z0, x1, z1 = Framing.slot_box(bp); click.(s, (x0 + x1) / 2, (z0 + z1) / 2)
fd = UI::HtmlDialog.all.reverse.find { |d| d.file.to_s.end_with?('frame.html') }
chk(fd.last('load')['goto_row'] == 'plate:BP' && fd.last('load')['on_table'], 'clicking the plate on the table opens its cut-list row')
fd.fire('set_row', { 'key' => 'plate:BP', 'v' => Framing.fmt_len(bp.expected['length']), 'size' => bp.expected['size'] })
chk(Builder.params_of(s)['entries'] && Builder.params_of(s)['entries']['BP'], 'typing the bottom plate row nails it')
# double plates wait while a wall is on the table
p = Builder.params_of(s)
chk(Builder.dtp_blockers('Level 1').any? { |b| b.include?('W-101') }, 'double plates wait for the wall to be framed and standing')
# a second wall: the first goes back to its line unfinished
w2 = id.('W-102')
click.(w2, 30, 50)
chk(Builder.on_table?(w2) && !Builder.on_table?(s), 'one wall on the table at a time - the other goes back on its line')
chk(s.transformation.zaxis.z > 0.99 && (s.transformation.origin.x - Builder.home(s).origin.x).abs < 1e-6, 'it stands back exactly on its line')
chk(Builder.params_of(s)['entries']['BP'], 'and keeps what was already nailed')
# a corner changed while a wall is on the table moves its chalk line, not the wall
before = w2.transformation.origin.x
Builder.set_run(id.('W-102'), 'through'); Builder.resolve_layout('Level 1')
chk((w2.transformation.origin.x - before).abs < 1e-6 && Builder.on_table?(w2), 'corner change while on the table: the wall stays on the table')
Builder.set_run(id.('W-102'), 'butt'); Builder.resolve_layout('Level 1')
# stand it up from the panel
Dialogs.focus_wall('W-102'); yd.fire('stand_up')
chk(!Builder.on_table?(w2) && w2.transformation.zaxis.z > 0.99, 'Stand it up sets it on its line')
# answer key / grading reads the line in the house
click.(s, 60, 50)
snap = Builder.snapshot_wall(s)
chk(snap['p1'] == [shape0['o'][0], shape0['o'][1]], "grading reads the wall's line, not the table: #{snap['p1']}")

# ---- inspector catches, logged for grading ----
p = Builder.params_of(s)
p['entries']['TP:1'] = { 'role' => 'Top Plate', 'size' => '2x4', 'length' => 100.0, 'pieces' => [{ 'size' => '2x4', 'length' => 100.0 }] }
Builder.set_params(s, p)
r = Dialogs.inspect_group(s)
cs = Project.data['catches']
chk(cs.size == 1 && cs[0]['slot'] == 'TP:1', "the wrong top plate is logged, blanks aren't: #{cs.map { |c| c['slot'] }}")
chk(r['summary'].include?('logged for grading'), "the student is told: #{r['summary']}")
Dialogs.inspect_group(s)
chk(Project.data['catches'][0]['times'] == 2 && Project.data['catches'].size == 1, 'caught again = counted again, not a second record')
html = DMACC::WallFramer.catches_html
chk(html.include?('First-time right') && html.include?('caught 2 times'), 'grade report shows first-time-right and repeat catches')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
