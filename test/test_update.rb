require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
chk(Updater.newer?('0.6.10', '0.6.9') && !Updater.newer?('0.6.0', '0.6.0') && Updater.newer?('1.0', '0.9.9'), 'version compare')
g = Builder.create_wall(Geom::Point3d.new(0,0,0), Geom::Point3d.new(120,0,0), 'Level 1', 'EXT 2x6')
chk(Updater.reload!, 'reload in place works')
chk(Builder.all_walls.size == 1 && Builder.params_of(Builder.all_walls.first)['id'] == 'W-101', 'model data survives reload')
Sketchup.write_default('DMACC_WallFramer', 'update_url', 'https://x/version.json')
Sketchup::Http::RESPONSES['https://x/version.json'] = Sketchup::Http::Res.new(200, JSON.generate('version' => '9.9.9', 'rbz' => 'https://x/w.rbz', 'notes' => 'Test'))
Sketchup::Http::RESPONSES['https://x/w.rbz'] = Sketchup::Http::Res.new(200, 'PK' + 'x' * 5000)
UI.messages.clear; UI.answers[:msg] = IDYES
Updater.check(quiet: true)
chk(UI.messages.first.to_s.include?('9.9.9 is available'), 'newer version offered')
chk($installed == '/tmp/WallFramer_9.9.9.rbz' && File.size($installed) > 1000, 'downloaded and installed')
UI.messages.clear
Sketchup::Http::RESPONSES['https://x/version.json'] = Sketchup::Http::Res.new(200, JSON.generate('version' => VERSION, 'rbz' => 'https://x/w.rbz'))
Updater.check(quiet: true); chk(UI.messages.empty?, 'quiet check stays quiet when up to date')
Updater.check(quiet: false); chk(UI.messages.last.include?('up to date'), 'manual check says up to date')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
