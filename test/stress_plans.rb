# Stress test: a simulated student frames a small house start to finish through the
# real tool clicks and pop-ups, then inspection + interlock + answer key must all pass.
#   ruby -Itest/stubs test/stress_plans.rb A    (plans A-E)
# Every snag a student could hit is logged as a FINDING instead of stopping the run.
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
$findings = []
def finding(msg) = ($findings << msg; puts "FINDING #{msg}")
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)

# ---------------- the five plans ----------------
# ext: outside-face corners, counterclockwise; runs: through/butt per wall in draw order
# openings: wall index => [[mark, type, center_from_wall_start, ro_w, ro_h, head, header, plies]]
# ints: [[x1,y1,x2,y2,type,[openings]]]
PLANS = {
  'A' => { name: "16x12 bunkhouse", ext: [[0, 0], [192, 0], [192, 144], [0, 144]], runs: %w[through butt through butt],
           openings: { 0 => [['W1', 'Window', 96, 36, 48, 82.5, '2x8', 3]], 2 => [['D1', 'Door', 60, 38, 82.5, nil, '2x10', 3]] } },
  'B' => { name: "24x16 with a closet partition (splices)", ext: [[0, 0], [288, 0], [288, 192], [0, 192]], runs: %w[through butt through butt],
           openings: { 0 => [['W1', 'Window', 72, 36, 48, 82.5, '2x8', 3], ['D1', 'Door', 200, 38, 82.5, nil, '2x10', 3]],
                       2 => [['W2', 'Window', 72, 48, 48, 82.5, '2x10', 3]] },
           ints: [[150.0, 5.5, 150.0, 186.5, 'INT 2x4', [['D2', 'Door', 120, 32, 82.5, nil, :flat, nil]]]] },
  'C' => { name: "L-shaped 28x24", ext: [[0, 0], [336, 0], [336, 144], [192, 144], [192, 288], [0, 288]],
           runs: %w[through butt through butt through butt],
           openings: { 0 => [['W1', 'Window', 40, 36, 48, 82.5, '2x8', 3], ['W2', 'Window', 290, 36, 48, 82.5, '2x8', 3]],
                       3 => [['D1', 'Door', 72, 38, 82.5, nil, '2x10', 3]], 5 => [['W3', 'Window', 144, 72, 48, 82.5, '2x12', 3]] } },
  'D' => { name: "20x30, 24\" O.C., layout from the far end, two tees", ext: [[0, 0], [240, 0], [240, 360], [0, 360]],
           runs: %w[butt through butt through], type: 'EXT 2x6 24', layout_end: [2],
           openings: { 1 => [['W1', 'Window', 60, 36, 60, 82.5, '2x10', 3]], 2 => [['D1', 'Door', 60, 38, 82.5, nil, '2x10', 3]],
                       3 => [['W2', 'Window', 300, 36, 48, 82.5, '2x8', 3]] },
           ints: [[5.5, 120.0, 234.5, 120.0, 'INT 2x4', [['D2', 'Door', 60, 32, 82.5, nil, :flat, nil]]],
                  [5.5, 240.0, 234.5, 240.0, 'INT 2x4', []]] },
  'E' => { name: "2-story 24x20 with header RFIs", ext: [[0, 0], [288, 0], [288, 240], [0, 240]], runs: %w[through butt through butt],
           openings: { 0 => [['W1', 'Window', 96, 36, 48, 82.5, :rfi, nil]], 2 => [['D1', 'Door', 144, 38, 82.5, nil, '2x10', 3]] },
           upper: { openings: { 0 => [['W5', 'Window', 96, 36, 48, 82.5, :rfi, nil]], 2 => [['W6', 'Window', 144, 36, 48, 82.5, '2x8', 3]] } } },
  'F' => { name: "16x12 drawn clockwise (body outside?)", ext: [[0, 0], [0, 144], [192, 144], [192, 0]], runs: %w[through butt through butt],
           openings: { 1 => [['W1', 'Window', 96, 36, 48, 82.5, '2x8', 3]] } },
  'G' => { name: "bay with a 45-degree corner", ext: [[0, 0], [240, 0], [240, 96], [192, 144], [0, 144]], runs: %w[through butt through butt through],
           openings: { 0 => [['W1', 'Window', 120, 36, 48, 82.5, '2x8', 3]] } }
}.freeze
KEY = ARGV[0] || 'A'
PLAN = PLANS.fetch(KEY)
puts "=== Plan #{KEY}: #{PLAN[:name]} ==="

