# Things students do that aren't the happy path. Each case runs on its own; an exception
# or a dead end is a FINDING.
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
$findings = []
def finding(m) = ($findings << m; puts "FINDING #{m}")
def ok(m) = puts("ok   #{m}")
def kase(name)
  $stdout.puts "--- #{name}"; $stdout.flush
  yield
rescue StandardError => e
  finding("#{name}: CRASH #{e.class}: #{e.message} @ #{e.backtrace.find { |l| l.include?('dmacc_wall_framer') }}")
end
Project.import_sfpa(File.join(__dir__, 'fixtures', 'sfpa_fake.json'))
Project.update { |d| d['settings']['framing_table'] = false } # these cases are about the framing steps, not the table

def box(w, h, type = 'EXT 2x6', x0 = 0, y0 = 0)
  t = DrawWallTool.new('Level 1', type); t.activate
  pts = [[x0, y0], [x0 + w, y0], [x0 + w, y0 + h], [x0, y0 + h]]
  t.onLButtonDown(0, pts[0][0], pts[0][1], V)
  pts.each_with_index do |a, i|
    b = pts[(i + 1) % 4]
    len = Math.hypot(b[0] - a[0], b[1] - a[1])
    t.onMouseMove(0, a[0] + (b[0] - a[0]) / len * 30, a[1] + (b[1] - a[1]) / len * 30, V)
    t.onUserText(Framing.fmt_len(len), V)
  end
end
box(240, 168)
ws = -> { Builder.all_walls.sort_by { |w| Builder.params_of(w)['id'] } }
id = ->(n) { Builder.all_walls.find { |w| Builder.params_of(w)['id'] == n } }
Builder.set_run(id.('W-101'), 'through'); Builder.set_run(id.('W-103'), 'through')
Builder.create_wall(Geom::Point3d.new(100, 5.5, 0), Geom::Point3d.new(100, 162.5, 0), 'Level 1', 'INT 2x4')
Builder.resolve_layout('Level 1')
Builder.refresh_corner_needs
Dialogs.open_yard; YD = UI::HtmlDialog.all.last; YD.fire('ready')
Dialogs.activate_tool; T = Dialogs.tool; T.activate
UI.answers[:msg] = IDYES
def face(g, x, z) = (V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)])
def click(g, x, z) = (face(g, x, z); T.onMouseMove(0, 0, 0, V); T.onLButtonDown(0, 0, 0, V))
s = id.('W-101')
slot = ->(g, sid) { Builder.work_slots(Builder.params_of(g)).find { |x| x.id == sid } }
cslot = ->(g, sl) { x0, z0, x1, z1 = Framing.slot_box(sl); click(g, (x0 + x1) / 2, (z0 + z1) / 2) }
require_relative 'cut_student'
row = lambda do |g, key, v, size = nil|
  Dialogs.open_frame(g); d = CutStudent.frame_dialog; d.fire('ready')
  d.fire('set_row', { 'key' => key, 'v' => v, 'size' => size }); d.last('rowsUpdate')
end

# Openings go in through the Frame Wall form (the old pop-ups are gone). Returns the form's errors.
def opening_form(g, rows)
  Dialogs.open_frame(g); d = CutStudent.frame_dialog; d.fire('ready')
  have = d.last('load')['openings']
  add = rows.map { |m, t, x, w, h, head, hdr, pl| { 'mark' => m, 'type' => t, 'x_text' => x, 'width_text' => w, 'height_text' => h, 'sill_text' => head.to_s, 'header' => hdr, 'plies' => pl } }
  sc = d.instance_variable_get(:@scripts); n = sc.size
  d.fire('save_openings', { 'pos_mode' => 'center', 'openings' => have + add })
  e = sc[n..].reverse.find { |x| x.start_with?('openingErrors(') }
  e ? JSON.parse(e[14..-2]) : []
end

kase('clicking a piece asks nothing') do
  UI.answers[:inputbox] = ->(*_) { finding('a pop-up came up'); nil }
  cslot.(s, slot.(s, 'BP'))
  Builder.params_of(s)['entries'].to_h.empty? ? ok('click = cut list opens, nothing nailed') : finding('click still nailed something')
  CutStudent.frame_dialog.fire('ready')
  CutStudent.frame_dialog.last('load')['goto_row'] == 'plate:BP' ? ok('opened at the bottom plate row') : finding('click did not open the plate row')
