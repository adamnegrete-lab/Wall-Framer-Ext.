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
          'kerf' => 0.125,
          'framing_table' => true,        # frame each wall flat beside the house, then stand it up
          'jobsite_order' => true,        # plates -> openings -> opening units -> commons -> double plate
          'student_layout' => true,       # students mark their own common-stud layout
          'tape_readout' => false,        # show a tape reading while marking (off = use Tape Measure)
          'guided' => true,               # pop-up framing: click a piece, enter its length
          'popup_tips' => true,           # pop-ups say how to measure (not the answer)
          'rfi_delay_min' => 1,           # TEST setting - normally 32          # RFIs answer themselves after this long (students don't see a timer)
          'ladder_oc' => 24               # ladder blocking spacing at tees
        },
        'pw_hash' => nil,
        'log' => [],          # inspection attempts
        'takeoff' => nil,     # student's takeoff rows
        'takeoff_log' => [],  # takeoff check attempts
        'yard' => nil,        # material yard (piles, cart, offcuts)
        'dtp_order' => [],
        'dtp_seq' => nil,     # double plate pieces in the order they went on
        'rfis' => [],
        'notes' => [],        # job notes the instructor posts
        'student_notes' => [],
        'catches' => [],       # mistakes the inspector caught: one per wall + piece, with how many times # field notes the student saves (numbers off the plans, etc.)
        'notes_seen_at' => 0, # Job Notes tab last opened
        'sfpa' => nil,        # header tables imported by the instructor (kept in the model, not the extension)         # requests for information (header sizes not on the plans)
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

        # ---------- RFIs ----------

        def submit_rfi(wall_id, mark, question)
          n = nil
          update do |d|
            n = d['rfis'].size + 1
            d['rfis'] << { 'n' => n, 'wall' => wall_id, 'mark' => mark, 'question' => question,
                           'at' => Time.now.to_i, 'answer' => nil, 'answered_at' => nil }
          end
          n
        end

        # The "engineer's response": the instructor's span table for the
        # assignment, or (2) 2x4 flat in a non-bearing wall (IRC R602.7.4).
        def rfi_answer(rfi)
          g = Builder.find_wall(rfi['wall']) or return nil
          p = Builder.params_of(g)
          o = p['openings'].find { |x| x['mark'] == rfi['mark'] } or return nil
          unless p['bearing']
            return { 'header' => Framing::FLAT, 'text' => "#{rfi['mark']} is in a non-bearing wall - use (2) 2x4 flat." }
          end
          sfpa_answer(g, o) || span_table_answer(o)
        end

        # Header tables: roof only (nothing framed above) or roof + wall + floor,
        # looked up by the clear opening and the span the wall carries.
        def sfpa_answer(g, o)
          t = sfpa_tables or return nil
          key = Builder.floor_above?(g) ? 'roof_floor' : 'roof'
          span_ft = Builder.building_span(g) / 12.0
          ci = t['spans'].index { |s| s >= span_ft - 0.01 } or return nil
          ri = t['openings'].index { |w| w >= o['width'].to_f - 0.01 } or return nil
          cell = t[key][ri][ci]
          return nil unless cell['size'] # glulam - the instructor answers that one
          { 'header' => cell['size'], 'plies' => cell['plies'].to_i,
            'text' => "#{o['mark']}: use (#{cell['plies']}) #{cell['size']}." }
        end

        def span_table_answer(o)
          span = o['width'].to_f
          row = data['span_table'].select { |r| r['span'].to_f >= span - 1e-6 && Framing::ACTUAL[r['size']] }
                                  .min_by { |r| [Framing::ACTUAL[r['size']], r['plies'].to_i] }
          return nil unless row
          cond = data['span_conditions'].to_s.strip
          { 'header' => row['size'], 'plies' => row['plies'].to_i,
            'text' => "#{o['mark']}: use (#{row['plies']}) #{row['size']}#{cond.empty? ? '' : " (#{cond})"}." }
        end

        # Why an RFI can't answer itself (for the instructor), or nil.
        def rfi_stuck_reason(rfi)
          return nil if rfi['answer'] || rfi_answer(rfi)
          return 'no header tables imported (Project Setup)' unless sfpa_tables || data['span_table'].any?
          'the table calls for glulam or the house is wider than 40\' - answer it yourself'
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

        # Answer one RFI now (instructor) or every RFI whose time is up.
        # Returns the RFIs answered.
        def release_rfis(force_n = nil)
          delay = (settings['rfi_delay_min'] || 32).to_f * 60
          done = []
          data['rfis'].each do |r|
            next if r['answer']
            next unless force_n == r['n'] || (force_n.nil? && Time.now.to_i - r['at'].to_i >= delay)
            ans = rfi_answer(r)
            next unless ans
            apply_rfi(r, ans)
            done << r.merge('answer' => ans['text'])
          end
          done
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

        # Instructor answers by hand (no span table row, or a different call).
        def answer_rfi_manual(n, header, plies, text)
          r = data['rfis'].find { |x| x['n'] == n && !x['answer'] } or return []
          return [] unless Framing::SIZES.include?(header) || header == Framing::FLAT
          ans = { 'header' => header, 'text' => text.to_s.strip }
          ans['plies'] = plies if plies.positive?
          apply_rfi(r, ans)
          [r.merge('answer' => ans['text'])]
        end

        def apply_rfi(rfi, ans)
          g = Builder.find_wall(rfi['wall'])
          if g
            p = Builder.params_of(g)
            p['openings'] = p['openings'].map do |o|
              next o unless o['mark'] == rfi['mark']
              # the student reads the answer and updates the opening themselves
              o.merge('rfi_new' => rfi['n'])
            end
            Builder.set_params(g, p)
            Builder.rebuild(g)
          end
          update do |d|
            r = d['rfis'].find { |x| x['n'] == rfi['n'] }
            r['answer'] = ans['text']
            r['answered_at'] = Time.now.to_i
          end
        end

        def log_inspection(entry)
          update { |d| d['log'] << entry.merge('time' => Time.now.strftime('%Y-%m-%d %H:%M'), 'at' => Time.now.to_i, 'summary' => entry['summary']) }
        end
      end
    end
  end
end
