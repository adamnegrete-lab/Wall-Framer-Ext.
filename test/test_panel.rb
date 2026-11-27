# v0.13: header tables remembered on this computer; Framing panel tabs + Job Notes; quiet RFI answers
require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
module Sketchup; class Group; def bounds = Geom::BoundingBox.new; end; end
Project.update { |d| d['settings']['framing_table'] = false } # walls stay standing in this test
fx = File.join(__dir__, 'fixtures', 'sfpa_fake.json')

# import once -> a copy stays on this computer -> a model without tables gets them back
Project.import_sfpa(fx)
chk(File.exist?(Project.local_sfpa_path), "copy saved on this computer: #{Project.local_sfpa_path.sub(ENV['WALLFRAMER_HOME'], '~')}")
Project.update { |d| d['sfpa'] = nil } # like a brand-new model
chk(Project.sfpa_tables && Project.data['sfpa'], 'new model picks up the tables without importing')

g = Builder.create_wall(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(192, 0, 0), 'Level 1', 'EXT 2x6')
Builder.create_wall(Geom::Point3d.new(192, 0, 0), Geom::Point3d.new(192, 144, 0), 'Level 1', 'EXT 2x6')
p = Builder.params_of(g)
p['openings'] = [{ 'mark' => 'W1', 'type' => 'Window', 'x' => 60.0, 'width' => 36.0, 'height' => 82.5, 'sill' => 34.5, 'header' => Framing::RFI }]
Builder.set_params(g, p)
n = Project.submit_rfi('W-101', 'W1', 'No header on the plans for W1 - what size?')
p = Builder.params_of(g); p['openings'][0]['rfi'] = n; Builder.set_params(g, p)

Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
st = yd.last('load')
chk(st['notes']['items'].any? { |i| i['kind'] == 'RFI' && i['title'].include?('waiting') }, 'Job Notes lists the open RFI')
chk(st['walls'].find { |w| w['id'] == 'W-101' }['held'] == ['W1'], 'Building tab shows W-101 on hold for W1')

# answer comes back -> no pop-up, badge + opening tag
Project.update { |d| d['rfis'][0]['at'] -= 120 }
msgs = UI.messages.size
Dialogs.notify_rfis(Project.release_rfis)
chk(UI.messages.size == msgs, 'no pop-up when the answer comes back')
chk(Sketchup.status_text.include?('Job Notes'), "status bar points to Job Notes: #{Sketchup.status_text}")
st = yd.last('load')
chk(st['notes']['unseen'] >= 1 && st['notes']['items'].first['title'].include?('answered'), "badge: #{st['notes']['unseen']} new, newest is the answer")
o = Builder.params_of(g)['openings'][0]
chk(o['rfi_new'] == n, 'opening tagged "RFI answered - click to read"')

# clicking the opening shows the answer once
Dialogs.activate_tool; tool = Dialogs.tool; tool.activate
edit_seen = []
UI.answers[:inputbox] = lambda do |pr, vals, _l, title|
  edit_seen << [title, vals]
  next vals if title.start_with?('Edit W1')                              # centerline / mark / type as entered
  next vals[0..-3] + ['2x6', '1'] if title.include?('Edit W1')           # header + plies from the answer
  nil
end
s = Builder.work_slots(Builder.params_of(g)).find { |x| x.opening == 'W1' && x.expected['role'] == 'King Stud' }
x0, z0, x1, z1 = Framing.slot_box(s)
V.ray = [Geom::Point3d.new((x0 + x1) / 2, -60, (z0 + z1) / 2).transform(g.transformation), Geom::Vector3d.new(0, 1, 0).transform(g.transformation)]
Builder.set_flag(g, 'openings_done', true)
p = Builder.params_of(g)
p['entries'] = Builder.work_slots(p).select { |x| x.phase == 'plates' }.to_h { |x| [x.id, x.expected.merge('pieces' => [{ 'size' => x.expected['size'], 'length' => x.expected['length'] }])] }
Builder.set_params(g, p)
tool.onMouseMove(0, 0, 0, V); tool.onLButtonDown(0, 0, 0, V)
chk(Sketchup.status_text.include?("RFI #1 is answered"), "click the opening -> told the answer is in: #{Sketchup.status_text[0, 60]}")
fd = UI::HtmlDialog.all.last
fd.fire('ready')
row = fd.last('load')['openings'].find { |r| r['mark'] == 'W1' }
chk(row && row['width_text'] == "3' 0\"" && row['sill_text'] == "6' 10-1/2\"" && row['header'] == Framing::HDR_PICK && row['rfi_note'].to_s.include?('answered'),
    "Openings form opens with what was entered, header left to fill in, answer shown: #{row && row['rfi_note']}")
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [row.merge('header' => '2x6', 'plies' => '1')] })
o = Builder.params_of(g)['openings'][0]
chk(o['header'] == '2x6' && o['plies'] == 1 && !o['rfi_new'] && Builder.gate_reason(Builder.params_of(g), s).nil?, 'student updated W1 from the answer - off hold')

# opening the Job Notes tab clears the badge
yd.fire('notes_seen')
chk(yd.last('load')['notes']['unseen'].zero?, 'badge clears when Job Notes is opened')
# instructor note
yd.fire('post_note', { 'text' => 'Window headers on the north wall come from sheet A3.' })
it = yd.last('load')['notes']['items'].first
chk(it['kind'] == 'Note' && it['unseen'], 'instructor job note posted and shows as new')
# inspection shows up in Job Notes
yd.fire('inspect')
chk(yd.last('load')['notes']['items'].any? { |i| i['kind'] == 'Inspection' && i['lines'][0].include?('W-101') }, 'inspection result saved to Job Notes')
# plan notes: the student's own entries, per opening
pl = yd.last('load')['notes']['plans']
chk(pl.size == 1 && pl[0]['text'].include?("W1 window (W-101) - RO 3' 0\" x 4' 0\", head height 6' 10-1/2\""), "plan notes: #{pl[0] && pl[0]['text']}")
# field notes: save, show, delete; in the grade report
yd.fire('add_my_note', { 'text' => 'Stud length 92-5/8 per wall section A5' })
mine = yd.last('load')['notes']['items'].find { |i| i['kind'] == 'My note' }
chk(mine && mine['lines'][0].include?('92-5/8') && !mine['unseen'], 'field note saved in Job Notes')
chk(DMACC::WallFramer.field_notes_html.include?('92-5/8'), 'field notes show up in the grade report')
yd.fire('delete_my_note', { 'i' => mine['mine'] })
chk(yd.last('load')['notes']['items'].none? { |i| i['kind'] == 'My note' }, 'field note deleted')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
