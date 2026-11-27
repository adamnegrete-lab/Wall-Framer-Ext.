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

# RFI with no tables -> stuck, instructor told why
p = Builder.params_of(s)
p['openings'] = [{ 'mark' => 'W1', 'type' => 'Window', 'x' => 60.0, 'width' => 36.0, 'height' => 82.5, 'sill' => 34.5, 'header' => Framing::RFI }]
Builder.set_params(s, p)
hs = Builder.work_slots(Builder.params_of(s)).find { |x| x.opening == 'W1' }
chk(Builder.gate_reason(Builder.params_of(s), hs).to_s.include?("RFI isn't submitted"), 'unsent RFI holds the opening')
d = Dialogs.open_rfi('W-101', 'W1'); d.fire('ready')
st = d.last('load')
chk(st['ro'].include?("3' 0\"") && st['mark'] == 'W1' && st['n'] == 1, "RFI form shows wall, opening, RO: #{st['wall']} #{st['mark']} #{st['ro']}")
UI.answers[:msg] = IDYES
d.fire('submit', { 'question' => 'No header called out for W1 on A2 or the general notes. What size?' })
o = Builder.params_of(s)['openings'].first
chk(o['rfi'] == 1 && Project.data['rfis'].first['question'].include?('A2'), 'RFI submitted from the form')
chk(Project.sfpa_tables, 'header tables ship with the extension (never stuck for lack of tables)')

# import SFPA tables -> roof only (nothing above): 4' opening, 16' column -> (1) 2x6
Project.import_sfpa(SFPA)
ans = Project.rfi_answer(Project.data['rfis'].first)
chk(ans && ans['header'] == '2x6' && ans['plies'] == 1, "single story: roof-only table -> #{ans && ans['text']}")
# put a second level on top -> roof + floor table -> (1) 2x10
Project.update { |dd| dd['levels'] << { 'name' => 'Level 2', 'elev' => 108.0 } }
Builder.create_wall(Geom::Point3d.new(0, 0, 108), Geom::Point3d.new(192, 0, 108), 'Level 2', 'EXT 2x6')
chk(Builder.floor_above?(s), 'Level 2 walls sit above W-101')
ans = Project.rfi_answer(Project.data['rfis'].first)
chk(ans && ans['header'] == '2x10' && ans['plies'] == 1, "floor above: roof + floor table -> #{ans && ans['text']}")
up = Builder.all_walls.find { |w| Builder.params_of(w)['level'] == 'Level 2' }
chk(!Builder.floor_above?(up), 'top-level wall uses roof only')
# answers itself after the delay (1 min test setting)
chk(Project.settings['rfi_delay_min'].to_f == 1.0, 'test delay is 1 minute')
Project.update { |dd| dd['rfis'][0]['at'] -= 61 }
done = Project.release_rfis
o = Builder.params_of(s)['openings'].first
chk(done.size == 1 && done.first['answer'] == 'W1: use (1) 2x10.' && o['rfi_new'] && o['jacks'].nil?, 'RFI answered: size + plies; jacks stay on the Habitat rule')
chk(Builder.gate_reason(Builder.params_of(s), hs).to_s.include?('update the opening'), 'still on hold until the student updates W1')
# glulam / too wide -> waits for the instructor
o2 = { 'mark' => 'W9', 'type' => 'Window', 'x' => 20.0, 'width' => 150.0, 'height' => 82.5, 'sill' => 34.5, 'header' => Framing::RFI }
chk(Project.sfpa_answer(s, o2).nil?, 'glulam sizes wait for the instructor')

# back out of openings: right-click items
Dialogs.activate_tool; tool = Dialogs.instance_variable_get(:@tool); tool.activate
w2 = id.('W-102')
p = Builder.params_of(w2)
p['entries'] = Builder.work_slots(p).select { |x| %w[BP TP:1].include?(x.id) }.to_h { |x| [x.id, x.expected.merge('pieces' => [{ 'size' => x.expected['size'], 'length' => x.expected['length'] }])] }
Builder.set_params(w2, p)
chk(Builder.stage(Builder.params_of(w2)) == 'openings', 'W-102 at the openings step')
tool.instance_variable_set(:@focus, 'W-102')
menu = Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([]); tool.menu_items(menu)
item = menu.items.find { |t2, _| t2.include?('Enter openings for W-102') }
chk(item, "right-click opens the Openings form: #{menu.items.map(&:first)}")
item[1].call
fd = UI::HtmlDialog.all.last
fd.fire('ready')
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [] }) # 'No openings in this wall'
chk(Builder.stage(Builder.params_of(w2)) != 'openings', 'No openings in this wall - straight to framing')
p = Builder.params_of(w2)
p['openings'] = [{ 'mark' => 'D3', 'type' => 'Door', 'x' => 30.0, 'width' => 32.0, 'height' => 82.5, 'sill' => 0.0, 'header' => '2x10', 'plies' => 3 }]
Builder.set_params(w2, p)
menu = Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([]); tool.menu_items(menu)
rm = menu.items.find { |t2, _| t2.include?('Remove opening D3') }
chk(rm, "remove an opening: #{menu.items.map(&:first)}")
rm[1].call
chk(Builder.params_of(w2)['openings'].empty?, 'opening removed')

# SketchUp's own right-click menu gets the framing items on top
p = Builder.params_of(w2); p['openings_done'] = false
p['openings'] = [{ 'mark' => 'D4', 'type' => 'Door', 'x' => 30.0, 'width' => 32.0, 'height' => 82.5, 'sill' => 0.0, 'header' => '2x10', 'plies' => 3 }]
Builder.set_params(w2, p)
cm = Struct.new(:items) { def add_item(t, &b) = items << [t, b]; def add_separator = items << ['--']; def add_submenu(*) = self }.new([])
DMACC::WallFramer.context_menu(cm)
chk(cm.items.first(3).map(&:first).any? { |t2| t2.include?('Enter openings') || t2.include?('openings on W-102') }, "SketchUp's menu gets the framing items first: #{cm.items.first(3).map(&:first)}")
# panel: Remove D4 button
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; Dialogs.focus_wall('W-102'); yd.fire('ready')
chk(yd.last('load')['wall']['removable'] == ['D4'], 'This Wall tab lists D4 to remove')
UI.answers[:msg] = IDYES
yd.fire('remove_opening', { 'mark' => 'D4' })
chk(Builder.params_of(w2)['openings'].empty?, 'Remove D4 from the panel')

# pile tags are short
tag = YardView.short_tag({ 'size' => '2x4', 'length' => 92.625, 'label' => '2x4 92-5/8" precut studs', 'qty' => nil }) rescue nil
tag ||= Yard.short_tag({ 'size' => '2x4', 'length' => 92.625, 'label' => '2x4 92-5/8" precut studs', 'qty' => nil })
chk(tag == '2x4 92-5/8 PC', "short pile tag: #{tag}")
puts($f ? 'SOME FAILED' : 'ALL PASSED')