Project.update do |d|
  d['wall_types'] << { 'name' => 'EXT 2x6 24', 'stud' => '2x6', 'spacing' => 24.0, 'height' => 97.125, 'top_plates' => 2,
                       'function' => 'Exterior', 'bearing' => true }
  d['levels'] << { 'name' => 'Level 2', 'elev' => 109.0 } if PLAN[:upper]
  d['settings']['rfi_delay_min'] = 1
end
sfpa = '/home/claude/sfpa/WallFramer_SFPA_headers.json'
Project.import_sfpa(File.exist?(sfpa) ? sfpa : File.join(__dir__, 'fixtures', 'sfpa_fake.json'))

# ---------------- draw it ----------------
def draw_level(level, pts, type)
  t = DrawWallTool.new(level, type)
  t.activate
  t.onLButtonDown(0, pts[0][0], pts[0][1], V)
  pts.each_with_index do |a, i|
    b = pts[(i + 1) % pts.size]
    len = Math.hypot(b[0] - a[0], b[1] - a[1])
    dx = (b[0] - a[0]) / len
    dy = (b[1] - a[1]) / len
    t.onMouseMove(0, a[0] + dx * 30, a[1] + dy * 30, V)
    t.onUserText(Framing.fmt_len(len), V)
  end
  Builder.all_walls.select { |w| Builder.params_of(w)['level'] == level }.sort_by { |w| Builder.params_of(w)['id'] }
end

levels = [['Level 1', PLAN[:openings]]]
levels << ['Level 2', PLAN[:upper][:openings]] if PLAN[:upper]
WALL_OPS = {}
levels.each do |lv, ops|
  ext = draw_level(lv, PLAN[:ext], PLAN[:type] || 'EXT 2x6')
  finding("#{lv}: drew #{ext.size} walls for #{PLAN[:ext].size} sides") if ext.size != PLAN[:ext].size
  ext.each_with_index do |w, i|
    Builder.set_run(w, PLAN[:runs][i])
    WALL_OPS[Builder.params_of(w)['id']] = (ops[i] || []).map(&:dup)
    Builder.set_layout_from(w, true) if (PLAN[:layout_end] || []).include?(i)
  end
  next unless lv == 'Level 1'
  (PLAN[:ints] || []).each do |x1, y1, x2, y2, type, iops|
    w = Builder.create_wall(Geom::Point3d.new(x1, y1, 0), Geom::Point3d.new(x2, y2, 0), lv, type)
    WALL_OPS[Builder.params_of(w)['id']] = iops.map(&:dup)
  end
  Builder.resolve_layout(lv)
end
Builder.refresh_corner_needs
walls = Builder.all_walls.sort_by { |w| Builder.params_of(w)['id'] }
puts '   ' + walls.map { |w| p = Builder.params_of(w); "#{p['id']}(#{p['run'] || '-'}) #{Framing.fmt_len(p['length'])}" }.join(', ')
walls.each do |w|
  p = Builder.params_of(w)
  oc = Builder.open_corners(p)
  finding("#{p['id']}: corners still open after setting runs: #{oc}") unless oc.empty?
end

