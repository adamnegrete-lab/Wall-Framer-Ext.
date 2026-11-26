%w[framing inspector].each { |f| require_relative "../src/dmacc_wall_framer/#{f}" }
include DMACC::WallFramer
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
wall = {'id'=>'W-101','stud'=>'2x6','spacing'=>16.0,'height'=>97.125,'top_plates'=>2,'length'=>192.0,
  'openings'=>[{'mark'=>'W1','type'=>'Window','x'=>30.0,'width'=>36.0,'height'=>82.5,'sill'=>34.5,'header'=>'2x8'},
               {'mark'=>'D1','type'=>'Door','x'=>113.0,'width'=>38.0,'height'=>82.5,'header'=>'2x10'}]}
sl = Framing.slots(wall); by = sl.to_h { |s| [s.id, s] }
ent = {}
g = ->(id) { Inspector.gate(by[id], ent, by) }
fill = ->(id) { s = by[id]; ent[id] = s.expected.merge('pieces' => Array.new(s.plies || 1) { {'size'=>s.expected['size'],'length'=>s.expected['length']} }) }
k = sl.find { |s| s.label == 'W1 left king' }; j = sl.find { |s| s.label == 'W1 left jack' }
chk(g.(k.id)&.start_with?('Plates first'), "king before plates: #{g.(k.id)}")
fill.('BP'); fill.('TP:1')
chk(g.(k.id).nil?, 'king OK after plates')
chk(g.(j.id)&.include?('king first'), "jack before king: #{g.(j.id)}")
fill.(k.id); chk(g.(j.id).nil?, 'jack OK after king')
chk(g.('HDR:W1')&.include?('Both jacks'), g.('HDR:W1'))
sl.select { |s| s.opening == 'W1' && %w[King\ Stud Jack\ Stud].include?(s.expected['role']) }.each { |s| fill.(s.id) }
chk(g.('HDR:W1').nil?, 'header OK after both jacks')
chk(g.('SILL:W1')&.include?('header first'.capitalize) || g.('SILL:W1')&.include?('Set the header'), g.('SILL:W1'))
c = sl.find { |s| s.label.include?('under sill') }; chk(g.(c.id)&.include?('Sill first'), g.(c.id))
cm = sl.find(&:common); chk(g.(cm.id)&.include?('opening unit'), g.(cm.id))
chk(g.('TP:2')&.include?('last'), g.('TP:2'))
# bottom plate full length + door cutout drawn
bp = by['BP']; chk(bp.expected['length'] == 192.0, 'bottom plate cut full length')
chk(Framing.members_for_entry(wall, bp, bp.expected).size == 2, 'BP drawn in 2 pieces (door cut out)')
# student layout
wl = wall.merge('marks' => [15.25, 79.25, 100.0])  # 2 correct, 1 off layout
ws = Framing.work_slots(wl, Framing::DEFAULT_HEADER_TABLE, true)
chk(ws.count(&:common) == 3, "work slots include 3 student marks (#{ws.count(&:common)})")
chk(Framing.snap_mark(wall, 15.31) == 15.25 && Framing.snap_mark(wall, 20.0) == 20.0, 'marks snap to true layout within 1/8"')
full = sl.to_h { |s| [s.id, s.expected.dup] }
ws.select(&:common).each { |s| full[s.id] = s.expected.dup }
r = Inspector.inspect_wall(wl, full, level: 'fix', student_layout: true)
puts '   ' + r['summary']
off = r['issues'].find { |i| i['fields'] == ['layout'] && i['message'].start_with?('Off') } rescue nil
off = r['issues'].find { |i| i.fields == ['layout'] && i.message.start_with?('Off') }
chk(off && off.fix['length_text'].include?("7' 11-1/4"), "off-layout mark flagged with fix: #{off&.fix&.dig('length_text')}")
puts($f ? 'SOME FAILED' : 'ALL PASSED')