end

kase('garbage lengths') do
  u = row.(s, 'plate:BP', 'abc', '2x6')
  u['err'].to_s.include?("Couldn't read") ? ok('garbage length -> friendly message in the row') : finding("garbage length: no message (#{u['err']})")
end

kase('19 ft plate on a 20 ft wall') do
  u = row.(s, 'plate:BP', "19'", '2x6')
  u['err'].to_s.include?("Longest plate stock is 16'") ? ok('over-16 ft piece -> splice message') : finding('19 ft piece: no splice message')
end

kase('wrong plate length, then fix with Demo') do
  w2 = id.('W-102') # 13' 1" butt wall
  row.(w2, 'plate:BP', "12'", '2x6')
  e = Builder.params_of(w2)['entries']['BP']
  if e && e['length'] == 144.0
    r = Inspector.inspect_wall(Builder.params_of(w2), Builder.params_of(w2)['entries'], level: 'coach')
    r['issues'].any? { |i| i.slot_id == 'BP' } ? ok('short plate flagged at inspection') : finding('short plate not flagged')
    DMACC::WallFramer.demo_tool
    d = DMACC::WallFramer.instance_variable_get(:@demo)
    sl = slot.(w2, 'BP'); _x0, z0, _x1, z1 = Framing.slot_box(sl); face(w2, 60, (z0 + z1) / 2)
    d.onMouseMove(0, 0, 0, V); d.onLButtonDown(0, 0, 0, V)
    Builder.params_of(w2)['entries']['BP'] ? finding('Demo did not pull the plate') : ok('Demo pulled the bad plate')
    (Builder.params_of(w2)['cutlist'] || {})['plate:BP'] ? finding('the row still shows the pulled plate') : ok('and its cut-list row emptied')
    DMACC::WallFramer.frame_tool
  else
    finding("12' bottom plate: #{e.inspect[0, 120]}")
  end
end

# plates on every wall, the right way
pl = ->(g) { CutStudent.fill(g, only: %w[plate:BP plate:TP:1]) }
kase('plates everywhere') { ws.().each { |g| pl.(g) }; ok("plates in: #{ws.().map { |g| Builder.stage(Builder.params_of(g)) }.uniq}") }

kase('opening form mistakes') do
  bad = { 'too close to the wall start' => [['W1', 'Window', '20"', '36', '48', '82 1/2', '2x8', '3'], 'too close to the wall start'],
          'header won\'t fit' => [['W1', 'Window', "8'", '36', '48', "8' 2\"", '2x8', '3'], 'fit'],
          'no plies' => [['W1', 'Window', "8'", '36', '48', '82 1/2', '2x8', '--'], 'plies'],
          'no header picked' => [['W1', 'Window', "8'", '36', '48', '82 1/2', Framing::HDR_PICK, '3'], 'pick the header'],
          'blank width' => [['W1', 'Window', "8'", '', '48', '82 1/2', '2x8', '3'], 'width'] }
  bad.each do |k, (r, want)|
    errs = opening_form(s, [r]).join(' | ')
    errs.include?(want) ? ok("opening check: #{k}") : finding("opening form didn't catch: #{k} (#{errs[0, 120]})")
  end
  Builder.params_of(s)['openings'].empty? ? ok('nothing laid out after the mistakes') : finding("opening saved despite errors: #{Builder.params_of(s)['openings'].map { |o| o['mark'] }}")
end

kase('duplicate mark on another wall') do
  e1 = opening_form(s, [['W1', 'Window', "5'", '36', '48', '82 1/2', '2x8', '3']])
  e1.empty? ? ok('W1 on W-101') : finding("W1 refused: #{e1}")
  e2 = opening_form(id.('W-103'), [['W1', 'Window', "4'", '36', '48', '82 1/2', '2x8', '3']])
  e2.any? { |x| x.include?('already used') } ? ok('duplicate mark caught') : finding("duplicate mark across walls not caught (#{e2})")