# ---------------- the student ----------------
class Student
  attr_accessor :g, :ops, :dtp_ctx, :popups
  def initialize = (@popups = [])

  def p = Builder.params_of(@g)

  def answer(prompts, vals, _lists, title)
    @popups << title
    if @popups.last(6).uniq.size == 1 && @popups.size >= 6
      finding("the same pop-up came back 6 times: #{title} - #{UI.messages.last.to_s.tr("\n", ' ')[0, 160]}")
      @popups << '-'
      return nil
    end
    q = p
    case title
    when /\ALay out an opening/
      o = @cur = @ops.shift
      raise "no opening queued for #{title}" unless o
      [Framing.fmt_len(Framing.layout_dist(q, o[2])), o[0], o[1]]
    when /\) - Lay out an opening/, /\) - Edit /
      o = @cur
      hdr = case o[6] when :rfi then Framing::HDR_RFI when :flat then Framing::HDR_FLAT else o[6] end
      plies = o[7] ? o[7].to_s : '--'
      if title.include?(') - Edit ') # updating after the RFI answer
        ans = Project.data['rfis'].find { |r| r['mark'] == o[0] }['answer']
        m = ans.match(/\((\d)\) (2x\d+)/)
        hdr = m ? m[2] : Framing::HDR_FLAT
        plies = m ? m[1] : '--'
      end
      base = o[1] == 'Window' ? [o[3], o[4], o[5]] : [o[3], o[4]]
      base.map { |v| Framing.fmt_len(v.to_f) } + [hdr, plies]
    when /\AEdit /
      vals
    when /\ACorner - /
      end_name = prompts[0].include?('start') ? 'start' : 'end'
      need = (q['corner_need'] || {})[end_name]
      [GuidedTool::CORNERS[need && need['type'] == 'L' ? 'L' : 'single']]
    when /\AStud layout - /
      sp = q['spacing'].to_f
      [sp == sp.round ? sp.round.to_s : sp.to_s]
    when /\APartition backing/
      [GuidedTool::BACKING['ladder']]
    when /\ASplice the double plate/
      [Framing.fmt_len(dtp_cut)]
    else
      s = Builder.work_slots(q).find { |sl| title.start_with?("#{sl.label} -") }
      raise "unknown pop-up: #{title} | #{prompts.join(' / ')}" unless s
      x = s.expected
      return [Framing.fmt_len(x['length'])] if x['role'] == 'Header'
      if Framing.plate?(s)
        e = q['entries'] && q['entries'][s.id]
        left = q['length'].to_f - (e ? e['pieces'].sum { |pc| pc['length'].to_f } : 0)
        return [x['size'], Framing.fmt_len([left, Framing::STOCK_MAX].min)]
      end
      [x['size'], Framing.fmt_len(x['length'])]
    end
  end

  # A splice that passes: longest first piece (from the arrow end) the engine accepts.
  def dtp_cut
    g, lx = @dtp_ctx
    sp = Builder.dtp_preview(g, lx)
    len = sp['b'] - sp['a']
    c = Framing::STOCK_MAX
    while c > 1
      rest = len - c
      return c if rest <= Framing::STOCK_MAX && rest.positive? && Builder.dtp_splice_problem(g, sp, [c, rest]).nil?
      c -= 0.25
    end
    finding("#{Builder.params_of(g)['id']}: no splice works for a #{Framing.fmt_len(len)} double plate run")
    Framing::STOCK_MAX
  end

  def message(m)
    UI.messages << m
    return(@ops.empty? ? IDNO : IDYES) if m.include?('Another opening')
    return(@ops.empty? ? IDNO : IDYES) if m.include?('have any openings')
    IDYES
  end
end

require_relative 'cut_student'
S = Student.new
UI.answers[:inputbox] = ->(*a) { S.answer(*a) }
UI.answers[:msg] = ->(m) { S.message(m) }
Dialogs.open_yard; YD = UI::HtmlDialog.all.last; YD.fire('ready')
Dialogs.activate_tool
TOOL = Dialogs.tool
TOOL.activate

def face(g, x, z)
  V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)]
end

def state_of(g)
  p = Builder.params_of(g)
  JSON.generate([p['entries'], p['openings'], p['oc'], p['openings_done'], p['corners']])
end

def click(g, x, z)
  face(g, x, z)
  TOOL.onMouseMove(0, 0, 0, V)
  TOOL.onLButtonDown(0, 0, 0, V)
end

def click_slot(g, s)
  x0, z0, x1, z1 = Framing.slot_box(s)
  before = state_of(g)
  click(g, (x0 + x1) / 2.0, (z0 + z1) / 2.0)
  return true if state_of(g) != before
  hit = TOOL.instance_variable_get(:@target)
  got = hit ? hit[1].label : (TOOL.instance_variable_get(:@corner) ? 'a corner' : (TOOL.instance_variable_get(:@mark) ? 'the plate/tape' : 'nothing'))
  finding("#{Builder.params_of(g)['id']}: clicking the middle of '#{s.label}' hit #{got} (status: #{Sketchup.status_text})")
  false
end

