# Cut list: the student fills rows in the Frame Wall form (any order); pieces go in live.
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
UI.answers[:inputbox] = ->(*a) { raise "pop-up asked: #{a.last}" }
UI.answers[:msg] = ->(*a) { raise "message box: #{a.first[0, 80]}" }

g = Builder.create_wall(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(240, 0, 0), 'Level 1', 'EXT 2x6') # 20' wall
Dialogs.open_yard
Dialogs.activate_tool; tool = Dialogs.tool; tool.activate
face = ->(x, z) { V.ray = [Geom::Point3d.new(x, -60, z).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)] }
click = ->(x, z) { face.(x, z); tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V) }

click.(60, 50)
fd = UI::HtmlDialog.all.find { |d| d.file.to_s.end_with?('frame.html') }
chk(fd, 'clicking the wall opens the Frame Wall form')
fd.fire('ready')
st = fd.last('load')
chk(st['cutlist'].map { |r| r['key'] }.first(2) == ['plate:BP', 'plate:TP:1'], 'cut list starts with the plates')
chk(st['stage'] == 'plates', "stage plates (#{st['stage']})")
row = ->(k) { fd.last('rowsUpdate')['rows'].find { |r| r['key'] == k } }
set = ->(k, v, size = nil) { fd.fire('set_row', { 'key' => k, 'v' => v, 'size' => size }) }
p = -> { Builder.params_of(g) }
ent = ->(id) { (p.call['entries'] || {})[id] }

# a 20' plate in one piece is refused (16' stock), a splice goes in
set.('plate:BP', "20'")
chk(fd.last('rowsUpdate')['err'].to_s.include?("16'"), 'one 20\' piece: told the stock is 16\' and to splice')
chk(!ent.('BP'), 'nothing nailed for an unreadable/too-long plate')
set.('plate:BP', "16', 4'", '2x6')
chk(ent.('BP') && ent.('BP')['pieces'].size == 2 && ent.('BP')['full'] != false, 'spliced bottom plate goes in, both pieces')
chk(row.('plate:BP')['state'] == 'placed', "row says placed (#{row.('plate:BP')['note']})")
set.('plate:TP:1', "12'", '2x6')
chk(row.('plate:TP:1')['state'] == 'short', "short top plate: row says how much is left (#{row.('plate:TP:1')['note']})")
set.('plate:TP:1', "12', 8'", '2x6')
chk(ent.('TP:1') && ent.('TP:1')['full'] != false, 'changing the row replaces the plate')
chk(fd.last('rowsUpdate')['stage'] == 'openings', 'plates in -> openings next')

# openings from tab 1; the form stays open and moves to the cut list
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [
  { 'mark' => 'W1', 'type' => 'Window', 'x_text' => "4'", 'width_text' => '36', 'height_text' => '48', 'sill_text' => '82 1/2', 'header' => '2x8', 'plies' => '2' },
  { 'mark' => 'D1', 'type' => 'Door', 'x_text' => "12'", 'width_text' => '38', 'height_text' => '82 1/2', 'sill_text' => '', 'header' => '2x10', 'plies' => '2' }] })
chk(fd.visible?, 'the form stays open after saving the openings')
st = fd.last('load')
keys = st['cutlist'].map { |r| r['key'] }
chk(%w[king:W1 jack:W1 header:W1 sill:W1 under:W1 above:W1 king:D1 header:D1].all? { |k| keys.include?(k) }, 'a section for each opening')
chk(!keys.include?('sill:D1'), 'no sill row for a door')
exp = ->(role, mk) { Builder.work_slots(p.call).find { |s| s.expected['role'] == role && s.opening == mk }.expected }

# any order: the header first waits for the jacks
set.('header:W1', Framing.fmt_len(exp.('Header', 'W1')['length']))
chk(row.('header:W1')['state'] == 'waiting', "header before the jacks waits (#{row.('header:W1')['note']})")
set.('king:W1', Framing.fmt_len(exp.('King Stud', 'W1')['length']), '2x6')
set.('jack:W1', Framing.fmt_len(exp.('Jack Stud', 'W1')['length']), '2x6')
chk(row.('header:W1')['state'] == 'placed', 'jacks in -> the waiting header goes in by itself')
hdr = ent.('HDR:W1')
chk(hdr && hdr['pieces'].size == 2, 'header gets both plies from the plans')
set.('sill:W1', Framing.fmt_len(exp.('Rough Sill', 'W1')['length']), '2x6')
set.('under:W1', '30')
chk(row.('under:W1')['state'] == 'waiting', "cripples wait for the stud layout (#{row.('under:W1')['note']})")
%w[king jack].each { |k| set.("#{k}:D1", Framing.fmt_len(exp.(k == 'king' ? 'King Stud' : 'Jack Stud', 'D1')['length']), '2x6') }
set.('header:D1', Framing.fmt_len(exp.('Header', 'D1')['length']))
chk(fd.last('rowsUpdate')['stage'] == 'commons', "openings framed -> studs next (#{fd.last('rowsUpdate')['stage']})")

