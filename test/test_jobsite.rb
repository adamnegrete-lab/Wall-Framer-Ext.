require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
DMACC::WallFramer::Project.update { |d| d['settings']['guided'] = false }
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
g = Builder.create_wall(Geom::Point3d.new(192,144,0), Geom::Point3d.new(0,144,0), 'Level 1', 'EXT 2x6')
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
Dialogs.activate_tool; tool = Dialogs.instance_variable_get(:@tool); tool.activate
aim = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
down = ->(x) { V.ray = [Geom::Point3d.new(x, 2.75, 60).transform(g.transformation), Geom::Vector3d.new(0, 0, -1).transform(g.transformation)] }
pile = ->(label) { Yard.data['piles'].find { |p| p['label'] == label }['id'] }
stock_for = lambda do |x|
  if x['size'] != '2x6' then "#{x['size']} 8' header stock"
  elsif x['length'] > 144 then "2x6 16' stock" elsif x['length'] > 96 then "2x6 12' stock"
  else '2x6 92-5/8" precut studs' end
end
nail = lambda do |s|
  x = s.expected; st = stock_for.(x)
  yd.fire('set_stock', { 'id' => pile.(st) })
  full = Yard.data['piles'].find { |p| p['id'] == pile.(st) }['length']
  yd.fire('set_cut', { 'text' => (full - x['length']).abs > 0.01 ? Framing.fmt_len(x['length']) : '' })
  x0, z0, x1, z1 = Framing.slot_box(s); aim.((x0 + x1) / 2, (z0 + z1) / 2)
  tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V)
end
# 1. try opening mark before plates -> refused
tool.set_mode(:opening); down.(60); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
chk(Sketchup.status_text.start_with?('Plates first'), "opening before plates refused: #{Sketchup.status_text}")
# try a king-location... nothing to nail yet except plates; try nailing TP:2 early
tool.set_mode(:nail)
dtp = Builder.work_slots(Builder.params_of(g)).find { |s| s.id == 'TP:2' }
nail.(dtp); chk(Sketchup.status_text.include?('after every wall stands') && Yard.data['pulled'].empty?, 'double plate refused per wall, no board wasted')
# plates
%w[BP TP:1].each { |id| nail.(Builder.work_slots(Builder.params_of(g)).find { |s| s.id == id }) }
chk(Builder.params_of(g)['entries'].keys.sort == %w[BP TP:1], 'plates in')
# 2. opening centerline via mark tool -> frame dialog prefilled
tool.set_mode(:opening); down.(132.0); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
fd = UI::HtmlDialog.all.find { |d| d.file.to_s.end_with?('frame.html') }; fd.fire('ready')
st = fd.last('load'); chk(st['prefill'] && st['prefill']['x_text'] == "11' 0\"" && st['pos_mode'] == 'center', "frame dialog prefilled CL #{st['prefill']}")
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [
  { 'mark' => 'D1', 'type' => 'Door', 'x_text' => "11'", 'width_text' => '38', 'height_text' => '82 1/2', 'sill_text' => '', 'header' => '2x10' }]})
chk(fd.last('openingErrors') == [], 'door saved from centerline')
tool.set_mode(:nail)
ws = Builder.work_slots(Builder.params_of(g))
nail.(ws.find { |s| s.id == 'HDR:D1' }); chk(Sketchup.status_text.include?('Both jacks'), Sketchup.status_text)
# 3. opening unit in order: kings, jacks, header x3, blocks
order = ->(role) { Builder.work_slots(Builder.params_of(g)).select { |s| s.opening == 'D1' && s.expected['role'] == role } }
(order.('King Stud') + order.('Jack Stud')).each { |s| nail.(s) }
3.times { nail.(order.('Header').first) }
order.('Cripple Stud').each { |s| nail.(s) }
# commons before layout: none exist yet as work slots (student layout on)
p1 = Builder.params_of(g)
chk(Builder.work_slots(p1).count(&:common) == 0, 'no common studs until laid out')
# 4. layout: student clicks stud centers at 16,32,... skipping door zone; plus one bad mark
tool.set_mode(:layout)
[16, 32, 48, 64, 80, 96, 160, 176, 100].each { |c| down.(c.to_f); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V) }
p1 = Builder.params_of(g); puts "   marks: #{p1['marks'].map { |m| Framing.fmt_len(m) }.join(', ')}  (#{Sketchup.status_text})"
down.(124.0); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
chk(Sketchup.status_text.include?('inside D1'), "no marks inside the door unit: #{Sketchup.status_text}")
tool.set_mode(:nail)
Builder.work_slots(Builder.params_of(g)).select { |s| s.phase == 'commons' }.each { |s| nail.(s) }
chk(Builder.place_dtp(g).nil?, 'double plate placed as the building step')
yd.fire('inspect')
w = yd.last('load')['wall']; puts '   ' + w['inspection']['summary']
w['steps'].each { |s| puts "   #{s['done'] ? 'x' : ' '} #{s['name']}: #{s['text']}" }
iss = w['inspection']['issues']
chk(iss.size == 1 && iss[0]['message'].start_with?('Off layout'), "only the bad mark at 100 is flagged: #{iss.map { |i| i['message'] }}")
chk(w['steps'].all? { |s| s['done'] }, 'all 5 steps done')
bp = g.entities.select { |e| e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(Builder::DICT, 'role') == 'Bottom Plate' }
chk(bp.size == 2, 'bottom plate shows door cutout')
chk(Dialogs.expected_cut_list.select { |(sz, l), _| l == 192.0 }.values.sum == 3, 'cut list: BP + TP + DTP all full length, counted once')
File.write('/tmp/yard_state.json', JSON.generate(yd.last('load')))
puts($f ? 'SOME FAILED' : 'ALL PASSED')
