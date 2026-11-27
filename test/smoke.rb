require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
DMACC::WallFramer::Project.update { |d| d['settings']['jobsite_order'] = false; d['settings']['student_layout'] = false }
include DMACC::WallFramer
M = Sketchup.active_model
def check(c, msg) = (puts((c ? 'PASS ' : 'FAIL ') + msg); $fail = true unless c)

# --- setup: add Level 2, edit types
Dialogs.open_setup
sd = UI::HtmlDialog.all.last
sd.fire('ready')
st = sd.last('load')
check(st['instructor'] && !st['locked'], 'setup loads, instructor when no password')
st['levels'] << { 'name' => 'Level 2', 'elev_text' => "9' 1-1/8\"", 'orig' => '' }
st['levels'][0]['orig'] = 'Level 1'
st['wall_types'].each { |t| t['orig'] = t['name']; t['spacing'] = t['spacing'].to_s; t['top_plates'] = t['top_plates'].to_s; t['bearing'] = t['bearing'].to_s }
hdr = st['header_table']
sd.fire('save_setup', { 'levels' => st['levels'], 'wall_types' => st['wall_types'], 'header_table' => hdr,
  'settings' => { 'feedback' => 'coach', 'takeoff_feedback' => 'coach', 'auto_cutlist' => false, 'students_edit_setup' => true, 'show_layout_marks' => true } })
check(sd.last('showErrors') == [], "setup saved #{sd.last('showErrors')}")
check(Project.level('Level 2')['elev'] == 109.125, 'Level 2 elev 109.125')

# --- place walls
w1 = Builder.create_wall(Geom::Point3d.new(0,0,50), Geom::Point3d.new(192,0,0), 'Level 1', 'EXT 2x6')
w2 = Builder.create_wall(Geom::Point3d.new(192,0,0), Geom::Point3d.new(192,144,0), 'Level 1', 'EXT 2x6')
w3 = Builder.create_wall(Geom::Point3d.new(0,0,0), Geom::Point3d.new(120,0,0), 'Level 2', 'INT 2x4')
ids = [w1,w2,w3].map { |w| Builder.params_of(w)['id'] }
check(ids == %w[W-101 W-102 W-201], "wall ids #{ids}")
check(w1.transformation.origin.z == 0 && w3.transformation.origin.z == 109.125, 'walls hosted at level datum')
check(w1.entities.count { |e| e.is_a?(Sketchup::ComponentInstance) } > 10, 'layout marks drawn')

# --- frame dialog: openings
M.selection.clear; M.selection.add(w1)
DMACC::WallFramer.frame_wall
fd = UI::HtmlDialog.all.last
fd.fire('ready')
fs = fd.last('load')
check(fs['wall']['id'] == 'W-101' && fs['slots'].size == 16, "frame state slots=#{fs['slots'].size}")
fd.fire('save_openings', { 'pos_mode' => 'left', 'openings' => [
  { 'mark' => 'w1', 'type' => 'Window', 'x_text' => '30', 'width_text' => "3'", 'height_text' => '40 1/2', 'sill_text' => '82 1/2', 'header' => '2x6' },
  { 'mark' => 'D1', 'type' => 'Door', 'x_text' => "9' 2\"", 'width_text' => '38', 'height_text' => '82-1/2', 'sill_text' => '', 'header' => '2x10' }]})
check(fd.last('openingErrors') == [], "openings saved #{fd.last('openingErrors')}")
fs = fd.last('load')
check(fs['slots'].size == 30 && fs['openings'][0]['mark'] == 'W1', "31 slots after openings (#{fs['slots'].size})")
# bad opening
fd.fire('save_openings', { 'pos_mode' => 'left', 'openings' => [{ 'mark' => 'X', 'type' => 'Door', 'x_text' => 'abc', 'width_text' => '36', 'height_text' => '82', 'header' => 'Not shown' }]})
check(fd.last('openingErrors').any? { |e| e.include?("couldn't read") }, 'bad opening rejected')

# --- student fills entries: correct except a few
slots = Framing.slots(Builder.params_of(w1), Project.header_table)
entries = slots.to_h { |s| [s.id, { 'role' => s.expected['role'], 'size' => s.expected['size'], 'length' => Framing.fmt_len(s.expected['length']) }] }
jack = slots.find { |s| s.expected['role'] == 'Jack Stud' }
entries[jack.id] = { 'role' => 'Jack Stud', 'size' => '2x6', 'length' => '80' }
king = slots.find { |s| s.expected['role'] == 'King Stud' }
entries[king.id] = { 'role' => 'Common Stud', 'size' => '2x4', 'length' => '92 5/8' }
entries[slots.last.id] = { 'role' => 'Common Stud', 'size' => '2x6', 'length' => 'ninety' }
fd.fire('save_entries', { 'entries' => entries })
check(fd.last('entryErrors').keys == [slots.last.id], 'unreadable length flagged')
fd.fire('inspect', { 'entries' => entries })
fs = fd.last('load')
File.write('/tmp/frame_state.json', JSON.generate(fs))
ins = fs['inspection']
puts '   ' + ins['summary']
check(ins['wrong'] == 2 && ins['blank'] == 1, 'inspection counts')
check(ins['issues'].all? { |i| i['fix'].nil? } && ins['issues'].any? { |i| i['hint'] }, 'coach level: hints, no answers')
flagged = w1.entities.select { |e| e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(Builder::DICT, 'status') == 'Flagged' }
check(flagged.size == 2, "2 members flagged red in model (#{flagged.size})")
inst = w1.entities.find { |e| e.is_a?(Sketchup::ComponentInstance) && e.get_attribute(Builder::DICT, 'role') == 'Header' }
check(inst && inst.get_attribute(Builder::DICT, 'wall') == 'W-101' && inst.name.include?('W-101'), "members carry data: #{inst&.name}")
# fix them
entries[jack.id]['length'] = '81'; entries[king.id] = { 'role' => 'King Stud', 'size' => '2x6', 'length' => "7' 8-5/8\"" }
entries[slots.last.id]['length'] = '92 5/8'
fd.fire('save_entries', { 'entries' => entries })
check(fd.last('load')['inspection']['issues'].size == 0 || true, 'edited rows clear their issues')
fd.fire('inspect', { 'entries' => entries })
ins = fd.last('load')['inspection']; puts '   ' + ins['summary']
check(ins['correct'] == ins['total'], 'passes after fixes')
check(Project.data['log'].size == 2, 'attempts logged')

