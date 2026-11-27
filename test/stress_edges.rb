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

kase('cancel every pop-up') do
  UI.answers[:inputbox] = nil
  cslot.(s, slot.(s, 'BP'))
  Builder.params_of(s)['entries'].to_h.empty? ? ok('cancel = nothing nailed') : finding('cancel still nailed something')
end

kase('garbage lengths') do
  seq = [['2x6', 'abc'], nil]
  UI.answers[:inputbox] = ->(*_) { seq.shift }
  m = UI.messages.size
  cslot.(s, slot.(s, 'BP'))
  UI.messages[m..].any? { |x| x.include?("Couldn't read") } ? ok('garbage length -> friendly message') : finding("garbage length: no message (#{UI.messages.last})")
end

kase('19 ft plate on a 20 ft wall') do
  seq = [['2x6', "19'"], nil]
  UI.answers[:inputbox] = ->(*_) { seq.shift }
  m = UI.messages.size
  cslot.(s, slot.(s, 'BP'))
  UI.messages[m..].any? { |x| x.include?("Longest plate stock is 16'") } ? ok('over-16 ft piece -> splice message') : finding('19 ft piece: no splice message')
end

kase('wrong plate length, then fix with Demo') do
  w2 = id.('W-102') # 13' 1" butt wall
  seq = [['2x6', "12'"]]
  UI.answers[:inputbox] = ->(*_) { seq.shift }
  cslot.(w2, slot.(w2, 'BP'))
  e = Builder.params_of(w2)['entries']['BP']
  if e && e['length'] == 144.0
    r = Inspector.inspect_wall(Builder.params_of(w2), Builder.params_of(w2)['entries'], level: 'coach')
    r['issues'].any? { |i| i.slot_id == 'BP' } ? ok('short plate flagged at inspection') : finding('short plate not flagged')
    DMACC::WallFramer.demo_tool
    d = DMACC::WallFramer.instance_variable_get(:@demo)
    sl = slot.(w2, 'BP'); _x0, z0, _x1, z1 = Framing.slot_box(sl); face(w2, 60, (z0 + z1) / 2)
    d.onMouseMove(0, 0, 0, V); d.onLButtonDown(0, 0, 0, V)
    Builder.params_of(w2)['entries']['BP'] ? finding('Demo did not pull the plate') : ok('Demo pulled the bad plate')
    DMACC::WallFramer.frame_tool
  else
    finding("12' bottom plate: #{e.inspect[0, 120]}")
  end
end

# plates on every wall, the right way
pl = lambda do |g|
  %w[BP TP:1].each do |sid|
    5.times do
      q = Builder.params_of(g)
      e = (q['entries'] || {})[sid]
      break if e && e['full'] != false
      left = q['length'].to_f - (e ? e['pieces'].sum { |pc| pc['length'].to_f } : 0)
      UI.answers[:inputbox] = ->(*_) { [q['stud'], Framing.fmt_len([left, 192].min)] }
      cslot.(g, slot.(g, sid))
    end
  end
end
kase('plates everywhere') { ws.().each { |g| pl.(g) }; ok("plates in: #{ws.().map { |g| Builder.stage(Builder.params_of(g)) }.uniq}") }

