require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
g = Builder.create_wall(Geom::Point3d.new(0,0,0), Geom::Point3d.new(192,0,0), 'Level 1', 'EXT 2x6')
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
chk(yd.last('load')['guided'], 'panel in pop-up mode (saw/stock hidden)')
Dialogs.activate_tool; tool = Dialogs.instance_variable_get(:@tool); tool.activate
chk(tool.is_a?(GuidedTool), 'guided tool active')
face = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
down = ->(x) { V.ray = [Geom::Point3d.new(x, 2.75, 60).transform(g.transformation), Geom::Vector3d.new(0, 0, -1).transform(g.transformation)] }
popups = []
# the "student": reads the pop-up title, measures, answers correctly
UI.answers[:inputbox] = lambda do |prompts, vals, lists, title|
  popups << title
  if title.start_with?('Lay out an opening')
    @seen_cl ||= vals[0]
    @prompts1 ||= prompts
    @cur = @ops.shift; next [vals[0], @cur[1], @cur[2]]
  end
  if title.include?(') - Lay out an opening')
    @detail_prompts << prompts
    next @cur[2] == 'Window' ? @cur[3..6] + ['3'] : [@cur[3], @cur[4], @cur[6], '3']
  end
  if title.start_with?('Mark the kings')
    o = Builder.params_of(g)['openings'].find { |op| title.end_with?(op['mark']) }
    next [Framing.fmt_len(o['height'])]
  end
  next @studs.shift if title.start_with?('Corner') || title.start_with?('Stud layout')
  p = Builder.params_of(g)
  s = Builder.work_slots(p).find { |sl| title.start_with?(sl.label + ' -') }
  raise "no slot for #{title}" unless s
  x = s.expected
  @tips << prompts.join(' ') if x['role'] == 'Jack Stud'
  next [Framing.fmt_len(x['length'])] if x['role'] == 'Header' # size + plies come from the opening
  [x['size'], Framing.fmt_len(x['length'])]
end
@ops = [["4'", 'W1', 'Window', '36', '48', '82 1/2', '2x8'], ["11'", 'D1', 'Door', '38', '82 1/2', '', '2x10']]
@marks = %w[16 80 96 160 176]
@detail_prompts = []
@tips = []
UI.answers[:msg] = ->(m) { m.include?('Another opening') ? (@ops.empty? ? IDNO : IDYES) : IDYES }
click = ->(s) { x0, z0, x1, z1 = Framing.slot_box(s); face.((x0 + x1) / 2, (z0 + z1) / 2); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V) }
# try a king first (no openings yet -> nothing there), then plates
bp = Builder.work_slots(Builder.params_of(g)).find { |s| s.id == 'BP' }; click.(bp)
tp = Builder.work_slots(Builder.params_of(g)).find { |s| s.id == 'TP:1' }; click.(tp)
chk(Builder.stage(Builder.params_of(g)) == 'openings', 'plates set by pop-up -> openings stage')
chk(UI.messages.any? { |m| m.include?('find your opening centerlines') }, 'prompted to find opening centerlines')
# click centerlines on the plate
# pull the tape: type the plan dimension -> pencil mark, then click the mark -> opening pop-up
face.(10.0, 0.8); tool.onMouseMove(0,0,0,V)
chk(tool.instance_variable_get(:@mark), 'hovering the bottom plate face pulls the tape')
tool.onUserText("4'", V)
chk(Builder.params_of(g)['pencil'] == [48.0], 'typed reading -> pencil mark at 4\'')
face.(48.9, 0.8); tool.onMouseMove(0,0,0,V)
chk(tool.instance_variable_get(:@mark)[5] == 48.0, 'cursor near the mark snaps to it')
tool.onLButtonDown(0,0,0,V)
chk(@seen_cl == "4' 0\"", "opening pop-up prefilled with the mark: #{@seen_cl}")
# second opening: click to pencil (tape reading), then click the mark
face.(131.97, 0.8); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
face.(132.5, 0.8); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
p = Builder.params_of(g)
chk(p['openings'].map { |o| [o['mark'], o['x']] } == [['W1', 30.0], ['D1', 113.0]], "openings from centerline clicks: #{p['openings'].map { |o| [o['mark'], o['x']] }}")
chk(Builder.stage(p) == 'units', 'openings done -> units stage')
# build units: always click whatever is next (student follows the green marks)
n = 0
next_click = lambda do
  p = Builder.params_of(g)
  s = Builder.next_slots(p).first
  if (why = Builder.gate_reason(p, s)) && why.include?('Mark the header height')
    s = Builder.work_slots(p).find { |k| k.opening == s.opening && k.expected['role'] == 'King Stud' }
  end
  click.(s)
end
while Builder.stage(Builder.params_of(g)) == 'units' && n < 60
  next_click.call; n += 1
