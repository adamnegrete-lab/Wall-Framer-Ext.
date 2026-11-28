# v0.13: header tables remembered on this computer; Framing panel Job Notes; old RFI headers
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

# an old model with an RFI'd header: the wall is held until the student picks a size
Dialogs.open_yard; yd = UI::HtmlDialog.all.last; yd.fire('ready')
Builder.set_flag(g, 'openings_done', true)
s = Builder.work_slots(Builder.params_of(g)).find { |x| x.opening == 'W1' && x.expected['role'] == 'King Stud' }
chk(Builder.gate_reason(Builder.params_of(g), s).to_s.include?("Pick W1's header size"), "held: #{Builder.gate_reason(Builder.params_of(g), s)}")
Dialogs.open_frame(g); fd = UI::HtmlDialog.all.last; fd.fire('ready')
row = fd.last('load')['openings'].find { |r| r['mark'] == 'W1' }
chk(row && row['width_text'] == "3' 0\"" && row['sill_text'] == "6' 10-1/2\"" && row['header'] == Framing::HDR_PICK,
    "Openings form opens with what was entered, header left to pick: #{row && row['header']}")
chk(fd.last('load')['header_tables'], 'header table offered in the form')
fd.fire('save_openings', { 'pos_mode' => 'center', 'openings' => [row.merge('header' => '2x6', 'plies' => '1')] })
o = Builder.params_of(g)['openings'][0]
chk(o['header'] == '2x6' && o['plies'] == 1 && !Builder.gate_reason(Builder.params_of(g), s).to_s.include?('header'), 'student picked the header - off hold')
yd.fire('ready')

# opening the Job Notes tab clears the badge
yd.fire('notes_seen')
chk(yd.last('load')['notes']['unseen'].zero?, 'badge clears when Job Notes is opened')
# instructor note
yd.fire('post_note', { 'text' => 'Window headers on the north wall come from sheet A3.' })
it = yd.last('load')['notes']['items'].first
chk(it['kind'] == 'Note' && it['unseen'], 'instructor job note posted and shows as new')
# inspection shows up in Job Notes
yd.fire('inspect')
chk(Sketchup.status_text.include?('Inspection opens'), 'inspection waits until the whole level is framed')
Dialogs.inspect_group(Builder.find_wall('W-101'))
yd.fire('ready')
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
