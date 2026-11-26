require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
# place the bunkhouse with the chain tool (S through, E butt, N through, W butt) + closet wall
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V)
t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
t.onMouseMove(0, 192, 80, V); t.onUserText("12'", V)
t.onMouseMove(0, 50, 144, V); t.onUserText("16'", V)
t.onMouseMove(0, 0, 70, V); t.onUserText("12'", V)
id_ = ->(n) { Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n } }
Builder.set_run(id_.('W-101'), 'through'); Builder.set_run(id_.('W-103'), 'through')
Builder.create_wall(Geom::Point3d.new(138.5, 5.5, 0), Geom::Point3d.new(138.5, 138.5, 0), 'Level 1', 'INT 2x4')
Builder.resolve_layout('Level 1')
walls = Builder.all_walls
puts '   ' + walls.map { |w| p = Builder.params_of(w); "#{p['id']} #{Framing.fmt_len(p['length'])}" }.join(', ')
ws, shapes, joints = Builder.dtp_context('Level 1')
chk(joints.size == 6, "joints found in the model: #{joints.map { |j| "#{j['butt']}>#{j['through']}" }.join(' ')}")
# frame every wall except the double plate (fill entries directly)
fill_all = lambda do |w|
  p = Builder.params_of(w)
  p['marks'] = Framing.slots(p).select(&:common).map { |s| s.x + 0.75 - 0.75 }
  p['entries'] = Builder.work_slots(p).reject { |s| s.id == 'TP:2' }.to_h do |s|
    [s.id, s.expected.merge('pieces' => Array.new(s.plies || 1) { { 'size' => s.expected['size'], 'length' => s.expected['length'] } })]
  end
  Builder.set_params(w, p); Builder.rebuild(w)
end
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
fill_all.(walls[0])
chk(yd.tap { |d| d.fire('ready') }.last('load')['building']['blockers'].size == 4, 'double plates locked until every wall is framed')
walls.each { |w| fill_all.(w) }
yd.fire('dtp'); tool = Dialogs.instance_variable_get(:@tool)
chk(tool.mode == :dtp, 'top view / double plate mode on')
top = ->(w) { p = Builder.params_of(w); V.ray = [Geom::Point3d.new(p['length'].to_f / 2, Framing.depth(p) / 2, 500).transform(w.transformation), Geom::Vector3d.new(0, 0, -1)] }
id = ->(n) { walls.find { |w| Builder.params_of(w)['id'] == n } }
# wrong order first: S (through) before E
top.(id.('W-101')); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
top.(id.('W-102')); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
yd.fire('check_interlock'); b = yd.last('load')['building']
puts "   after S,E: #{b['ok']}/#{b['joints']}"
chk(b['results'].any? { |r| r['text'].include?("W-102 / W-101 corner: doesn't lap") }, 'wrong order flagged at the S/E corner')
# fix: take both off (right-click), redo in the right order: butts first
[id.('W-101'), id.('W-102')].each do |w|
  top.(w); tool.onMouseMove(0,0,0,V)
  menu = Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([]); tool.getMenu(menu); menu.items.first[1].call
end
chk(Builder.dtp_order.empty?, 'took both off')
%w[W-102 W-104 W-105 W-101 W-103].each { |n| top.(id.(n)); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V) }
yd.fire('check_interlock'); b = yd.last('load')['building']
chk(b['ok'] == 6 && b['joints'] == 6, "right order: #{b['ok']}/#{b['joints']} interlocked")
s = Builder.params_of(id.('W-101'))['entries']['TP:2']['segs']
e = Builder.params_of(id.('W-102'))['entries']['TP:2']['segs']
chk(e == [[-5.5, 138.5]] && s == [[5.5, 135.0], [138.5, 186.5]], "geometry: E laps both corners #{e}, S breaks for corners + closet tee #{s}")
chk(Builder.interlock('Level 1').all? { |r| r['ok'] }, 'interlock all good')
st = Yard.stats; chk(st['boards_pulled'] >= 6, "double plates pulled real boards (#{st['boards_pulled']}, splices on long runs)")
r = Inspector.inspect_wall(Builder.params_of(id.('W-101')), Builder.params_of(id.('W-101'))['entries'], student_layout: true)
chk(r['correct'] == r['total'], "per-wall inspection still passes: #{r['summary']}")
cl = Dialogs.expected_cut_list; puts "   ideal double plate cut list: #{cl.select { |(sz, l), _| [133+11.0, 181.0, 129.5, 48.0].include?(l) }}"
File.write('/tmp/yard_state.json', JSON.generate(yd.last('load')))
puts($f ? 'SOME FAILED' : 'ALL PASSED')
