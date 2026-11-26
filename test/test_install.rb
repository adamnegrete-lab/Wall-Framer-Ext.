require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
DMACC::WallFramer::Project.update { |d| d['settings']['guided'] = false }
DMACC::WallFramer::Project.update { |d| d['settings']['jobsite_order'] = false; d['settings']['student_layout'] = false }
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
# wall drawn NE->NW like W-103 (rotated, so transforms matter)
g = Builder.create_wall(Geom::Point3d.new(192,144,0), Geom::Point3d.new(0,144,0), 'Level 1', 'EXT 2x6')
p0 = Builder.params_of(g)
p0['openings'] = [{'mark'=>'D1','type'=>'Door','x'=>113.0,'width'=>38.0,'height'=>82.5,'sill'=>0.0,'header'=>'2x10'},
                  {'mark'=>'W1','type'=>'Window','x'=>30.0,'width'=>36.0,'height'=>82.5,'sill'=>34.5,'header'=>'2x8'}]
Builder.set_params(g, p0); Builder.rebuild(g)
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
ys = yd.last('load'); chk(ys['piles'].size >= 10 && ys['hand'].nil?, "yard loaded with #{ys['piles'].size} piles")
chk(Yard.group && Yard.group.entities.count > 50, 'yard drawn in model')
tool = InstallTool.new; tool.activate
# aim at a wall-local (x,z): ray from the outside face looking in (+y local)
aim = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
pile = ->(label) { Yard.data['piles'].find { |p| p['label'] == label }['id'] }
# click a pile in the model: aim straight down at its box
pull = lambda do |label|
  a, b = Yard.box_of(pile.(label))
  V.ray = [Geom::Point3d.new((a[0]+b[0])/2, (a[1]+b[1])/2, 500), Geom::Vector3d.new(0, 0, -1)]
  tool.onLButtonDown(0, 0, 0, V)
end
slots = Framing.slots(Builder.params_of(g), Project.header_table)
kerf_cripples = 0
slots.each do |s|
  x = s.expected
  n = s.plies || 1
  n.times do
    stock = if x['size'] != '2x6' then "#{x['size']} 8' header stock"
            elsif (x['length'] - 92.625).abs < 0.01 then '2x6 92-5/8" precut studs'
            elsif x['length'] > 144 then "2x6 16' stock" elsif x['length'] > 96 then "2x6 12' stock"
            elsif x['length'] < 12 && Yard.data['offcuts'].any? { |o| o['size'] == '2x6' && o['length'] >= x['length'] + 0.125 }
              nil else '2x6 92-5/8" precut studs' end
    if stock then pull.(stock)
    else
      o = Yard.data['offcuts'].find { |oc| oc['size'] == '2x6' && oc['length'] >= x['length'] + 0.125 }
      yd.fire('take', { 'id' => o['id'] }); kerf_cripples += 1
    end
    tool.onUserText(Framing.fmt_len(x['length']), V)   # cut in Measurements box
    x0, z0, x1, z1 = Framing.slot_box(s)
    aim.((x0 + x1) / 2, (z0 + z1) / 2)
    tool.onMouseMove(0, 0, 0, V)
    raise "missed #{s.label}: got #{tool.instance_variable_get(:@target)&.at(1)&.label}" unless tool.instance_variable_get(:@target)&.at(1)&.id == s.id
    tool.onLButtonDown(0, 0, 0, V)
  end
end
p1 = Builder.params_of(g)
chk(p1['entries'].size == slots.size, "every location framed (#{p1['entries'].size}/#{slots.size})")
chk(kerf_cripples > 0, "#{kerf_cripples} cripples cut from offcuts")
r = Inspector.inspect_wall(p1, p1['entries'], table: Project.header_table)
chk(r['correct'] == r['total'], "inspection: #{r['summary']}")
st = Yard.stats; puts "   stats: #{st}"
chk(Yard.data['cart'].empty?, 'cart empty after framing')
# mistakes: pull a jack and replace with a precut stud (too long)
jack = slots.find { |s| s.expected['role'] == 'Jack Stud' }
x0, z0, x1, z1 = Framing.slot_box(jack); aim.((x0+x1)/2, (z0+z1)/2); tool.onMouseMove(0,0,0,V)
menu = Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([])
tool.getMenu(menu); menu.items.first[1].call
chk(YardLogic.hand(Yard.data)['length'] == 81.0, 'pried jack is back in hand')
yd.fire('discard', { 'id' => Yard.data['hand'] })
pull.('2x6 92-5/8" precut studs'); aim.((x0+x1)/2, (z0+z1)/2); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
M.selection.clear; M.selection.add(g); DMACC::WallFramer.frame_wall
fd = UI::HtmlDialog.all.last; fd.fire('ready'); fd.fire('inspect')
ins = fd.last('load')['inspection']; puts '   ' + ins['summary']
chk(ins['wrong'] == 1 && ins['issues'][0]['message'].include?('too long'), 'inspection catches the long jack')
chk(fd.last('load')['slots'].any? { |s| s['flagged'] && s['installed'].include?("7' 8-5/8") }, 'member list shows flagged piece')
# occupied slot + empty hands
aim.((x0+x1)/2, (z0+z1)/2); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
chk(Sketchup.status_text.include?('already nailed'), "occupied message: #{Sketchup.status_text}")
# shop drawing
html = Dialogs.open_shop(g)
chk(true, 'shop drawing opens')
# report includes waste
Project.set_password('x'); Project.unlock('x')
File.write('/tmp/key2.json', JSON.generate({'walls'=>[Builder.snapshot_wall(g)], 'model'=>'k', 'created'=>'now'}))
UI.answers[:openpanel] = '/tmp/key2.json'; UI.answers[:savepanel] = '/tmp/rep2'
DMACC::WallFramer.grade_against_key
chk(File.read('/tmp/rep2.html').include?('Waste:'), 'report includes waste')
File.write('/tmp/yard_state.json', JSON.generate(yd.last('load')))
File.write('/tmp/frame_state2.json', JSON.generate(fd.last('load')))
puts($f ? 'SOME FAILED' : 'ALL PASSED')
