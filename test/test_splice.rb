# Plate splices on walls over 16'
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
g = Builder.create_wall(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(240, 0, 0), 'Level 1', 'EXT 2x6') # 20'
Dialogs.activate_tool; tool = Dialogs.tool; tool.activate
face = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
prompts = []
answers = []
UI.answers[:inputbox] = ->(pr, *_) { prompts << pr.join(' '); answers.shift }
bp = -> { Builder.work_slots(Builder.params_of(g)).find { |s| s.id == 'BP' } }
click = ->(s) { x0, z0, x1, z1 = Framing.slot_box(s); face.(60, (z0 + z1) / 2); tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V) }
# a 20' piece is refused (no stock that long)
answers << ['2x6', "20'"]
UI.answers[:msg] = IDYES
click.(bp.())
chk(UI.messages.last.to_s.include?("16'") && !Builder.params_of(g)['entries']['BP'], "20' piece refused: #{UI.messages.last}")
chk(prompts.last.include?('Splice it'), 'pop-up explains the splice')
# 16' first, then 4' - splice at 16' lands on a stud at any layout
answers << ['2x6', "16'"]; click.(bp.())
e = Builder.params_of(g)['entries']['BP']
chk(e && e['full'] == false && Builder.stage(Builder.params_of(g)) == 'plates', 'first piece on, plate not finished yet')
chk(Sketchup.status_text.include?('click the plate again'), "told to add the next piece: #{Sketchup.status_text}")
answers << ['2x6', "4'"]; click.(bp.())
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
Builder.remove_piece(g, 'BP'); Builder.remove_piece(g, 'BP')
answers << ['2x6', "15' 6\""]; click.(bp.())
answers << ['2x6', "4' 6\""]; click.(bp.())
r = Inspector.inspect_wall(Builder.params_of(g), Builder.params_of(g)['entries'], level: 'fix')
iss = r['issues'].find { |i| i.slot_id == 'SPLICE:BP' }
chk(iss && iss.message.include?("15' 6\""), "off-stud splice flagged: #{iss && iss.message}")
# a wall 16' or under never splices
g2 = Builder.create_wall(Geom::Point3d.new(0, 100, 0), Geom::Point3d.new(144, 100, 0), 'Level 1', 'EXT 2x6')
s2 = Builder.work_slots(Builder.params_of(g2)).find { |s| s.id == 'BP' }
Builder.nail_supplied(g2, s2, '2x6', 100.0)
chk(Builder.params_of(g2)['entries']['BP']['full'], 'walls 16\' and under: one piece, no splice')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
