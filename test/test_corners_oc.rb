require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
Project.update { |d| d['settings']['framing_table'] = false } # walls stay standing in this test
t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
t.onLButtonDown(0, 0, 0, V)
t.onMouseMove(0, 100, 0, V); t.onUserText("16'", V)
t.onMouseMove(0, 192, 80, V); t.onUserText("12'", V)
t.onMouseMove(0, 50, 144, V); t.onUserText("16'", V)
t.onMouseMove(0, 0, 70, V); t.onUserText("12'", V)
id_ = ->(n) { Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n } }
Builder.set_run(id_.('W-101'), 'through'); Builder.set_run(id_.('W-103'), 'through')
id = ->(n) { Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n } }
s_w = id.('W-101'); e_w = id.('W-102')
cn = ->(w) { Builder.params_of(w)['corner_need'].transform_values { |v| [v['type'], v['side'], v['by']].compact } }
chk(cn.(s_w) == { 'start' => ['L', 'in', 'W-104'], 'end' => ['L', 'in', 'W-102'] }, "S (runs through) needs L posts both ends: #{cn.(s_w)}")
chk(cn.(e_w) == { 'start' => ['single'], 'end' => ['single'] }, "E (butts) needs single studs: #{cn.(e_w)}")
# get S to the stud step: plates in, no openings
prep = lambda do |w|
  p = Builder.params_of(w)
  p['entries'] = Builder.work_slots(p).select { |s| s.phase == 'plates' }.to_h { |s| [s.id, s.expected.merge('pieces' => [{ 'size' => s.expected['size'], 'length' => s.expected['length'] }])] }
  p['openings_done'] = true
  Builder.set_params(w, p); Builder.rebuild(w)
end
prep.(s_w); prep.(e_w)
Dialogs.focus_wall('W-101'); Dialogs.activate_tool; tool = Dialogs.tool
chk(Builder.stage(Builder.params_of(s_w)) == 'commons', 'S at the stud step')
face = ->(w, x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(w.transformation), Geom::Vector3d.new(0, 1, 0).transform(w.transformation)] }
UI.answers[:inputbox] = ->(*a) { raise "pop-up asked: #{a.last}" }
sl = Framing.stud_length(Builder.params_of(s_w))
studs = lambda do |w, st, en, oc|
  Dialogs.open_frame(w); fd = UI::HtmlDialog.all.reverse.find { |d| d.file.to_s.end_with?('frame.html') }; fd.fire('ready')
  { 'corner:start' => st, 'corner:end' => en, 'oc' => oc, 'common' => Framing.fmt_len(sl) }.each do |k, v|
    fd.fire('set_row', { 'key' => k, 'v' => v, 'size' => '2x6' })
  end
  fd
end
# hovering the wall end targets its corner; clicking opens the cut list at that row
face.(s_w, 6, 50); tool.onMouseMove(0,0,0,V)
chk(tool.instance_variable_get(:@corner)&.last == 'start', 'hovering near the wall start targets its corner')
tool.onLButtonDown(0,0,0,V)
fd = UI::HtmlDialog.all.reverse.find { |d| d.file.to_s.end_with?('frame.html') }; fd.fire('ready')
chk(fd.last('load')['goto_row'] == 'corner:start', 'clicking the corner opens its cut-list row')
# student picks L at start, SINGLE at end (wrong), 16 O.C.
studs.(s_w, 'L', 'single', '16')
p = Builder.params_of(s_w)
chk(p['oc'] == 16.0 && p['marks'].size == 11, "commons laid out automatically (#{p['marks'].size} at 16\" O.C.)")
chk(Builder.stage(p) == 'framed', 'commons + end studs + corner post nailed from the common row')
post = s_w.entities.find { |e| e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(Builder::DICT, 'role') == 'Corner Stud' }
chk(post, 'L-corner post drawn at the wall start')
Dialogs.inspect_group(s_w)
ins = Builder.params_of(s_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }; puts '   ' + ins['summary']
chk(ins['issues'].size == 1 && ins['issues'][0]['message'] == 'This corner needs an L-corner post.', "wrong corner flagged: #{ins['issues'].map { |i| i['message'] }}")
puts '   why: ' + ins['issues'][0]['hint'].to_s
# redo with right corners but wrong O.C.
Builder.reset_commons(s_w)
chk(Builder.stage(Builder.params_of(s_w)) == 'commons', 'redo pulls the studs back out')
chk((Builder.params_of(s_w)['cutlist'] || {}).keys.none? { |k| k.start_with?('corner:') || k == 'oc' }, 'redo empties the stud rows')
studs.(s_w, 'L', 'L', '24')
Dialogs.inspect_group(s_w); ins = Builder.params_of(s_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }
chk(ins['issues'].size == 1 && ins['issues'][0]['message'].include?('24" O.C. - this wall type is 16" O.C.'), "wrong O.C. flagged once: #{ins['issues'].map { |i| i['message'] }}")
# all right: just change the spacing row
fd.fire('set_row', { 'key' => 'oc', 'v' => '16' })
Dialogs.inspect_group(s_w); ins = Builder.params_of(s_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }; puts '   ' + ins['summary']
chk(ins['issues'].empty?, 'right corners + 16" O.C. passes')
# E: L where a single is right
Dialogs.focus_wall('W-102'); tool.activate
studs.(e_w, 'L', 'single', '16')
Dialogs.inspect_group(e_w); ins = Builder.params_of(e_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }
chk(ins['issues'].map { |i| i['message'] } == ['No corner post needed here.'], "extra post flagged: #{ins['issues'].map { |i| i['message'] }}")
cl = Dialogs.expected_cut_list; chk(cl[['2x6', 92.625]] > 0, 'cut list includes the corner posts')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