end
chk(@detail_prompts.size == 2 && @detail_prompts[0].size == 5 && @detail_prompts[1].size == 4 && @detail_prompts[0].last.include?('plies') &&
    @detail_prompts[1].none? { |pr| pr.start_with?('Head height') }, 'second pop-up fits the type: doors skip head height')
chk(@prompts1.size == 3, 'first opening pop-up: centerline, mark, type')
chk(Builder.params_of(g)['hdr_marks'] == { 'W1' => 82.5, 'D1' => 82.5 }, "header heights marked on the kings: #{Builder.params_of(g)['hdr_marks']}")
chk(@tips.any? { |t| t.include?("(header mark: 6' 10-1/2\")") }, "jack pop-up shows the student's header mark: #{@tips.first}")
chk(popups.none? { |t| t =~ /header/i && t.include?('Lumber') }, 'header pop-up never asks the size again')
chk(Builder.stage(Builder.params_of(g)) == 'commons', "opening units built with #{n} pop-ups")
chk(UI.messages.any? { |m| m.include?('choose its corner assembly') }, 'prompted for corner assemblies + spacing')
# commons: mark stud centers, then click each
@studs = [[GuidedTool::CORNERS['single']], [GuidedTool::CORNERS['single']], ['16']]
face.(5.0, 50.0); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
face.(187.0, 50.0); tool.onMouseMove(0,0,0,V); tool.onLButtonDown(0,0,0,V)
n2 = (Builder.params_of(g)['marks'] || []).size
chk(n2 == 5, "corners + 16\" O.C. -> #{n2} commons laid out and nailed")
p = Builder.params_of(g)
chk(Builder.stage(p) == 'cripples', "studs in -> cripples and header blocks next (#{n2} commons + end studs)")
chk(UI.messages.last.include?('cripples and header blocks'), 'told cripples come next, on the layout')
cr = Builder.work_slots(p).select { |sl| sl.phase == 'cripples' }
on16 = ->(sl) { ((sl.x + 0.75) % 16).abs < 0.01 }
oc_ok = cr.select { |sl| sl.label.include?('header block') }.all?(&on16) && cr.count(&on16) >= 6
chk(oc_ok, "cripples land on the 16\" layout: #{cr.map { |sl| [sl.label, sl.x + 0.75] }}")
n3 = 0
while Builder.stage(Builder.params_of(g)) == 'cripples' && n3 < 30
  next_click.call; n3 += 1
end
p = Builder.params_of(g)
chk(Builder.stage(p) == 'framed', "framed after #{n3} cripples / header blocks")
chk(UI.messages.last.include?('is framed'), 'told the wall is framed')
r = Inspector.inspect_wall(p, p['entries'], student_layout: true, table: Project.header_table)
chk(r['correct'] == r['total'] - 1, "inspection: #{r['summary']} (only the double plate is left)")
hdr = popups.find { |t| t.start_with?('W1 header') }; chk(hdr, "header pop-up asked: #{hdr}")
puts "   #{Yard.stats}"
chk(Yard.stats['boards_pulled'] < 30, 'offcuts reused automatically')
# a wrong length: pull a jack, re-enter wrong
jack = Builder.work_slots(p).find { |s| s.expected['role'] == 'Jack Stud' }
x0, z0, x1, z1 = Framing.slot_box(jack); face.((x0+x1)/2, (z0+z1)/2); tool.onMouseMove(0,0,0,V)
menu = Struct.new(:items) { def add_item(t, &b) = items << [t, b] }.new([]); tool.getMenu(menu); menu.items.first[1].call
UI.answers[:inputbox] = ->(*_) { ['2x6', '80'] }
tool.onLButtonDown(0,0,0,V)
p = Builder.params_of(g)
r = Inspector.inspect_wall(p, p['entries'], student_layout: true, table: Project.header_table)
chk(r['issues'].any? { |i| i.message.include?('too short') }, 'wrong jack length caught by inspection')
puts "   pop-ups: #{popups.size} (sample: #{popups.first(4).join(' | ')})"
puts($f ? 'SOME FAILED' : 'ALL PASSED')
# trade convention: window RO 36 x 48 with 82-1/2 head -> sill at 34-1/2
w1 = Builder.params_of(g)['openings'].find { |o| o['mark'] == 'W1' }
chk(w1['height'] == 82.5 && w1['sill'] == 34.5 && Framing.ro_height(w1) == 48.0, "W1 RO 36x48, head 82-1/2 -> sill #{w1['sill']}")
d1 = Builder.params_of(g)['openings'].find { |o| o['mark'] == 'D1' }
chk(d1['height'] == 82.5 && Framing.ro_height(d1) == 82.5, 'door RO height measured from the subfloor')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