# studs: common length before the corners and spacing - waits
sl = Framing.stud_length(p.call)
set.('common', Framing.fmt_len(sl), '2x6')
chk(row.('common')['state'] == 'waiting', "commons wait for corners + spacing (#{row.('common')['note']})")
set.('corner:start', 'single')
set.('oc', '16')
chk(!p.call['oc'], 'spacing waits until both corners are picked')
set.('corner:end', 'single')
chk(p.call['oc'] == 16.0 && (p.call['marks'] || []).any?, 'both corners + spacing -> layout on the plates')
chk(row.('common')['state'] == 'placed', "commons nailed from the student's length (#{row.('common')['note']})")
chk(ent.('V:0.0:B1.5'), 'end stud in at the arrow end')
chk(row.('under:W1')['state'] != 'waiting' || row.('under:W1')['note'].include?('Sill'), "cripples under the sill go in now (#{row.('under:W1')['note']})")
blk = Builder.work_slots(p.call).find { |s| s.opening == 'W1' && s.anchor == :top && s.phase == 'cripples' }
set.('above:W1', Framing.fmt_len(blk.expected['length']), '2x6') if blk
dblk = Builder.work_slots(p.call).find { |s| s.opening == 'D1' && s.anchor == :top && s.phase == 'cripples' }
set.('above:D1', Framing.fmt_len(dblk.expected['length']), '2x6') if dblk
under = Builder.work_slots(p.call).find { |s| s.opening == 'W1' && s.anchor == :bottom && s.phase == 'cripples' }
set.('under:W1', Framing.fmt_len(under.expected['length']), '2x6')
chk(Builder.stage(p.call) == 'framed', "every row in -> framed (#{Builder.stage(p.call)})")
res = Inspector.inspect_wall(p.call, p.call['entries'], level: 'fix', table: Project.header_table)
res['issues'].reject! { |i| i.slot_id == 'TP:2' }
chk(res['issues'].empty?, "inspection passes (#{res['correct']}/#{res['total']}: #{res['issues'].map { |i| "#{i.label}: #{i.message}" }.first(3).join('; ')})")

# change the spacing -> layout redone, commons and cripples re-nailed from the rows
set.('oc', '24')
chk(p.call['oc'] == 24.0 && row.('common')['state'] == 'placed', 'new spacing: studs re-laid and re-nailed from the same rows')
chk(Builder.stage(p.call) == 'framed', "still framed after the change (#{Builder.stage(p.call)})")
set.('oc', '16')

# change a corner: the L-post comes out
set.('corner:start', 'L')
chk(ent.('LPOST:start'), 'corner changed to an L: the post goes in from the common row')
set.('corner:start', 'single')
chk(!ent.('LPOST:start'), 'and back to a single stud: the post came out')

# clicking a piece in the model opens its row
king = Builder.work_slots(p.call).find { |s| s.expected['role'] == 'King Stud' && s.opening == 'D1' }
x0, z0, x1, z1 = Framing.slot_box(king)
click.((x0 + x1) / 2, (z0 + z1) / 2)
chk(fd.last('load')['goto_row'] == 'king:D1', "clicking a king opens the cut list at its row (#{fd.last('load')['goto_row']})")

# a wrong row is caught by the inspector, logged; fix the row, it re-nails
set.('king:D1', '80', '2x6')
Dialogs.focus_wall(p.call['id'])
r = Dialogs.inspect_group(g)
chk((Project.data['catches'] || []).any? { |c| c['slot'].to_s.start_with?('V:') }, 'inspector catch logged for the short king')
set.('king:D1', Framing.fmt_len(king.expected['length']), '2x6')
res = Inspector.inspect_wall(p.call, p.call['entries'], level: 'fix', table: Project.header_table)
chk(res['issues'].reject { |i| i.slot_id == 'TP:2' }.empty?, 'fixed by changing the row')

# Demo tool pulls a piece -> its row empties
DemoTool.new
Builder.remove_piece(g, 'HDR:D1')
chk(!(p.call['cutlist'] || {})['header:D1'], 'pulling a piece empties its row so the table matches the wall')

# clearing a row pulls its pieces
set.('sill:W1', '')
chk(!ent.('SILL:W1'), 'emptying a row pulls its pieces')
chk(UI::HtmlDialog.all.none? { |d| d.file.to_s.end_with?('rfi.html') }, 'no RFI form without an RFI')

puts($f ? 'SOME FAILED' : 'ALL PASSED')