end

kase('door right where a partition tees in') do
  q = Builder.params_of(id.('W-103'))
  tee = (q['tee_need'] || []).first
  if tee
    mid = (tee['a0'].to_f + tee['a1'].to_f) / 2.0
    errs = opening_form(id.('W-103'), [['D9', 'Door', Framing.fmt_len(Framing.layout_dist(q, mid)), '30', '82 1/2', nil, '2x10', '3']])
    if Builder.params_of(id.('W-103'))['openings'].any? { |o| o['mark'] == 'D9' }
      finding("a door can be laid out right where a partition tees in (tee at #{tee['a0']}..#{tee['a1']} on W-103) - no warning")
    else
      ok("door over the tee refused: #{errs.first.to_s[0, 90]}")
    end
  else
    ok('no tee on W-103 to test')
  end
end

kase('window right next to an L-corner post') do
  w4 = id.('W-103')
  q = Builder.params_of(w4)
  end_l = (q['corner_need'] || {}).find { |_k, v| v['type'] == 'L' }
  if end_l
    x = end_l[0] == 'start' ? 26.5 : q['length'].to_f - 26.5
    errs = opening_form(w4, [['W7', 'Window', Framing.fmt_len(Framing.layout_dist(q, x)), '36', '48', '82 1/2', '2x8', '3']])
    o = Builder.params_of(w4)['openings'].find { |op| op['mark'] == 'W7' }
    if o
      king = end_l[0] == 'start' ? o['x'] - 3.0 : o['x'] + o['width'] + 1.5
      post = end_l[0] == 'start' ? [1.5, 7.0] : [q['length'].to_f - 7.0, q['length'].to_f - 1.5]
      king < post[1] && king + 1.5 > post[0] ? finding("W7's king stud lands on the L-corner post (king #{king}, post #{post})") : ok('window near the L corner clears the post')
      Builder.params_of(w4).then { |qq| qq['openings'] = qq['openings'].reject { |op| op['mark'] == 'W7' }; Builder.set_params(w4, qq) }
    else
      ok("window over the L post refused: #{errs.first.to_s[0, 100]}")
    end
  else
    ok('no L corner on W-103 to test')
  end
end

kase('opening wider than 6 ft (2 jacks)') do
  w3 = id.('W-101')
  q = Builder.params_of(w3)
  errs = opening_form(w3, [['W4', 'Window', Framing.fmt_len(Framing.layout_dist(q, 175.0)), '96', '48', '82 1/2', '2x12', '3']])
  q = Builder.params_of(w3)
  jacks = Builder.work_slots(q).count { |x| x.opening == 'W4' && x.expected['role'] == 'Jack Stud' }
  jacks == 4 ? ok('8 ft window gets 2 jacks each side') : finding("8 ft window jacks: #{jacks} (#{errs.first(2)})")
end

kase('clockwise loop in Place Walls is undone') do
  n = Builder.all_walls.size
  V.ray = nil
  t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
  pts = [[600, 0], [600, 120], [720, 120], [720, 0]] # up, right, down = clockwise
  t.onLButtonDown(0, 600, 0, V)
  pts.each_with_index do |a, i|
    b = pts[(i + 1) % 4]; len = Math.hypot(b[0] - a[0], b[1] - a[1])
    t.onMouseMove(0, a[0] + (b[0] - a[0]) / len * 30, a[1] + (b[1] - a[1]) / len * 30, V)
    t.onUserText(Framing.fmt_len(len), V)
  end
  Builder.all_walls.size == n ? ok("clockwise loop undone: #{Sketchup.status_text.to_s[0, 80]}") : finding("clockwise loop kept #{Builder.all_walls.size - n} walls")
end

kase('wall over 40 ft refused') do
  n = Builder.all_walls.size
  V.ray = nil
  t = DrawWallTool.new('Level 1', 'EXT 2x6'); t.activate
  t.onLButtonDown(0, 0, 600, V); t.onMouseMove(0, 30, 600, V); t.onUserText("42'", V)
  Builder.all_walls.size == n ? ok('42 ft wall refused') : finding('42 ft wall was drawn')
  t.onCancel(0, V) if t.respond_to?(:onCancel)
