%w[framing inspector yard_logic].each { |f| require_relative "../src/dmacc_wall_framer/#{f}" }
include DMACC::WallFramer
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
y = YardLogic.default_piles([{'stud'=>'2x6','stud_length'=>92.625},{'stud'=>'2x4','stud_length'=>92.625}], %w[2x6 2x8 2x10])
puts y['piles'].map { |p| p['label'] }.join(' | ')
pre = y['piles'].find { |p| p['label'].start_with?('2x6') && p['label'].include?('precut') }
pc, err = YardLogic.take(y, pre['id']); chk(err.nil? && y['hand'] == pc['id'], 'take precut into hand')
pc, off, err = YardLogic.cut(y, pc['id'], 81.0); chk(pc['length'] == 81.0 && (off['length'] - 11.5).abs < 1e-9, "cut jack 81, offcut #{off && off['length']}")
_, _, err = YardLogic.cut(y, pc['id'], 90.0); chk(err&.include?('Too long'), 'cannot cut longer than board')
YardLogic.install(y, pc['id']); chk(y['cart'].empty? && y['hand'].nil?, 'installed piece leaves cart')
c, err = YardLogic.take(y, off['id']); chk(c && y['offcuts'].empty?, 'pick up offcut')
c, off2, _ = YardLogic.cut(y, c['id'], 4.375); chk((off2['length'] - 7.0).abs < 1e-9, "cripple from offcut, left #{off2['length']}")
c, off3, _ = YardLogic.cut(y, off2['id'], 6.125) rescue nil
_, _ = YardLogic.take(y, off2['id']); c3, off3, _ = YardLogic.cut(y, off2['id'], 6.125)
chk(off3.nil? && (y['scrap'] - (0.125*3 + 0.75)).abs < 1e-9, "tiny remainder to scrap (scrap #{y['scrap']})")
st = YardLogic.stats(y, 81 + 4.375 + 6.125); p st
chk(st['boards_pulled'] == 1, 'one board pulled for all that')
# slot hit testing
wall = {'stud'=>'2x6','spacing'=>16.0,'height'=>97.125,'top_plates'=>2,'length'=>192.0,
  'openings'=>[{'mark'=>'W1','type'=>'Window','x'=>30.0,'width'=>36.0,'height'=>82.5,'sill'=>34.5,'header'=>'2x8'}]}
sl = Framing.slots(wall)
t = ->(x,z) { s = Framing.slot_at(sl, x, z); s && s.label }
chk(t.(28.9, 50) == 'W1 left jack', "jack hit: #{t.(28.9,50)}")
chk(t.(27.6, 90) == 'W1 left king', "king hit above jack: #{t.(27.6,90)}")
chk(t.(48, 86) == 'W1 header', "header hit: #{t.(48,86)}")
chk(t.(48, 92) =~ /header block/, "cripple above header: #{t.(48,92)}")
chk(t.(48, 20) =~ /under sill/, "cripple below sill: #{t.(48,20)}")
chk(t.(48, 33.5) == 'W1 rough sill', "sill: #{t.(48,33.5)}")
chk(t.(100, 0.7) == 'Bottom plate', "bottom plate: #{t.(100,0.7)}")
chk(t.(100, 95) == 'Top Plate', "top plate: #{t.(100,95)}")
chk(t.(48, 60).nil?, 'inside the window RO = nothing')
# header plies inspection
hs = sl.find { |s| s.id == 'HDR:W1' }
ent = sl.to_h { |s| [s.id, s.expected.dup] }
ent['HDR:W1'] = {'role'=>'Header','size'=>'2x8','length'=>39.0,'pieces'=>[{'size'=>'2x8','length'=>39.0},{'size'=>'2x8','length'=>39.0}]}
r = Inspector.inspect_wall(wall, ent, level: 'coach'); chk(r['issues'].first['message'].include?('2 of 3 plies'), r['issues'].first['message'])
ent['HDR:W1']['pieces'] << {'size'=>'2x8','length'=>39.0}
chk(Inspector.inspect_wall(wall, ent)['issues'].empty?, 'header passes with 3 plies')
ms = Framing.members_for_entry(wall, hs, ent['HDR:W1']); chk(ms.size == 3, '3 plies drawn')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
# saw stop
y2 = YardLogic.default_piles([{'stud'=>'2x6','stud_length'=>92.625}], %w[2x10])
y2['stock'] = y2['piles'].find { |p| p['label'].include?('precut') }['id']
y2['cut'] = 81.0
pcs = 3.times.map { pc, e = YardLogic.refill(y2); YardLogic.install(y2, pc['id']); pc }
chk(pcs.all? { |pc| pc['length'] == 81.0 } && y2['pulled'].size == 3 && y2['offcuts'].size == 3, 'saw stop: 3 jacks from 3 precuts, 3 drops')
y2['cut'] = 6.125; y2['use_offcuts'] = true
pc, e = YardLogic.refill(y2); chk(pc['length'] == 6.125 && y2['pulled'].size == 3, 'offcuts first: cripple from a drop, no new board')
y2['use_offcuts'] = false; y2['cut'] = 100.0; pc, e = YardLogic.refill(y2); chk(e&.include?("can't cut"), 'cut longer than stock refused')
y2['cut'] = nil; YardLogic.install(y2, y2['hand']) if y2['hand']; pc, _ = YardLogic.refill(y2); chk(pc['length'] == 92.625, 'no cut = full precut')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
