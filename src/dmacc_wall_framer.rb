require 'sketchup.rb'
require 'extensions.rb'

module DMACC
  module WallFramer
    Sketchup.require(File.join(__dir__, 'dmacc_wall_framer', 'version'))
    unless file_loaded?(__FILE__)
      ext = SketchupExtension.new('Wall Framer', File.join(__dir__, 'dmacc_wall_framer', 'main'))
      ext.description = 'Teaching wall framer: levels and wall types, shop drawings, a material yard and saw, hands-on member installation with inspections, manual takeoff checks, and answer-key grading.'
      ext.version = VERSION
      ext.creator = 'Adam Negrete - DMACC Construction Technology'
      ext.copyright = '2026'
      Sketchup.register_extension(ext, true)
      file_loaded(__FILE__)
    end
  end
end