end

kase('change a corner after framing') do
  w2 = id.('W-102')
  before = UI.messages.size
  ct = CornerTool.new('Level 1'); ct.activate
  ct.instance_variable_set(:@hover, id.('W-101'))
  V.ray = nil
  hit = Builder.affected_by_run(id.('W-101'), 'butt')
  ok("flipping W-101 to butt would change: #{hit}")
end

kase('switch the layout end after studs are in') do
  w3 = id.('W-103')
  q = Builder.params_of(w3); q['openings_done'] = true; Builder.set_params(w3, q)
  CutStudent.fill(w3)
  n0 = (Builder.params_of(w3)['marks'] || []).size
  Builder.set_layout_from(w3, true)
  q = Builder.params_of(w3)
  n0.positive? ? ok("#{n0} studs were in before the switch") : finding('no studs went in from the cut list')
  Framing.from_end?(q) && (q['marks'] || []).any? ? ok("layout end switch re-laid #{q['marks'].size} studs from the far end, from the same rows") : finding('layout end switch left no layout')
  %w[cripples framed].include?(Builder.stage(q)) ? ok("still past the studs (#{Builder.stage(q)})") : finding("after layout switch stage = #{Builder.stage(q)}")
end

kase('delete a wall that has double plate pieces') do
  ids = ['W-105']
  w5 = id.('W-105')
  Builder.forget_dtp(ids)
  w5.locked = false
  w5.erase! if w5.respond_to?(:erase!)
  Builder.refresh_corner_needs
  ok('wall deleted, double plate order cleaned')
end

kase('random clicks in empty space and on the yard') do
  V.ray = [Geom::Point3d.new(5000, 5000, 300), Geom::Vector3d.new(0, 0, -1)]
  T.onMouseMove(0, 0, 0, V); T.onLButtonDown(0, 0, 0, V)
  T.onUserText('48', V)
  ok('clicks on nothing: no crash')
end

kase('panel callbacks with nothing selected') do
  %w[inspect shop openings openings_done notes_seen dtp check_interlock].each { |c| YD.fire(c) rescue finding("panel #{c}: #{$!.message}") }
  YD.fire('edit_opening', { 'mark' => 'NOPE' })
  YD.fire('remove_opening', { 'mark' => 'NOPE' })
  YD.fire('focus', { 'id' => 'W-999' })
  ok('panel buttons with odd input: no crash')
end

kase('wall type change mid-framing') do
  w4 = id.('W-104')
  q = Builder.params_of(w4)
  ty = Project.wall_type('INT 2x4')
  Builder.apply_type(q, ty)
  Builder.set_params(w4, q); Builder.rebuild(w4)
  Inspector.inspect_wall(Builder.params_of(w4), Builder.params_of(w4)['entries'], level: 'coach')
  ok('wall type changed after plates: inspection runs')
end

kase('grade a model with no walls in the key') do
  res = AnswerKey.compare({ 'walls' => [] }, DMACC::WallFramer.student_snapshot)
  DMACC::WallFramer.report_html(res, { 'model' => 'x', 'created' => 'y' })
  ok('empty key grades without crashing')
end

kase('Build and stand wall before the cut list is done') do
  w = id.('W-104')
  Dialogs.open_frame(w); d = CutStudent.frame_dialog; d.fire('ready')
  d.fire('build_stand')
  msg = d.scripts.reverse.find { |x| x.start_with?('setStatus(') }.to_s
  msg.include?('Not built yet') ? ok("refused with a reason: #{msg[10, 90]}") : finding("Build and stand on an unfinished wall: #{msg[0, 100]}")
end

kase('Frame Wall form buttons after its wall was deleted') do
  w = Builder.create_wall(Geom::Point3d.new(0, 400, 0), Geom::Point3d.new(120, 400, 0), 'Level 1', 'INT 2x4')
  Dialogs.open_frame(w); d = CutStudent.frame_dialog; d.fire('ready')
  Sketchup.active_model.entities.instance_variable_get(:@items).delete(w)
  %w[ready frame_next continue build_stand shop inspect stand_up].each { |c| d.fire(c) rescue finding("form #{c} after delete: #{$!.class} #{$!.message}") }
  d.fire('set_row', { 'key' => 'plate:BP', 'v' => "10'", 'size' => '2x4' }) rescue finding("set_row after delete: #{$!.message}")
  d.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [] }) rescue finding("save_openings after delete: #{$!.message}")
  ok('form buttons on a deleted wall: no crash')