kase('opening pop-up mistakes') do
  bad = { 'too close to the wall start' => [["20\"", 'W1', 'Window'], %w[36 48 82.5 2x8 3], 'too close to the wall start'],
          'sill below the plate' => [["8'", 'W1', 'Window'], ['36', '80', '82 1/2', '2x8', '3'], 'down at the bottom plate'],
          "header won't fit" => [["8'", 'W1', 'Window'], ['36', '48', "8' 2\"", '2x8', '3'], "won't fit under the top plate"],
          'no plies' => [["8'", 'W1', 'Window'], ['36', '48', '82 1/2', '2x8', '--'], 'plies'],
          'no header picked' => [["8'", 'W1', 'Window'], ['36', '48', '82 1/2', Framing::HDR_PICK, '3'], "don't assume"],
          'centerline off the wall' => [["30'", 'W1', 'Window'], nil, 'centerline'] }
  bad.each do |k, (a1, a2, want)|
    answers = [a1, a2, nil, nil].compact
    answers = [a1, nil] if a2.nil?
    seq = a2 ? [a1, a2, nil, nil] : [a1, nil]
    UI.answers[:inputbox] = ->(*_) { seq.shift }
    m = UI.messages.size
    T.opening_popup(s, 120.0)
    msgs = UI.messages[m..].join(' | ')
    msgs.include?(want) ? ok("opening check: #{k}") : finding("opening pop-up didn't catch: #{k} (#{msgs[0, 120]})")
  end
  Builder.params_of(s)['openings'].empty? ? ok('nothing laid out after the mistakes') : finding("opening saved despite errors: #{Builder.params_of(s)['openings'].map { |o| o['mark'] }}")
end

kase('duplicate mark on another wall') do
  UI.answers[:inputbox] = ->(*_) { nil }
  answers = [["5'", 'W1', 'Window'], %w[36 48 82.5 2x8 3]]
  UI.answers[:inputbox] = ->(*_) { answers.shift }
  T.opening_popup(s, 60.0)
  answers = [["4'", 'W1', 'Window'], nil]
  m = UI.messages.size
  T.opening_popup(id.('W-103'), 48.0)
  UI.messages[m..].any? { |x| x.include?('already used') } ? ok('duplicate mark caught') : finding('duplicate mark across walls not caught')
end

kase('door right where a partition tees in') do
  # W-105 tees into W-101 at x 100..103.5 (from the start). A door centered there:
  answers = [["11' 10\"", 'D9', 'Door'], ['30', '82 1/2', '2x10', '3'], nil, nil]
  UI.answers[:inputbox] = ->(*_) { answers.shift }
  m = UI.messages.size
  T.opening_popup(id.('W-103'), 142.0) # W-105 tees into the north wall at 140 - 143-1/2
  q = Builder.params_of(id.('W-103'))
  tee = (q['tee_need'] || []).first
  if q['openings'].any? { |o| o['mark'] == 'D9' }
    finding("a door can be laid out right where a partition tees in (tee at #{tee && tee['a0']}..#{tee && tee['a1']} on W-103) - no warning")
  else
    ok("door over the tee refused: #{UI.messages[m..].last.to_s[0, 90]}")
  end
end

kase('window right next to an L-corner post') do
  w4 = id.('W-103') # a through wall: the butt walls land on its ends -> L posts
  q = Builder.params_of(w4)
  need = q['corner_need'] || {}
  end_l = need.find { |_k, v| v['type'] == 'L' }
  if end_l
    x = end_l[0] == 'start' ? 26.5 : q['length'].to_f - 26.5
    answers = [[Framing.fmt_len(Framing.layout_dist(q, x)), 'W7', 'Window'], %w[36 48 82.5 2x8 3], nil, nil]
    UI.answers[:inputbox] = ->(*_) { answers.shift }
    m = UI.messages.size
    T.opening_popup(w4, x)
    o = Builder.params_of(w4)['openings'].find { |op| op['mark'] == 'W7' }
    if o
      king = end_l[0] == 'start' ? o['x'] - 3.0 : o['x'] + o['width'] + 1.5
      post = end_l[0] == 'start' ? [1.5, 7.0] : [q['length'].to_f - 7.0, q['length'].to_f - 1.5]
      overlap = king < post[1] && king + 1.5 > post[0]
      overlap ? finding("W7's king stud lands on the L-corner post (king #{king}, post #{post})") : ok('window near the L corner clears the post')
      Builder.params_of(w4).then { |qq| qq['openings'] = qq['openings'].reject { |op| op['mark'] == 'W7' }; Builder.set_params(w4, qq) }
    else
      ok("window over the L post refused: #{UI.messages[m..].join[0, 100]}")
    end
  else
    ok('no L corner on W-102 to test')
  end
end

