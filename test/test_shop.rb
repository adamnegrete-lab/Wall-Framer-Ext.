%w[framing shop].each { |f| require_relative "../src/dmacc_wall_framer/#{f}" }
include DMACC::WallFramer
wall = {'id'=>'W-101','type'=>'EXT 2x6','level'=>'Level 1','stud'=>'2x6','spacing'=>16.0,'height'=>97.125,'top_plates'=>2,'length'=>192.0,
  'openings'=>[{'mark'=>'W1','type'=>'Window','x'=>30.0,'width'=>36.0,'height'=>82.5,'sill'=>34.5,'header'=>'2x8'},
               {'mark'=>'D9','type'=>'Door','x'=>120.0,'width'=>38.0,'height'=>82.5,'header'=>'2x10'}]}
File.write('/tmp/shop_full.html', Shop.html(wall, {'letters'=>true,'cutlist'=>true,'elevation'=>true}))
File.write('/tmp/shop_min.html', Shop.html(wall, {'letters'=>false,'cutlist'=>false,'elevation'=>false}))
