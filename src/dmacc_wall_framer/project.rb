require 'json'
require 'digest'

module DMACC
  module WallFramer
    # Model-level data: levels, wall types, instructor settings, logs.
    # Stored as JSON in the .skp, so an assignment file carries its own setup.
    module Project
      DICT = 'dmacc_wf_project'.freeze

      DEFAULT = {
        'levels' => [
          { 'name' => 'Level 1', 'elev' => 0.0 }
        ],
        'wall_types' => [
          { 'name' => 'EXT 2x6', 'stud' => '2x6', 'spacing' => 16.0, 'height' => 97.125,
            'top_plates' => 2, 'function' => 'Exterior', 'bearing' => true },
          { 'name' => 'INT 2x4', 'stud' => '2x4', 'spacing' => 16.0, 'height' => 97.125,
            'top_plates' => 2, 'function' => 'Interior', 'bearing' => false }
        ],
        'header_table' => Framing::DEFAULT_HEADER_TABLE.map(&:dup),
        'settings' => {
          'feedback' => 'coach',          # count | locate | coach | fix
          'takeoff_feedback' => 'coach',  # count | coach | fix
          'auto_cutlist' => false,        # students can export the auto cut list
          'students_edit_setup' => true,  # students may edit levels / wall types
          'show_layout_marks' => true,    # gray layout marks for unconfirmed slots
          'shop_letters' => true,         # shop drawing shows X/K/J/C letters
          'shop_cutlist' => true,         # shop drawing includes the cut list
          'shop_elevation' => true,       # shop drawing draws every member
          'kerf' => 0.125,
          'jobsite_order' => true,        # plates -> openings -> opening units -> commons -> double plate
          'student_layout' => true,       # students mark their own common-stud layout
          'tape_readout' => false,        # show a tape reading while marking (off = use Tape Measure)
          'guided' => true,               # pop-up framing: click a piece, enter its length
          'popup_tips' => true            # pop-ups say how to measure (not the answer)
        },
        'pw_hash' => nil,
        'log' => [],          # inspection attempts
        'takeoff' => nil,     # student's takeoff rows
        'takeoff_log' => [],  # takeoff check attempts
        'yard' => nil,        # material yard (piles, cart, offcuts)
        'dtp_order' => [],    # wall ids in the order double top plates went on
        'next_wall' => {}     # level name => next sequence number
      }.freeze

      @unlocked = false # instructor unlocked in this session

      class << self
        def model
          Sketchup.active_model
        end

        def data
          raw = model.get_attribute(DICT, 'data')
          d = raw ? JSON.parse(raw) : {}
          deep = JSON.parse(JSON.generate(DEFAULT))
          deep.merge(d) { |k, a, b| k == 'settings' ? a.merge(b) : b }
        end

        def save(d)
          model.set_attribute(DICT, 'data', JSON.generate(d))
        end

        def update
          d = data
          yield d
          save(d)
          d
        end

        def settings
          data['settings']
        end

        def header_table
          data['header_table'].map { |w, s| [w.to_f, s] }
        end

        def level(name)
          data['levels'].find { |l| l['name'] == name }
        end

        def wall_type(name)
          data['wall_types'].find { |t| t['name'] == name }
        end

        # ----- instructor lock -----

        def locked?
          !data['pw_hash'].nil?
        end

        def instructor?
          !locked? || @unlocked
        end

        def unlock(pw)
          @unlocked = (Digest::SHA256.hexdigest(pw.to_s) == data['pw_hash'])
        end

        def relock
          @unlocked = false
        end

        def set_password(pw)
          update { |d| d['pw_hash'] = pw.to_s.empty? ? nil : Digest::SHA256.hexdigest(pw.to_s) }
          @unlocked = false
        end

        # ----- ids -----

        # W-101, W-102 on Level 1; W-201 on Level 2 ...
        def next_wall_id(level_name)
          d = data
          idx = d['levels'].index { |l| l['name'] == level_name } || 0
          used = Builder.all_walls.map { |w| Builder.params_of(w)['id'] }
          n = (d['next_wall'][level_name] || 1).to_i
          id = nil
          loop do
            id = format('W-%d%02d', idx + 1, n)
            break unless used.include?(id)
            n += 1
          end
          d['next_wall'][level_name] = n + 1
          save(d)
          id
        end

        def log_inspection(entry)
          update { |d| d['log'] << entry.merge('time' => Time.now.strftime('%Y-%m-%d %H:%M')) }
        end
      end
    end
  end
end
