require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
g = Builder.create_wall(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(192, 0, 0), 'Level 1', 'EXT 2x6')
p = Builder.params_of(g)
p['openings'] = [{ 'mark' => 'W1', 'type' => 'Window', 'x' => 60.0, 'width' => 36.0, 'height' => 82.5, 'sill' => 34.5, 'header' => '2x10', 'plies' => 3 }]
p['openings_done'] = true
Builder.set_params(g, p)
p = Builder.params_of(g)
p['entries'] = Builder.work_slots(p).select { |s| %w[plates opening].include?(s.phase) }.to_h do |s|
  [s.id, s.expected.merge('pieces' => Array.new(s.plies || 1) { { 'size' => s.expected['size'], 'length' => s.expected['length'] } })]
end
Builder.set_params(g, p); Builder.rebuild(g)
DMACC::WallFramer.demo_tool
tool = M.instance_variable_get(:@tool) || DMACC::WallFramer.instance_variable_get(:@demo)
chk(tool.is_a?(DemoTool), 'Demo button picks up the cat\'s paw')
face = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
at = ->(role) { s = Builder.work_slots(Builder.params_of(g)).find { |x| x.expected['role'] == role }; x0, z0, x1, z1 = Framing.slot_box(s); face.((x0 + x1) / 2, (z0 + z1) / 2); s }
# header: all 3 plies come out, nothing rests on it here
hs = at.('Header'); tool.onMouseMove(0, 0, 0, V)
chk(tool.instance_variable_get(:@hit)&.dig(2)&.id == hs.id, 'hovering the header targets it')
tool.onLButtonDown(0, 0, 0, V)
chk(!Builder.params_of(g)['entries'][hs.id], 'header pulled - all 3 plies')
# a jack: the sill rests on it -> asks, pulls both
UI.answers[:msg] = IDYES
js = at.('Jack Stud'); tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V)
e = Builder.params_of(g)['entries']
chk(UI.messages.last.to_s =~ /rests? on the W1/ && !e[js.id] && Builder.work_slots(Builder.params_of(g)).none? { |s| s.expected['role'] == 'Rough Sill' && e[s.id] },
    "jack: asks first, pulls the sill with it (#{UI.messages.last})")
# say No -> nothing pulled
UI.answers[:msg] = IDNO
ks = at.('King Stud'); tool.onMouseMove(0, 0, 0, V)
before = Builder.params_of(g)['entries'].keys.size
tool.onLButtonDown(0, 0, 0, V)
chk(Builder.params_of(g)['entries'].keys.size == before || Builder.params_of(g)['entries'][ks.id], 'No = nothing pulled')
# Esc -> back to framing
tool.onCancel(0, V)
chk(Dialogs.tool.is_a?(GuidedTool) && !Dialogs.tool.is_a?(DemoTool), 'Esc goes back to the Frame tool')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
