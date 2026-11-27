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
answers = []
UI.answers[:inputbox] = ->(prompts, vals, lists, title) { answers << title; @next.shift }
# student picks L at start, SINGLE at end (wrong), 16 O.C.
@next = [[CORNERS = GuidedTool::CORNERS['L']], [GuidedTool::CORNERS['single']], ['16']]
face.(s_w, 6, 50); tool.onMouseMove(0,0,0,V)
chk(tool.instance_variable_get(:@corner)&.last == 'start', 'hovering near the wall start targets its corner')
tool.onLButtonDown(0,0,0,V)
face.(s_w, 186, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
p = Builder.params_of(s_w)
chk(answers.last.start_with?('Stud layout'), 'after both corners -> O.C. pop-up')
chk(p['oc'] == 16.0 && p['marks'].size == 11, "commons laid out automatically (#{p['marks'].size} at 16\" O.C.)")
chk(Builder.stage(p) == 'framed', 'commons + end studs + corner post nailed automatically')
post = s_w.entities.find { |e| e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(Builder::DICT, 'role') == 'Corner Stud' }
chk(post, 'L-corner post drawn at the wall start')
Dialogs.inspect_group(s_w)
ins = Builder.params_of(s_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }; puts '   ' + ins['summary']
chk(ins['issues'].size == 1 && ins['issues'][0]['message'] == 'This corner needs an L-corner post.', "wrong corner flagged: #{ins['issues'].map { |i| i['message'] }}")
puts '   why: ' + ins['issues'][0]['hint'].to_s
# redo with right corners but wrong O.C.
Builder.reset_commons(s_w)
chk(Builder.stage(Builder.params_of(s_w)) == 'commons' && Yard.data['offcuts'].size >= 12, 'redo pulls the studs back (to the offcut pile)')
@next = [[GuidedTool::CORNERS['L']], [GuidedTool::CORNERS['L']], ['24']]
face.(s_w, 6, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
face.(s_w, 186, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
Dialogs.inspect_group(s_w); ins = Builder.params_of(s_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }
chk(ins['issues'].size == 1 && ins['issues'][0]['message'].include?('24" O.C. - this wall type is 16" O.C.'), "wrong O.C. flagged once: #{ins['issues'].map { |i| i['message'] }}")
# all right
Builder.reset_commons(s_w)
@next = [[GuidedTool::CORNERS['L']], [GuidedTool::CORNERS['L']], ['16']]
face.(s_w, 6, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
face.(s_w, 186, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
Dialogs.inspect_group(s_w); ins = Builder.params_of(s_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }; puts '   ' + ins['summary']
chk(ins['issues'].empty?, 'right corners + 16" O.C. passes')
# E: L where a single is right
Dialogs.focus_wall('W-102'); tool.activate
@next = [[GuidedTool::CORNERS['L']], [GuidedTool::CORNERS['single']], ['16']]
face.(e_w, 6, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
face.(e_w, 128, 50); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
Dialogs.inspect_group(e_w); ins = Builder.params_of(e_w)['last_inspection']; ins['issues'].reject! { |i| i['slot_id'] == 'TP:2' }
chk(ins['issues'].map { |i| i['message'] } == ['No corner post needed here.'], "extra post flagged: #{ins['issues'].map { |i| i['message'] }}")
cl = Dialogs.expected_cut_list; chk(cl[['2x6', 92.625]] > 0, 'cut list includes the corner posts')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
