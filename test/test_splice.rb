# Plate splices on walls over 16'
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
Project.update { |d| d['settings']['framing_table'] = false } # walls stay standing in this test
g = Builder.create_wall(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(240, 0, 0), 'Level 1', 'EXT 2x6') # 20'
Dialogs.activate_tool; tool = Dialogs.tool; tool.activate
face = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
prompts = []
answers = []
UI.answers[:inputbox] = ->(pr, *_) { prompts << pr.join(' '); answers.shift }
bp = -> { Builder.work_slots(Builder.params_of(g)).find { |s| s.id == 'BP' } }
click = ->(s) { x0, z0, x1, z1 = Framing.slot_box(s); face.(60, (z0 + z1) / 2); tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V) }
UI.answers[:msg] = IDYES
Dialogs.open_frame(g); fd = UI::HtmlDialog.all.reverse.find { |d| d.file.to_s.end_with?('frame.html') }; fd.fire('ready')
set = ->(v) { fd.fire('set_row', { 'key' => 'plate:BP', 'v' => v, 'size' => '2x6' }); fd.last('rowsUpdate') }
# a 20' piece is refused (no stock that long)
u = set.("20'")
chk(u['err'].to_s.include?("16'") && !Builder.params_of(g)['entries']['BP'], "20' piece refused: #{u['err']}")
chk(u['err'].include?('Splice it'), 'the row explains the splice')
# 16' first - plate not finished yet
u = set.("16'")
e = Builder.params_of(g)['entries']['BP']
chk(e && e['full'] == false && Builder.stage(Builder.params_of(g)) == 'plates', 'first piece on, plate not finished yet')
chk(u['rows'][0]['note'].include?('Splice in the next piece'), "told to add the next piece: #{u['rows'][0]['note']}")
# then 4' - splice at 16' lands on a stud at any layout
set.("16', 4'")
e = Builder.params_of(g)['entries']['BP']
chk(e['full'] && Framing.plate_splices(e) == [192.0], "plate finished, spliced at 16': #{Framing.plate_splices(e)}")
ms = Framing.members_for_entry(Builder.params_of(g), bp.(), e)
chk(ms.size == 2, 'two plate pieces drawn (joint shows)')
r = Inspector.inspect_wall(Builder.params_of(g), Builder.params_of(g)['entries'], level: 'fix')
chk(r['issues'].none? { |i| i.slot_id.to_s.start_with?('SPLICE') }, '16\' splice passes (16", 19.2", 24" all land)')
[19.2, 24.0].each do |sp|
  pr = Builder.params_of(g).merge('oc' => sp)
  r = Inspector.inspect_wall(pr, pr['entries'], level: 'fix')
  chk(r['issues'].none? { |i| i.slot_id.to_s.start_with?('SPLICE') }, "16' splice on #{sp}\" layout passes")
end
# a bad splice: 15' 6" + 4' 6"
set.("15' 6\", 4' 6\"")
r = Inspector.inspect_wall(Builder.params_of(g), Builder.params_of(g)['entries'], level: 'fix')
iss = r['issues'].find { |i| i.slot_id == 'SPLICE:BP' }
chk(iss && iss.message.include?("15' 6\""), "off-stud splice flagged: #{iss && iss.message}")
set.("16', 4'")
# a wall 16' or under never splices
g2 = Builder.create_wall(Geom::Point3d.new(0, 100, 0), Geom::Point3d.new(144, 100, 0), 'Level 1', 'EXT 2x6')
s2 = Builder.work_slots(Builder.params_of(g2)).find { |s| s.id == 'BP' }
Builder.nail_supplied(g2, s2, '2x6', 100.0)
chk(Builder.params_of(g2)['entries']['BP']['full'], 'walls 16\' and under: one piece, no splice')

# ---- double top plate splices: students pick them; bad ones get a hint ----
p = Builder.params_of(g)
p['entries'] = Builder.work_slots(p).reject { |x| %w[BP TP:1 TP:2].include?(x.id) }.to_h do |x|
  [x.id, x.expected.merge('pieces' => Array.new(x.plies || 1) { { 'size' => x.expected['size'], 'length' => x.expected['length'] } })]
end.merge('BP' => Framing.plate_entry(p, 'Bottom Plate', [{ 'size' => '2x6', 'length' => 192.0 }, { 'size' => '2x6', 'length' => 48.0 }]),
          'TP:1' => Framing.plate_entry(p, 'Top Plate', [{ 'size' => '2x6', 'length' => 192.0 }, { 'size' => '2x6', 'length' => 48.0 }]))
p['openings_done'] = true; p['oc'] = 16.0
p['marks'] = Framing.auto_marks(p, 16.0)
Builder.set_params(g, p)
p = Builder.params_of(g)
p['entries'] = p['entries'].merge(Builder.work_slots(p).select(&:common).to_h { |x| [x.id, x.expected.merge('pieces' => [{ 'size' => '2x6', 'length' => x.expected['length'] }])] })
Builder.set_params(g, p); Builder.rebuild(g)
q = Builder.params_of(g2); q['openings_done'] = true; q['oc'] = 16.0; q['marks'] = Framing.auto_marks(q, 16.0); Builder.set_params(g2, q)
q = Builder.params_of(g2)
q['entries'] = Builder.work_slots(q).reject { |x| x.id == 'TP:2' }.to_h { |x| [x.id, x.expected.merge('pieces' => [{ 'size' => '2x6', 'length' => x.expected['length'] }])] }
Builder.set_params(g2, q)
chk(Builder.dtp_blockers('Level 1').empty? || puts("   blockers #{Builder.dtp_blockers('Level 1')}"), 'wall framed - double plates open')
tool.set_mode(:dtp)
V.ray = [Geom::Point3d.new(100, 2.75, 500).transform(g.transformation), Geom::Vector3d.new(0, 0, -1).transform(g.transformation)]
tool.onMouseMove(0, 0, 0, V)
msgs = UI.messages.size
answers.clear
answers << ["16'"]       # splice right over the top plate splice -> hint
answers << ["15' 1\""]   # not on a stud -> hint
answers << ["12'"]       # on layout, 48" from the top plate splice -> good
tool.onLButtonDown(0, 0, 0, V)
hints = UI.messages[msgs..]
chk(hints.size == 2 && hints[0].include?('24'), "too close to the top plate splice -> hint: #{hints[0].to_s.lines[2].to_s.strip}")
chk(hints[1].to_s.include?("isn't centered on a stud"), "off a stud -> hint: #{hints[1].to_s.lines[2].to_s.strip[0, 80]}")
e = Builder.params_of(g)['entries']['TP:2']
chk(e && e['segs'].size == 2 && (e['segs'][0][1] - 144).abs < 0.01, "double plate on, spliced at 12' (joint shows): #{e && e['segs']}")
chk(prompts.any? { |x| x.include?("longest stock is 16'") }, 'pop-up says the run needs a splice')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