def frame_wall(g)
  S.g = g
  id = Builder.params_of(g)['id']
  S.ops = WALL_OPS[id] || []
  # first click: the wall goes to the framing table, lying flat
  home0 = Builder.wall_shape(g)
  click(g, 30, 50)
  if Project.settings['framing_table']
    unless Builder.on_table?(g)
      finding("#{id}: first click didn't take it to the framing table")
    else
      t = g.transformation
      finding("#{id}: on the table but not lying flat (z axis #{t.zaxis.to_a})") unless t.zaxis.z.abs < 1e-6 && t.yaxis.z < -0.99
      finding("#{id}: its plan position changed when it went to the table") unless Builder.wall_shape(g) == home0
      others = Builder.table_walls - [g]
      finding("#{id}: another wall is still on the table: #{others.map { |w| Builder.params_of(w)['id'] }}") unless others.empty?
    end
  end
  fd = CutStudent.frame_dialog
  finding("#{id}: the Frame Wall form didn't open on the first click") unless fd&.visible?
  12.times do
    p = Builder.params_of(g)
    st = Builder.stage(p)
    case st
    when 'framed'
      if Builder.on_table?(g)
        fd = CutStudent.frame_dialog
        fd.fire('stand_up')
      end
      t = g.transformation
      h = Builder.home(g)
      ok = (t.origin.x - h.origin.x).abs < 1e-6 && (t.origin.y - h.origin.y).abs < 1e-6 && t.zaxis.z > 0.99
      finding("#{id}: stood up but not on its line") unless ok
      return true
    when 'corners'
      finding("#{id}: stuck at corners")
      return false
    when 'openings'
      fd = CutStudent.frame_dialog
      unless fd
        finding("#{id}: no Openings form at the openings step")
        return false
      end
      fd.fire('ready')
      rows = S.ops.map do |o|
        hdr = case o[6] when :rfi then Framing::HDR_RFI when :flat then Framing::HDR_FLAT else o[6] end
        { 'mark' => o[0], 'type' => o[1], 'x_text' => Framing.fmt_len(Framing.layout_dist(p, o[2])),
          'width_text' => Framing.fmt_len(o[3].to_f), 'height_text' => Framing.fmt_len(o[4].to_f),
          'sill_text' => o[1] == 'Window' ? Framing.fmt_len(o[5].to_f) : '', 'header' => hdr, 'plies' => o[7] ? o[7].to_s : '--' }
      end
      fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => rows })
      errs = fd.last('openingErrors') || []
      unless errs.empty?
        finding("#{id}: Openings form refused: #{errs.first(2)}")
        return false
      end
      rfis = S.ops.select { |o| o[6] == :rfi }
      S.ops = []
      # rows for the other openings go in while the RFI is out (any order)
      CutStudent.fill(g)
      rfis.each { |o| rfi_flow(g, o) }
    else
      CutStudent.fill(g, order: [:reverse, :forward].sample)
      p = Builder.params_of(g)
      if Builder.stage(p) == st && st != 'framed'
        stuck = CutList.rows(p).reject { |r| %w[placed none].include?(r['state']) }
        finding("#{id}: stuck at #{st} with the cut list filled: #{stuck.map { |r| "#{r['label']} [#{r['state']}] #{r['note']}" }.first(3)}")
        return false
      end
    end
  end
  finding("#{id}: didn't finish (stage #{Builder.stage(Builder.params_of(g))})")
  false
end

# Header not on the plans: RFI form -> wait -> answer -> student updates the opening
def rfi_flow(g, o)
  id = Builder.params_of(g)['id']
  Dialogs.open_rfi(id, o[0]) unless (Builder.params_of(g)['openings'].find { |x| x['mark'] == o[0] } || {})['rfi']
  d = UI::HtmlDialog.all.last
  if d.instance_variable_get(:@cbs)&.key?('submit')
    d.fire('ready')
    d.fire('submit', { 'question' => "Checked the plans and general notes - no header called out for #{o[0]}. What size?" })
  else
    finding("#{id}: RFI form didn't open for #{o[0]}")
    return
  end
  op = Builder.params_of(g)['openings'].find { |x| x['mark'] == o[0] }
  finding("#{id}: #{o[0]} has no RFI number after submitting") unless op && op['rfi']
  Project.update { |dd| dd['rfis'].each { |r| r['at'] -= 120 unless r['answer'] } }
  done = Project.release_rfis
  Dialogs.notify_rfis(done)
  r = done.find { |x| x['mark'] == o[0] }
  unless r
    finding("#{id}: RFI for #{o[0]} didn't answer itself (#{Project.rfi_stuck_reason(Project.data['rfis'].find { |x| x['mark'] == o[0] })})")
    return
  end
  puts "   RFI #{o[0]}: #{r['answer']}"
  S.instance_variable_set(:@cur, o)
  ws = Builder.work_slots(Builder.params_of(g))
  k = ws.find { |x| x.opening == o[0] }
  x0, z0, x1, z1 = Framing.slot_box(k)
  click(g, (x0 + x1) / 2, (z0 + z1) / 2) # click the opening -> read the answer -> the Openings form
  fd = UI::HtmlDialog.all.reverse.find { |dd| dd.instance_variable_get(:@cbs)&.key?('save_openings') }
  fd.fire('ready')
  rows = fd.last('load')['openings']
  m = r['answer'].match(/\((\d)\) (2x\d+)/)
  rows = rows.map { |row| row['mark'] == o[0] ? row.merge('header' => m ? m[2] : Framing::HDR_FLAT, 'plies' => m ? m[1] : '--') : row }
  fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => rows })
  finding("#{id}: updating #{o[0]} from the RFI answer was refused: #{fd.last('openingErrors')}") unless (fd.last('openingErrors') || []).empty?
  op = Builder.params_of(g)['openings'].find { |x| x['mark'] == o[0] }
  finding("#{id}: #{o[0]} still on hold after reading the RFI answer and updating") if op['header'] == Framing::RFI
