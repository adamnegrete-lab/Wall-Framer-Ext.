# v0.12: RFI form, SFPA header tables by level + span, plies, header marks, opening back-out, labels, pile tags
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
SFPA = File.join(__dir__, 'fixtures', 'sfpa_fake.json')

# 16' x 12' box, Level 1
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V)
t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
t.onMouseMove(0, 192, 80, V); t.onUserText("12'", V)
t.onMouseMove(0, 50, 144, V); t.onUserText("16'", V)
t.onMouseMove(0, 0, 70, V); t.onUserText("12'", V)
id = ->(n) { Builder.all_walls.find { |x| Builder.params_of(x)['id'] == n } }
s = id.('W-101')
chk(s.entities.to_a.any? { |e| e.respond_to?(:name) && e.name == 'W-101' }, 'wall ID label in the model')
span = Builder.building_span(s) / 12.0
chk((span - 12).abs < 0.6, "span read from the house: #{span.round(2)}' across W-101")

# header tables ship with the extension; the floor above picks roof + floor
chk(Project.sfpa_tables && Project.sfpa_tables['roof'], 'header tables ship with the extension')
Project.update { |dd| dd['levels'] << { 'name' => 'Level 2', 'elev' => 108.0 } }
Builder.create_wall(Geom::Point3d.new(0, 0, 108), Geom::Point3d.new(192, 0, 108), 'Level 2', 'EXT 2x6')
chk(Builder.floor_above?(s), 'Level 2 walls sit above W-101')
up = Builder.all_walls.find { |w| Builder.params_of(w)['level'] == 'Level 2' }
chk(!Builder.floor_above?(up), 'top-level wall uses roof only')

# back out of openings: the form and the panel
Dialogs.activate_tool; tool = Dialogs.instance_variable_get(:@tool); tool.activate
w2 = id.('W-102')
p = Builder.params_of(w2)
p['entries'] = Builder.work_slots(p).select { |x| %w[BP TP:1].include?(x.id) }.to_h { |x| [x.id, x.expected.merge('pieces' => [{ 'size' => x.expected['size'], 'length' => x.expected['length'] }])] }
Builder.set_params(w2, p)
chk(Builder.stage(Builder.params_of(w2)) == 'openings', 'W-102 at the openings step')
tool.instance_variable_set(:@focus, 'W-102')
Dialogs.open_frame(w2)
fd = UI::HtmlDialog.all.last
fd.fire('ready')
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [] }) # 'No openings in this wall'
chk(Builder.stage(Builder.params_of(w2)) != 'openings', 'No openings in this wall - straight to framing')
p = Builder.params_of(w2)
p['openings'] = [{ 'mark' => 'D3', 'type' => 'Door', 'x' => 30.0, 'width' => 32.0, 'height' => 82.5, 'sill' => 0.0, 'header' => '2x10', 'plies' => 3 }]
Builder.set_params(w2, p)
p = Builder.params_of(w2); p['openings_done'] = false
p['openings'] = [{ 'mark' => 'D4', 'type' => 'Door', 'x' => 30.0, 'width' => 32.0, 'height' => 82.5, 'sill' => 0.0, 'header' => '2x10', 'plies' => 3 }]
Builder.set_params(w2, p)
cm = Struct.new(:items) { def add_item(t, &b) = items << [t, b]; def add_separator = items << ['--']; def add_submenu(*) = self }.new([])
M.selection.clear; M.selection.add(w2)
DMACC::WallFramer.context_menu(cm)
chk(cm.items.map(&:first).include?('Delete Selected Wall(s)...') && cm.items.none? { |t2, _| t2.to_s.include?('Pull') }, "right-click: Wall Framer submenu only (#{cm.items.map(&:first)})")
M.selection.clear
# panel: Remove D4 button
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; Dialogs.focus_wall('W-102'); yd.fire('ready')
chk(yd.last('load')['wall']['removable'] == ['D4'], 'This Wall tab lists D4 to remove')
UI.answers[:msg] = IDYES
yd.fire('remove_opening', { 'mark' => 'D4' })
chk(Builder.params_of(w2)['openings'].empty?, 'Remove D4 from the panel')

puts($f ? 'SOME FAILED' : 'ALL PASSED')
