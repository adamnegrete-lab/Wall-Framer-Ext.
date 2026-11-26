require 'json'
require_relative 'mock_sketchup'
require_relative '../src/dmacc_wall_framer/main'
include DMACC::WallFramer
M = Sketchup.active_model; V = M.active_view
def chk(c, m) = (puts((c ? 'PASS ' : 'FAIL ') + m); $f = true unless c)
a = Builder.create_wall(Geom::Point3d.new(0,0,0), Geom::Point3d.new(192,0,0), 'Level 1', 'EXT 2x6')
b = Builder.create_wall(Geom::Point3d.new(192,5.5,0), Geom::Point3d.new(192,138.5,0), 'Level 1', 'EXT 2x6')
chk(a.locked && b.locked, 'walls are locked (no accidental open/move)')
Dialogs.focus_wall('W-102')
M.active_path = [b] # student double-clicked into a wall
DMACC::WallFramer.frame_tool
chk(M.active_path.nil?, 'Frame tool closes the open wall first')
chk(Dialogs.tool.is_a?(GuidedTool) && Dialogs.tool.instance_variable_get(:@focus) == 'W-102', 'Frame picks up the wall you were on (W-102)')
DMACC::WallFramer.tape_tool; chk($action == 'selectMeasureTool:', 'Tape button switches to Tape Measure')
M.active_path = [a]
DMACC::WallFramer.frame_tool; chk(M.active_path.nil? && Dialogs.tool.mode == :guided, 'back to framing in one click')
# highlight boxes use the wall's real position now that edits are closed
DMACC::WallFramer.inspect_tool
chk(Builder.params_of(b)['last_inspection'], 'Inspect button inspects the working wall')
puts($f ? 'SOME FAILED' : 'ALL PASSED')