end

kase('Continue framing / Lists buttons with nothing on the table') do
  Builder.table_walls.each { |w| Builder.stand_up(w) }
  Dialogs.open_frame(id.('W-101')); d = CutStudent.frame_dialog
  d.fire('continue') rescue finding("continue: #{$!.message}")
  DMACC::WallFramer.shop_tool rescue finding("shop: #{$!.message}")
  DMACC::WallFramer.inspect_tool rescue finding("inspect: #{$!.message}")
  DMACC::WallFramer.dtp_tool rescue finding("dtp: #{$!.message}")
  DMACC::WallFramer.tape_tool rescue finding("tape: #{$!.message}")
  DMACC::WallFramer.frame_tool rescue finding("frame: #{$!.message}")
  ok('toolbar buttons in odd states: no crash')
end

kase('Instructor menu without the password') do
  n = UI.messages.size
  Instructor.fill_wall; Instructor.frame_floor; Instructor.reset_wall; Instructor.draw_test_house
  ms = UI.messages[n..]
  ms.size == 4 && ms.all? { |m| m.include?('Instructor only') } ? ok('no password on the model: all four refuse') : finding("instructor items without a password: #{ms.first(2)}")
  Project.set_password('pw'); Project.relock
  n = UI.messages.size
  Instructor.fill_wall
  UI.messages[n..].any? { |m| m.include?('Unlock in Project Setup') } ? ok('password set but locked: refuses') : finding("locked instructor menu: #{UI.messages[n..].first}")
end

kase('Level 2 drawn clockwise') do
  Project.update { |dd| dd['levels'] << { 'name' => 'Level 2', 'elev' => 109.0 } unless dd['levels'].any? { |l| l['name'] == 'Level 2' } }
  V.ray = nil
  n = Builder.all_walls.size
  t = DrawWallTool.new('Level 2', 'EXT 2x6'); t.activate
  pts = [[0, 0], [0, 168], [240, 168], [240, 0]]
  t.onLButtonDown(0, 0, 0, V)
  pts.each_with_index do |a, i|
    b = pts[(i + 1) % 4]; len = Math.hypot(b[0] - a[0], b[1] - a[1])
    t.onMouseMove(0, a[0] + (b[0] - a[0]) / len * 30, a[1] + (b[1] - a[1]) / len * 30, V)
    t.onUserText(Framing.fmt_len(len), V)
  end
  ids = Builder.all_walls.select { |w| Builder.params_of(w)['level'] == 'Level 2' }.map { |w| Builder.params_of(w)['id'] }
  ids.empty? ? ok('Level 2 clockwise loop undone') : finding("Level 2 clockwise loop kept #{ids}")
  pts = [[0, 0], [240, 0], [240, 168], [0, 168]]
  t = DrawWallTool.new('Level 2', 'EXT 2x6'); t.activate
  t.onLButtonDown(0, 0, 0, V)
  pts.each_with_index do |a, i|
    b = pts[(i + 1) % 4]; len = Math.hypot(b[0] - a[0], b[1] - a[1])
    t.onMouseMove(0, a[0] + (b[0] - a[0]) / len * 30, a[1] + (b[1] - a[1]) / len * 30, V)
    t.onUserText(Framing.fmt_len(len), V)
  end
  ids = Builder.all_walls.select { |w| Builder.params_of(w)['level'] == 'Level 2' }.map { |w| Builder.params_of(w)['id'] }.sort
  ids == %w[W-201 W-202 W-203 W-204] ? ok("redrawn counterclockwise: #{ids} (numbers given back)") : finding("Level 2 redraw got ids #{ids}")
end

File.write('/tmp/stress_edges.json', JSON.generate($findings))
puts($findings.empty? ? 'ALL PASSED' : "#{$findings.size} FINDINGS")
