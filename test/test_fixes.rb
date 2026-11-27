# v0.11 fixes: RFIs, flat headers, header marks, tee backing, layout end, selection, double plate pieces
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end

# ---- flat headers ----
o = { 'mark' => 'D9', 'type' => 'Door', 'x' => 20, 'width' => 32, 'height' => 82.5, 'sill' => 0, 'header' => Framing::FLAT }
hd = Framing.header_dims(o, 3.5)
chk(hd['flat'] && hd['plies'] == 2 && hd['height'] == 3.0, "(2) 2x4 flat header: #{hd}")
chk(Framing.header_label(o) == '(2) 2x4 flat', 'flat header label')
chk(Framing.header_dims(o.merge('header' => Framing::RFI), 3.5).nil?, 'RFI header has no size yet')

# ---- layout from the other end ----
w = Framing::DEFAULT_WALL.merge('length' => 100.0, 'spacing' => 16.0)
a = Framing.layout_marks(w)
b = Framing.layout_marks(w.merge('layout_from' => 'end'))
chk(a.first == 15.25 && b.last == 100 - 16 - 0.75, "layout pulls from either end: #{a.first} / #{b.last}")

# ---- bunkhouse with a closet partition teeing into the south wall ----
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V)
t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
t.onMouseMove(0, 192, 80, V); t.onUserText("12'", V)
t.onMouseMove(0, 50, 144, V); t.onUserText("16'", V)
t.onMouseMove(0, 0, 70, V); t.onUserText("12'", V)
id = ->(n) { Builder.all_walls.find { |x| Builder.params_of(x)['id'] == n } }
Builder.set_run(id.('W-101'), 'through'); Builder.set_run(id.('W-103'), 'through')
Builder.create_wall(Geom::Point3d.new(138.5, 5.5, 0), Geom::Point3d.new(138.5, 138.5, 0), 'Level 1', 'INT 2x4')
Builder.resolve_layout('Level 1')
Builder.refresh_corner_needs('Level 1')
s = id.('W-101'); sp = Builder.params_of(s)
chk((sp['tee_need'] || []).map { |x| x['id'] } == ['W-105'], "closet tee found on the south wall: #{sp['tee_need']}")
tee = Builder.work_slots(sp).find { |x| x.id == 'TEE:W-105' }
chk(tee && tee.kind == :backing, 'tee shows up as a backing spot')
chk(Builder.gate_reason(sp, tee).to_s.include?('studs first'), 'backing waits for the studs')

# selection clears when a framing tool starts (no red locked walls)
M.selection.add(s)
Dialogs.activate_tool; tool = Dialogs.instance_variable_get(:@tool); tool.activate
chk(M.selection.to_a.empty?, 'framing tool clears the selection')

# frame commons on the south wall the quick way, then add backing
fill = lambda do |wall, skip = []|
  p = Builder.params_of(wall)
  p['oc'] = 16.0
  p['marks'] = Framing.auto_marks(p, 16.0)
  p['openings_done'] = true
  p['entries'] = Builder.work_slots(p).reject { |x| x.id == 'TP:2' || x.kind == :backing || skip.include?(x.phase) }.to_h do |x|
    [x.id, x.expected.merge('pieces' => Array.new(x.plies || 1) { { 'size' => x.expected['size'], 'length' => x.expected['length'] } })]
  end
  Builder.set_params(wall, p); Builder.rebuild(wall)
end
fill.(s)
err = Builder.install_tee(s, 'W-105', 'ladder')
e = Builder.params_of(s)['entries']['TEE:W-105']
chk(err.nil? && e && e['geom'].count { |g| g['role'] == 'Ladder Block' } >= 3, "ladder blocking in: #{e && e['geom'].map { |g| g['role'] }.tally}")
pulled = Builder.remove_backing(s, 'TEE:W-105')
chk(pulled.size == e['pieces'].size && !Builder.params_of(s)['entries']['TEE:W-105'], 'backing comes out as a set')
Builder.install_tee(s, 'W-105', 'channel')
e = Builder.params_of(s)['entries']['TEE:W-105']
chk(e['geom'].count { |g| g['role'] == 'Backing Stud' } == 2, '3-stud channel: two studs flank the partition')
r = Inspector.inspect_wall(Builder.params_of(s), Builder.params_of(s)['entries'], student_layout: true)
chk(r['issues'].none? { |i| i.message.include?('backing') }, "backing counts at inspection: #{r['summary']}")