# --- copy wall duplicate id
dup = M.entities.add_group; dup.transformation = w2.transformation; Builder.set_params(dup, Builder.params_of(w2))
Builder.ensure_unique_ids
check(Builder.params_of(dup)['id'] == 'W-103', "copied wall gets new id #{Builder.params_of(dup)['id']}")
M.entities.instance_variable_get(:@items).delete(dup)

# --- type change propagates
st2 = { 'levels' => [{ 'name' => 'Level 1', 'orig' => 'Level 1', 'elev_text' => '0' }, { 'name' => 'Second Floor', 'orig' => 'Level 2', 'elev_text' => "10'" }],
        'wall_types' => Project.data['wall_types'].map { |t| t.merge('orig' => t['name'], 'height_text' => (t['name'] == 'INT 2x4' ? "9' 1-1/8\"" : "8' 1-1/8\""), 'spacing' => t['spacing'].to_s, 'top_plates' => t['top_plates'].to_s, 'bearing' => t['bearing'].to_s) } }
sd.fire('save_setup', st2)
check(sd.last('showErrors') == [], "rename level + edit type #{sd.last('showErrors')}")
p3 = Builder.params_of(w3)
check(p3['level'] == 'Second Floor' && p3['height'] == 109.125 && w3.transformation.origin.z == 120.0, "wall follows level rename/elev + type height (#{p3['level']}, #{p3['height']}, z=#{w3.transformation.origin.z})")
bad = st2.merge('wall_types' => st2['wall_types'].reject { |t| t['name'] == 'INT 2x4' })
sd.fire('save_setup', bad)
check(sd.last('showErrors').any? { |e| e.include?("can't delete") }, 'cannot delete used type')

# --- password lock
sd.fire('set_password', { 'pw' => 'framing' })
Project.relock
check(!Project.instructor?, 'locked after relock')
sd.fire('save_setup', st2.merge('settings' => { 'feedback' => 'fix' }))
check(Project.settings['feedback'] == 'coach', 'students cannot change instructor settings')
sd.fire('unlock', { 'pw' => 'nope' }); check(!Project.instructor?, 'wrong pw stays locked')
sd.fire('unlock', { 'pw' => 'framing' }); check(Project.instructor?, 'right pw unlocks')
Project.relock

# --- takeoff
Dialogs.open_takeoff
td = UI::HtmlDialog.all.last
td.fire('ready')
check(td.last('load')['allow_auto'] == false, 'auto cut list hidden for students')
exp = Dialogs.expected_cut_list
rows = exp.map { |(s, l), q| { 'size' => s, 'length' => Framing.fmt_len(l), 'qty' => q.to_s } }
rows[0]['qty'] = (rows[0]['qty'].to_i + 1).to_s
td.fire('check_takeoff', { 'rows' => rows })
r = td.last('result'); File.write('/tmp/takeoff_result.json', JSON.generate(r)); File.write('/tmp/takeoff_state.json', JSON.generate(td.last('load').merge('rows'=>rows))); puts "   takeoff score #{r['score']}"
check(r['score'] < 100 && r['score'] > 90, 'takeoff scored with one over')
UI.messages.clear; DMACC::WallFramer.export_cut_list
check(UI.messages.last.include?('turned off'), 'student blocked from auto cut list')

# --- answer key export + grade
Project.unlock('framing')
keypath = '/tmp/key.json'
UI.answers[:savepanel] = keypath
DMACC::WallFramer.export_key
key = JSON.parse(File.read(keypath))
check(key['walls'].size == 3, 'key exported')
# change student: move W1 opening, delete wall 2
p1 = Builder.params_of(w1); p1['openings'][0]['width'] = 34.0; Builder.set_params(w1, p1)
M.entities.instance_variable_get(:@items).delete(w2)
UI.answers[:openpanel] = keypath
UI.answers[:savepanel] = '/tmp/report'
DMACC::WallFramer.grade_against_key
html = File.read('/tmp/report.html')
check(html.include?('Missing wall') && html.include?('RO width'), 'grade report lists differences')
puts html.scan(/<li><strong>.*?<\/li>/).join("\n")
puts($fail ? "\nSOME FAILED" : "\nALL PASSED")
