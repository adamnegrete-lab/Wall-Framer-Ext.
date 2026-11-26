require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
DMACC::WallFramer::Project.update { |d| d['settings']['guided'] = false }
DMACC::WallFramer::Project.update { |d| d['settings']['jobsite_order'] = false; d['settings']['student_layout'] = false }
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
g = Builder.create_wall(Geom::Point3d.new(192,144,0), Geom::Point3d.new(0,144,0), 'Level 1', 'EXT 2x6')
p0 = Builder.params_of(g)
p0['openings'] = [{'mark'=>'D1','type'=>'Door','x'=>113.0,'width'=>38.0,'height'=>82.5,'sill'=>0.0,'header'=>'2x10'},
                  {'mark'=>'W1','type'=>'Window','x'=>30.0,'width'=>36.0,'height'=>82.5,'sill'=>34.5,'header'=>'2x8'}]
Builder.set_params(g, p0); Builder.rebuild(g)
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
tool = Dialogs.instance_variable_get(:@tool) || (Dialogs.activate_tool; Dialogs.instance_variable_get(:@tool))
tool.activate
aim = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
pile = ->(label) { Yard.data['piles'].find { |p| p['label'] == label }['id'] }
clicks = 0
slots = Framing.slots(Builder.params_of(g), Project.header_table)
plan = slots.group_by do |s|
  x = s.expected
  stock = if x['size'] != '2x6' then "#{x['size']} 8' header stock"
          elsif x['length'] > 144 then "2x6 16' stock" elsif x['length'] > 96 then "2x6 12' stock"
          else '2x6 92-5/8" precut studs' end
  [stock, x['length']]
end
plan.each do |(stock, len), ss|
  yd.fire('set_stock', { 'id' => pile.(stock) }); clicks += 1
  yd.fire('toggle_offcuts', { 'on' => len < 40 }); clicks += 1 if len < 40
  full = Yard.data['piles'].find { |p| p['id'] == pile.(stock) }['length']
  if (full - len).abs > 0.01 then yd.fire('set_cut', { 'text' => Framing.fmt_len(len) }) else yd.fire('set_cut', { 'text' => '' }) end
  clicks += 1
  ss.each do |s|
    (s.plies || 1).times do
      x0, z0, x1, z1 = Framing.slot_box(s); aim.((x0 + x1) / 2, (z0 + z1) / 2)
      tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V); clicks += 1
    end
  end
end
p1 = Builder.params_of(g)
members = slots.sum { |s| s.plies || 1 }
chk(p1['entries'].size == slots.size, "every location framed (#{p1['entries'].size}/#{slots.size})")
puts "   #{clicks} clicks/entries for #{members} pieces (was ~#{members * 4}+ plus camera moves)"
r = Inspector.inspect_wall(p1, p1['entries'], table: Project.header_table)
chk(r['correct'] == r['total'], "inspection: #{r['summary']}")
st = Yard.stats; puts "   #{st}"
chk(st['boards_pulled'] < members, 'offcuts-first saved boards')
ys = yd.last('load'); chk(ys['wall']['framed'] == ys['wall']['total'], 'panel shows wall progress')
# mistake: occupied click doesn't waste a board
before = Yard.data['pulled'].size
s0 = slots.first; x0, z0, x1, z1 = Framing.slot_box(s0); aim.((x0+x1)/2,(z0+z1)/2); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
chk(Yard.data['pulled'].size == before && Sketchup.status_text.include?('already nailed'), 'click on nailed spot pulls no board')
# pull a jack, re-nail a full precut via the hand
jack = slots.find { |s| s.expected['role'] == 'Jack Stud' }
x0, z0, x1, z1 = Framing.slot_box(jack); aim.((x0+x1)/2,(z0+z1)/2); tool.onMouseMove(0,0,0,V)
menu = Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([]); tool.getMenu(menu); menu.items.first[1].call
chk(YardLogic.hand(Yard.data)['length'] == 81.0, 'pulled jack in hand')
yd.fire('discard', { 'id' => Yard.data['hand'] })
yd.fire('set_stock', { 'id' => pile.('2x6 92-5/8" precut studs') }); yd.fire('set_cut', { 'text' => '' }); yd.fire('toggle_offcuts', { 'on' => false })
tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
yd.fire('inspect')
ins = yd.last('load')['wall']['inspection']
chk(ins && ins['issues'].size == 1 && ins['issues'][0]['message'].include?('too long'), "panel inspection: #{ins && ins['summary']}")
# measurements box: typed stop + commands
tool.onUserText('o', V); chk(Yard.data['use_offcuts'] == true, 'o toggles offcuts')
tool.onUserText("6' 9\"", V); chk(Yard.data['cut'] == 81.0, 'typed saw stop')
tool.onUserText('full', V); chk(Yard.data['cut'].nil?, 'full clears stop')
File.write('/tmp/yard_state.json', JSON.generate(yd.last('load')))
puts($f ? 'SOME FAILED' : 'ALL PASSED')
