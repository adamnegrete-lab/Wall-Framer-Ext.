require 'fileutils'
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
          'framing_table' => true,        # frame each wall flat beside the house, then stand it up
          'jobsite_order' => true,        # plates -> openings -> opening units -> commons -> double plate
          'student_layout' => true,       # students mark their own common-stud layout
          'ladder_oc' => 24               # ladder blocking spacing at tees
        },
        'pw_hash' => nil,
        'log' => [],          # inspection attempts
        'takeoff' => nil,     # student's takeoff rows
        'takeoff_log' => [],  # takeoff check attempts
        'dtp_order' => [],
        'dtp_seq' => nil,     # double plate pieces in the order they went on
        'notes' => [],        # job notes the instructor posts
        'student_notes' => [],
        'catches' => [],      # mistakes the inspector caught: one per wall + piece, with how many times
        'notes_seen_at' => 0, # Job Notes tab last opened
        'sfpa' => nil,        # header tables imported by the instructor (else the built-in ones)
        # Header span table for this assignment, entered by the instructor from the
        # code book (IRC 2024 Table R602.7(1)) for the assignment's conditions.
        'span_table' => [],   # [{'size'=>'2x8','plies'=>2,'span'=>inches,'jacks'=>1}]
        'span_conditions' => '',
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
        # Walls taken back out (a loop drawn the wrong way): their numbers get used again.
        def give_back_wall_ids(level_name, ids)
          nums = ids.map { |id| id[/\d{2}\z/].to_i }.reject(&:zero?)
          return if nums.empty?
          update { |d| d['next_wall'][level_name] = nums.min }
        end

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


        def import_sfpa(path)
          t = JSON.parse(File.read(path))
          raise 'not a Wall Framer header table file' unless t['roof'] && t['roof_floor'] && t['spans'] && t['openings']
          update { |d| d['sfpa'] = t }
          save_local_sfpa(t)
          t
        end

        # A copy kept on this computer (not in the extension download), so every
        # model you open or start here gets the tables without importing again.
        def local_dir
          File.join(ENV['WALLFRAMER_HOME'] || ENV['APPDATA'] || Dir.home, 'DMACC Wall Framer')
        end

        def local_sfpa_path
          File.join(local_dir, 'header_tables.json')
        end

        def save_local_sfpa(t)
          FileUtils.mkdir_p(local_dir)
          File.write(local_sfpa_path, JSON.generate(t))
        rescue StandardError
          nil
        end

        def local_sfpa
          File.exist?(local_sfpa_path) ? JSON.parse(File.read(local_sfpa_path)) : nil
        rescue StandardError
          nil
        end

        # The model's tables; fills them in from this computer's copy if the model has none.
        def sfpa_tables
          t = data['sfpa']
          return t if t
          lt = local_sfpa
          if lt
            update { |d| d['sfpa'] = lt }
            return lt
          end
          builtin_sfpa
        end

        # The header tables that ship with Wall Framer (SFPA Southern Pine, No. 2).
        def builtin_sfpa
          @builtin_sfpa ||= JSON.parse(File.read(File.join(__dir__, 'data', 'sfpa_headers.json')))
        rescue StandardError
          nil
        end

        # Log every real mistake an inspection catches (not blanks). One record per wall + piece.
        # Returns how many NEW catches this inspection added.
        def log_catches(wall_id, issues)
          added = 0
          update do |d|
            d['catches'] ||= []
            issues.each do |i|
              rec = d['catches'].find { |c| c['wall'] == wall_id && c['slot'] == i[:slot_id] }
              if rec
                rec['times'] = rec['times'].to_i + 1
              else
                d['catches'] << { 'wall' => wall_id, 'slot' => i[:slot_id], 'label' => i[:label], 'message' => i[:message],
                                  'times' => 1, 'at' => Time.now.to_i }
                added += 1
              end
            end
          end
          added
        end

        def log_inspection(entry)
          update { |d| d['log'] << entry.merge('time' => Time.now.strftime('%Y-%m-%d %H:%M'), 'at' => Time.now.to_i, 'summary' => entry['summary']) }
        end
      end
    end
  end
end
