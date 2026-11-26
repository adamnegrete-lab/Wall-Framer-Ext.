require_relative '../src/dmacc_wall_framer/framing'
F = DMACC::WallFramer::Framing
ext = {'stud'=>'2x6','spacing'=>16.0,'height'=>97.125,'top_plates'=>2}
int = ext.merge('stud'=>'2x4')
walls = {
 'W-101 South (SW->SE)' => ext.merge('length'=>192.0,'openings'=>[{'mark'=>'W1','type'=>'Window','x'=>48-18.0,'width'=>36.0,'height'=>82.5,'sill'=>34.5,'header'=>'2x8'}]),
 'W-102 East (SE->NE)'  => ext.merge('length'=>133.0,'openings'=>[]),
 'W-103 North (NE->NW)' => ext.merge('length'=>192.0,'openings'=>[{'mark'=>'D1','type'=>'Door','x'=>132-19.0,'width'=>38.0,'height'=>82.5,'header'=>'2x10'}]),
 'W-104 West (NW->SW)'  => ext.merge('length'=>133.0,'openings'=>[{'mark'=>'W2','type'=>'Window','x'=>66.5-12,'width'=>24.0,'height'=>82.5,'sill'=>46.5,'header'=>'2x6'}]),
 'W-105 Closet (S->N)'  => int.merge('length'=>133.0,'openings'=>[{'mark'=>'D2','type'=>'Door','x'=>36-16.0,'width'=>32.0,'height'=>82.5,'header'=>'2x6'}]),
}
all=[]
walls.each do |n,w|
  e=F.validate(w); puts "#{n}: #{e.empty? ? 'OK' : e}"
  s=F.slots(w); puts "   #{s.size} members"
  s.select{|x| x.opening}.group_by{|x| [x.expected['role'],F.fmt_len(x.expected['length']),x.expected['size']]}.each{|k,v| puts "   #{k.join(' ')} x#{v.size}"}
  all += F.expected_members(w)
end
puts "TOTAL pieces #{all.size}"
F.cut_list(all).sort_by{|(s,l),_|[s,-l]}.each{|(s,l),q| puts "#{s} #{F.fmt_len(l)} x#{q}"}