end

ok = walls.map { |w| frame_wall(w) }
puts "   framed #{ok.count(true)} of #{walls.size} walls; pop-ups: #{S.popups.size}"

# ---------------- double top plates ----------------
TOOL.set_mode(:dtp)
def top(g, x)
  p = Builder.params_of(g)
  V.ray = [Geom::Point3d.new(x, Framing.depth(p) / 2.0, 600).transform(g.transformation), Geom::Vector3d.new(0, 0, -1)]
end
Builder.all_walls.map { |w| Builder.params_of(w)['level'] }.uniq.each do |lv|
  bl = Builder.dtp_blockers(lv)
  unless bl.empty?
    finding("#{lv}: double plates blocked: #{bl}")
    next
  end
  lw = Builder.level_walls(lv)
  # correct order: walls that butt (interior tees, butt corners) before the walls they butt into
  order = lw.sort_by { |w| q = Builder.params_of(w); [q['function'] == 'Interior' ? 0 : (q['run'] == 'butt' ? 1 : 2), q['id']] }
  order.each do |w|
    20.times do
      free = Builder.dtp_free(w)
      break if free.empty?
      a, b = free.first
      x = (a + b) / 2.0
      S.dtp_ctx = [w, x]
      top(w, x)
      TOOL.onMouseMove(0, 0, 0, V)
      n = Builder.dtp_free(w).size
      TOOL.onLButtonDown(0, 0, 0, V)
      if Builder.dtp_free(w).size >= n && Builder.dtp_free(w).first == free.first
        finding("#{Builder.params_of(w)['id']}: double plate click at #{Framing.fmt_len(x)} didn't place a piece (#{Sketchup.status_text})")
        break
      end
    end
  end
  checks = Builder.interlock(lv)
  bad = checks.reject { |c| c['ok'] }
  finding("#{lv}: interlock #{checks.size - bad.size}/#{checks.size}: #{bad.map { |c| c['text'] }.first(2)}") unless bad.empty?
end

# ---------------- inspection + grading ----------------
Builder.refresh_corner_needs
Builder.all_walls.each do |w|
  YD.fire('ready')
  Dialogs.focus_wall(Builder.params_of(w)['id'])
  YD.fire('inspect')
  q = Builder.params_of(w)
  r = Inspector.inspect_wall(q, q['entries'], level: 'fix', table: Project.header_table, student_layout: Project.settings['student_layout'])
  next if r['correct'] == r['total'] && r['issues'].empty?
  finding("#{q['id']} inspection: #{r['summary']} - #{r['issues'].map { |i| "#{i.label}: #{i.message}" }.first(3)}")
end
key = { 'format' => 'dmacc-wall-framer-key-1', 'walls' => Builder.all_walls.map { |w| Builder.snapshot_wall(w) } }
res = AnswerKey.compare(key, DMACC::WallFramer.student_snapshot)
html = DMACC::WallFramer.report_html(res, key.merge('model' => 'self', 'created' => 'now'))
pct = res['areas'] ? res['areas'].map { |a| a['pct'] || a['score'] } : res.keys
puts "   self-grade: #{res.reject { |k, _| %w[notes walls].include?(k) }.to_a.first(6)}"
finding('grade report failed to build') unless html.include?('Grade Report')
st = Yard.stats
puts "   yard: #{st}"
YD.fire('ready')
ld = YD.last('load')
puts "   job notes: #{ld['notes']['items'].size} items, plans: #{ld['notes']['plans'].size} openings"
File.write("/tmp/stress_#{KEY}.json", JSON.generate('findings' => $findings, 'popups' => S.popups.size))
puts($findings.empty? ? 'ALL PASSED' : "#{$findings.size} FINDINGS")