kase('opening wider than 6 ft (2 jacks)') do
  w3 = id.('W-101')
  answers = [["14' 7\"", 'W4', 'Window'], ['96', '48', '82 1/2', '2x12', '3'], nil]
  UI.answers[:inputbox] = ->(*_) { answers.shift }
  T.opening_popup(w3, 175.0)
  q = Builder.params_of(w3)
  jacks = Builder.work_slots(q).count { |x| x.opening == 'W4' && x.expected['role'] == 'Jack Stud' }
  jacks == 4 ? ok('8 ft window gets 2 jacks each side') : finding("8 ft window jacks: #{jacks} (#{UI.messages.last(2).join(' | ')[0, 160]})")
end

kase('RFI form cancelled, then reopened from the opening') do
  w2 = id.('W-102')
  answers = [["5'", 'W8', 'Window'], ['36', '48', '82 1/2', Framing::HDR_RFI, '--'], nil]
  UI.answers[:inputbox] = ->(*_) { answers.shift }
  T.opening_popup(w2, 60.0)
  d = UI::HtmlDialog.all.last
  d.fire('ready'); d.fire('cancel')
  q = Builder.params_of(w2)
  op = q['openings'].find { |o| o['mark'] == 'W8' }
  if op && op['header'] == Framing::RFI && !op['rfi']
    ok('cancelled RFI: opening on hold, not sent')
    n = UI::HtmlDialog.all.size
    Builder.set_flag(w2, 'openings_done', true)
    k = Builder.work_slots(Builder.params_of(w2)).find { |x| x.opening == 'W8' }
    cslot.(w2, k)
    UI::HtmlDialog.all.size > n ? ok('clicking the held opening reopens the RFI form') : finding("clicking a held opening with no RFI sent didn't reopen the form (#{Sketchup.status_text})")
  else
    finding("cancelled RFI state: #{op.inspect}")
  end
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
  # frame the opening unit quickly
  UI.answers[:inputbox] = lambda do |_pr, _v, _l, title|
    sl = Builder.work_slots(Builder.params_of(w3)).find { |x| title.start_with?("#{x.label} -") }
    next nil unless sl
    sl.expected['role'] == 'Header' ? [Framing.fmt_len(sl.expected['length'])] : [sl.expected['size'], Framing.fmt_len(sl.expected['length'])]
  end
  30.times do
    q = Builder.params_of(w3)
    break unless Builder.stage(q) == 'units'
    n = Builder.next_slots(q).first or break
    cslot.(w3, n)
  end
  UI.answers[:inputbox] = ->(pr, *_) { pr[0].include?('Corner') ? [GuidedTool::CORNERS['single']] : ['16'] }
  click(w3, 4, 50); click(w3, Builder.params_of(w3)['length'] - 4, 50)
  n0 = (Builder.params_of(w3)['marks'] || []).size
  Builder.set_layout_from(w3, true)
  q = Builder.params_of(w3)
  q['oc'].nil? && (q['marks'] || []).empty? ? ok("layout end switch pulled #{n0} studs to redo") : finding('layout end switch left studs in place')
  Builder.stage(q) == 'commons' ? ok('back to the stud step') : finding("after layout switch stage = #{Builder.stage(q)}")
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
  T.getMenu(Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([]), 0, 0, 0, V)
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

kase('instructor answers an RFI by hand with a bad size') do
  r = Project.answer_rfi_manual(99, '2x99', 2, 'x')
  r.empty? ? ok('bad manual answer ignored') : finding('manual RFI answer accepted a bad size')
end

kase('grade a model with no walls in the key') do
  res = AnswerKey.compare({ 'walls' => [] }, DMACC::WallFramer.student_snapshot)
  DMACC::WallFramer.report_html(res, { 'model' => 'x', 'created' => 'y' })
  ok('empty key grades without crashing')
end

File.write('/tmp/stress_edges.json', JSON.generate($findings))
puts($findings.empty? ? 'ALL PASSED' : "#{$findings.size} FINDINGS")