# ---- RFIs ----
UI.answers[:msg] = IDYES
n = Project.submit_rfi('W-101', 'W7', 'Header for W7?')
p = Builder.params_of(s)
p['openings'] = [{ 'mark' => 'W7', 'type' => 'Window', 'x' => 60.0, 'width' => 36.0, 'height' => 82.5, 'sill' => 34.5, 'header' => Framing::RFI, 'rfi' => n }]
Builder.set_params(s, p)
hs = Builder.work_slots(Builder.params_of(s)).find { |x| x.opening == 'W7' }
chk(Builder.gate_reason(Builder.params_of(s), hs).to_s.include?('on hold'), 'opening on hold while the RFI is out')
chk(Project.release_rfis.empty?, 'no answer before the delay')
Project.set_password('shop'); Project.relock
st = Dialogs.rfi_state.first
chk(st['status'] == 'submitted - awaiting response' && !st.key?('left'), "students see no countdown: #{st['status']}")
Project.update { |d| d['span_table'] = [{ 'size' => '2x8', 'plies' => 2, 'span' => 48.0, 'jacks' => 1 }, { 'size' => '2x10', 'plies' => 2, 'span' => 72.0, 'jacks' => 2 }] }
Project.unlock('shop')
chk(Dialogs.rfi_state.first['status'].include?('min'), "instructor sees the time left: #{Dialogs.rfi_state.first['status']}")
Project.update { |d| d['rfis'][0]['at'] -= 33 * 60 }
done = Project.release_rfis
o7 = Builder.params_of(s)['openings'].first
chk(done.size == 1 && o7['header'] == '2x8' && o7['plies'] == 2 && !o7['rfi'], "answered from the span table after 32 min: #{done.first && done.first['answer']}")
# non-bearing wall: flat
cl = id.('W-105')
n2 = Project.submit_rfi('W-105', 'D5', 'Header for D5?')
p = Builder.params_of(cl)
p['openings'] = [{ 'mark' => 'D5', 'type' => 'Door', 'x' => 40.0, 'width' => 30.0, 'height' => 82.5, 'sill' => 0, 'header' => Framing::RFI, 'rfi' => n2 }]
Builder.set_params(cl, p)
done = Project.release_rfis(n2)
chk(done.size == 1 && Builder.params_of(cl)['openings'].first['header'] == Framing::FLAT, 'instructor answers early; non-bearing gets (2) 2x4 flat')
html = DMACC::WallFramer.rfi_html
chk(html.include?('#1') && html.include?('#2') && html.include?('flat'), 'RFIs logged in the grade report')

# ---- Frame mode won't pull a double plate ----
fill.(s); fill.(id.('W-102')); fill.(id.('W-103')); fill.(id.('W-104')); fill.(cl)
Builder.install_tee(s, 'W-105', 'channel')
Builder.install_tee(id.('W-103'), 'W-105', 'channel') if Builder.work_slots(Builder.params_of(id.('W-103'))).any? { |x| x.id == 'TEE:W-105' }
puts "   blockers: #{Builder.dtp_blockers('Level 1')}"
chk(Builder.place_dtp(id.('W-102'), 60).nil?, 'double plate piece on')
slot = Builder.work_slots(Builder.params_of(id.('W-102'))).find { |x| x.id == 'TP:2' }
tool.pull(id.('W-102'), slot)
chk(Builder.params_of(id.('W-102'))['entries']['TP:2'] && Sketchup.status_text.include?('Right-click the double plate'), 'Frame mode never pulls a double plate whole')
chk(Builder.dtp_order == ['W-102'], 'order has no ghosts')

# ---- legacy double plate data migrates to pieces ----
Project.update { |d| d['dtp_seq'] = nil; d['dtp_order'] = ['W-102'] }
chk(Builder.dtp_seq.size == 1 && Builder.dtp_seq.first['wall'] == 'W-102', 'old double plate order converts to pieces')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
