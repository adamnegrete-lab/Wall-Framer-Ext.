%w[framing inspector takeoff answer_key].each { |f| require_relative "../src/dmacc_wall_framer/#{f}" }
include DMACC::WallFramer
wall = { 'id'=>'W-101','stud'=>'2x6','spacing'=>16.0,'height'=>97.125,'top_plates'=>2,'length'=>192.0,
  'openings'=>[
   {'mark'=>'W1','type'=>'Window','x'=>30.0,'width'=>36.0,'height'=>82.5,'sill'=>42.0,'header'=>'Not shown'},
   {'mark'=>'D1','type'=>'Door','x'=>110.0,'width'=>38.0,'height'=>82.5,'header'=>'2x10'}]}
p Framing.validate(wall)
slots = Framing.slots(wall)
puts slots.size
slots.each { |s| puts [s.id, s.label, s.expected['role'], s.expected['size'], Framing.fmt_len(s.expected['length'])].join(' | ') }
raise 'dup ids' if slots.map(&:id).uniq.size != slots.size
# perfect entries
entries = slots.to_h { |s| [s.id, s.expected.dup] }
r = Inspector.inspect_wall(wall, entries); puts r['summary']
# introduce errors
k = slots.find { |s| s.expected['role']=='Jack Stud' }
entries[k.id] = {'role'=>'Jack Stud','size'=>'2x6','length'=>80.0}
c = slots.find { |s| s.expected['role']=='King Stud' }
entries[c.id] = {'role'=>'Common Stud','size'=>'2x4','length'=>92.625}
entries.delete(slots.last.id)
%w[count locate coach fix].each { |lv| r = Inspector.inspect_wall(wall, entries, level: lv); puts "#{lv}: #{r['summary']}"; r['issues'].each { |i| p i.to_h } }
%w[92\ 5/8 92-5/8 7'\ 8-5/8" 7'8.625 92.625 abc].each { |s| p [s, Framing.parse_len(s)] }
exp = Framing.cut_list(Framing.expected_members(wall))
p exp
rows = [{'size'=>'2x6','length'=>'92 5/8','qty'=>9},{'size'=>'2x6','length'=>'16\'','qty'=>2},{'size'=>'2x4','length'=>'10','qty'=>1},{'size'=>'','length'=>'','qty'=>0}]
%w[coach fix].each { |lv| p Takeoff.check(rows, exp, level: lv) }
key = {'walls'=>[{'id'=>'W-101','level'=>'Level 1','type'=>'EXT 2x6','p1'=>[0,0],'p2'=>[192,0],'openings'=>[{'mark'=>'W1','type'=>'Window','width'=>36.0,'height'=>82.5,'sill'=>42.0,'header_size'=>'2x6','center'=>[48,0]}]},
                    {'id'=>'W-102','level'=>'Level 1','type'=>'EXT 2x6','p1'=>[192,0],'p2'=>[192,120],'openings'=>[]}]}
stu = {'walls'=>[{'id'=>'W-101','level'=>'Level 1','type'=>'INT 2x4','p1'=>[192,1],'p2'=>[0,0],'openings'=>[{'mark'=>'w1','type'=>'Window','width'=>36.0,'height'=>80.0,'sill'=>42.0,'header_size'=>'2x6','center'=>[48.5,0]},{'mark'=>'D9','center'=>[0,0]}]}],
  'framing'=>{'W-101'=>{'correct'=>30,'total'=>34}}, 'takeoff'=>{'score'=>80.0}, 'log'=>[1,2,3]}
require 'pp'; pp AnswerKey.compare(key, stu)
# student-style lengths: units in words, unicode fractions; two whole numbers is a typo, not a sum
{ '7ft 8 5/8in' => 92.625, "92⅝" => 92.625, '16 ft' => 192.0, '92 5/8in' => 92.625, "7’ 8 5/8”" => 92.625,
  '7-8 5/8' => nil, '92 5/8 1/2' => nil }.each do |s, want|
  got = Framing.parse_len(s)
  raise "parse_len(#{s.inspect}) = #{got.inspect}, want #{want.inspect}" unless got == want
end
puts 'parse_len student formats ok'
