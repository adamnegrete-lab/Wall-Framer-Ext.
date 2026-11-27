# Pure-Ruby inspection: compares what the student entered for each slot
# against the correct framing and writes feedback at the instructor's level.
module DMACC
  module WallFramer
    module Inspector
      LENGTH_TOL = 1.0 / 16 # within 1/16" counts as correct

      # Feedback levels the instructor can pick, least help to most.
      LEVELS = {
        'count' => 'Count only - "3 errors on W-101"',
        'locate' => 'Locate - flags which members and which field is wrong',
        'coach' => 'Coach - flags + explains the why (no answers)',
        'fix' => 'Suggest fix - shows the correct value'
      }.freeze

      # Why-hints. Written for students: short, trade terms, explain the reason.
      ROLE_HINTS = {
        'Common Stud' => 'Full-height stud on the layout. It carries the top plates down to the bottom plate.',
        'King Stud' => 'Full-height stud on the outside of the jack. It runs plate to plate and gets nailed into the end of the header.',
        'Jack Stud' => 'Also called a trimmer. It sits tight to the rough opening and holds up the header.',
        'Cripple Stud' => 'Short stud that keeps the layout going above a header or below a rough sill, so sheathing and drywall still land on framing.',
        'Header' => 'Spans the opening and carries the load above it down to the jacks.',
        'Rough Sill' => 'Laid flat at the bottom of a window rough opening. The window sits on it.',
        'Bottom Plate' => 'Laid flat on the subfloor. Studs stand on it. It gets cut out at door openings.',
        'Top Plate' => 'First plate across the top of the studs.',
        'Double Top Plate' => 'Second top plate. It ties walls together at corners and intersections.'
      }.freeze

      LENGTH_HINTS = {
        'Common Stud' => 'Stud cut length = overall wall height minus the bottom plate and the top plate(s) (1-1/2" each).',
        'King Stud' => 'A king runs the same length as a common stud.',
        'Jack Stud' => 'Jack cut length = head height (bottom of the header, from the subfloor) minus the bottom plate.',
        'Cripple Stud' => 'Above a header: space between the top of the header and the underside of the top plate. Below a sill: top of the bottom plate to the underside of the rough sill.',
        'Header' => 'Header length = rough opening width plus one jack (1-1/2") on each side.',
        'Rough Sill' => 'Rough sill length = rough opening width (it fits between the jacks).',
        'Bottom Plate' => 'Plate runs the full wall length. At a door, stop the plate at the rough opening.',
        'Top Plate' => 'Top plate runs the full wall length.',
        'Double Top Plate' => 'Check the wall length.'
      }.freeze

      SIZE_HINT = 'Check the wall type on the plans. Studs and plates match the wall depth. Headers come from the header schedule or header table.'

      Issue = Struct.new(:slot_id, :label, :fields, :message, :hint, :fix) do
        def to_h
          { 'slot_id' => slot_id, 'label' => label, 'fields' => fields,
            'message' => message, 'hint' => hint, 'fix' => fix }
        end
      end

      module_function

      def same_len?(a, b)
        (a.to_f - b.to_f).abs <= LENGTH_TOL + 1e-9
      end

      def complete?(entry)
        entry && !entry['role'].to_s.empty? && !entry['size'].to_s.empty? && entry['length'].to_f > 0
      end

      # Returns { 'wall_id', 'total', 'correct', 'blank', 'issues' => [Issue], 'summary' }
      def inspect_wall(wall, entries, level: 'coach', table: Framing::DEFAULT_HEADER_TABLE, student_layout: false)
        slots = Framing.slots(wall, table)
        entries ||= {}
        issues = []
        blank = 0
        correct = 0
        extra = 0
        if student_layout
          ids = slots.map(&:id)
          marks = (wall['marks'] || []).map(&:to_f)
          lay = Framing.layout_marks(Framing::DEFAULT_WALL.merge(wall))
          marks.each do |mx|
            ms = Framing.mark_slot(wall, mx, [])
            next if ids.include?(ms.id)
            extra += 1
            near = lay.min_by { |l| (l - mx).abs }
            sp = wall['spacing'].to_f
            issues << Issue.new(ms.id, ms.label, ['layout'],
                                "Off layout - this mark doesn't land on #{sp.round(1) == sp.round ? sp.round : sp}\" O.C.",
                                'Hook your tape on the wall start. Layout marks fall every 16" (or 24") with the stud edge 3/4" back from the mark, so the stud centers on it. Pull the extra stud and move the mark.',
                                near && { 'role' => 'Common Stud', 'size' => wall['stud'], 'length' => near,
                                          'length_text' => "move to #{Framing.fmt_len(near)} from start" })
          end
        end
        slots.each do |s|
          e = entries[s.id]
          unless complete?(e)
            blank += 1
            if student_layout && s.common && !(wall['marks'] || []).any? { |m| Framing.mark_slot(wall, m.to_f, []).id == s.id }
              issues << Issue.new(s.id, 'Common stud layout', ['layout'], 'A common stud is missing from your layout.',
                                  'Count your layout marks between openings - every 16" (or 24") O.C. space gets a stud.',
                                  { 'role' => 'Common Stud', 'size' => s.expected['size'], 'length' => s.x,
                                    'length_text' => "mark at #{Framing.fmt_len(s.x)} from start" })
              next
            end
            if s.kind == :backing
              issues << Issue.new(s.id, s.label, ['backing'], "#{s.id.sub('TEE:', '')} tees into this wall - there's no backing behind it.",
                                  "The partition's end stud and the drywall need something to nail to: ladder blocking or a 3-stud channel.",
                                  { 'role' => 'Partition Backing', 'size' => s.expected['size'], 'length' => 0,
                                    'length_text' => 'ladder blocking or a 3-stud channel' })
              next
            end
            issues << Issue.new(s.id, s.label, %w[role size length].select { |f| e.nil? || e[f].to_s.empty? || (f == 'length' && e[f].to_f <= 0) },
                                'Not filled in yet.', nil, nil)
            next
          end
          if e['auto']
            correct += 1
            next
          end
          x = s.expected
          bad = []
          bad << 'role' unless e['role'] == x['role']
          pcs = e['pieces']
          if pcs && s.id.start_with?('HDR:')
            bad << 'size' unless pcs.all? { |pc| pc['size'] == x['size'] }
            bad << 'length' unless pcs.all? { |pc| same_len?(pc['length'], x['length']) }
            if pcs.size != s.plies.to_i
              issues << ply_issue(s, pcs.size, bad)
              next
            end
          else
            bad << 'size' unless e['size'] == x['size']
            bad << 'length' unless same_len?(e['length'], x['length'])
          end
          if bad.empty?
            correct += 1
            next
          end
          issues << build_issue(s, e, bad)
        end

        # Corner assemblies: what the student chose vs what the building needs
        need = wall['corner_need'] || {}
        (wall['corners'] || {}).each do |end_name, type|
          want = (need[end_name] || {})['type'] || 'single'
          next if want == type
          where = end_name == 'start' ? 'Wall start' : 'Wall end'
          by = (need[end_name] || {})['by']
          if want == 'L'
            # the expected post is already reported as not filled - say why instead
            before = issues.size
            issues.reject! { |i| i.slot_id == "LPOST:#{end_name}" }
            blank -= before - issues.size
            issues << Issue.new("LPOST:#{end_name}", "#{where} corner", ['corner'],
                                'This corner needs an L-corner post.',
                                "#{by || 'Another wall'} butts into this end - its drywall needs a stud turned flat behind your end stud to nail to.",
                                { 'role' => 'Corner Stud', 'size' => wall['stud'], 'length' => 0, 'length_text' => 'L-corner post' })
          else
            extra += 1
            issues << Issue.new("LPOST:#{end_name}", "#{where} corner", ['corner'],
                                'No corner post needed here.',
                                "Nothing butts into this end#{by ? '' : ' (or this wall butts into the other one)'} - a single end stud is all it takes.",
                                { 'role' => 'Common Stud', 'size' => wall['stud'], 'length' => 0, 'length_text' => 'single stud' })
          end
        end
        # Wrong O.C.: one clear issue instead of a pile of off-layout marks
        oc = wall['oc'].to_f
        if oc > 0 && (oc - wall['spacing'].to_f).abs > 0.01
          lay = issues.select { |i| i.fields == ['layout'] }
          issues -= lay
          fmt = ->(v) { v == v.round ? v.round.to_s : v.to_s }
          issues << Issue.new('LAYOUT', 'Stud layout', ['layout'],
                              "Studs are laid out at #{fmt.call(oc)}\" O.C. - this wall type is #{fmt.call(wall['spacing'].to_f)}\" O.C.",
                              'Check the wall legend on the plans for the stud spacing, then redo the stud layout (right-click the wall).', nil)
        end

        # Plate splices have to land centered on a stud
        Framing::PLATE_IDS.each do |pid|
          e = entries[pid] or next
          splices = Framing.plate_splices(e)
          next if splices.empty?
          sp = (wall['oc'] || wall['spacing']).to_f
          studs = slots.select { |sl| sl.kind == :vertical }.map { |sl| Framing.layout_dist(wall, sl.x + Framing::T / 2.0) }
          splices.each do |d|
            k = (d / sp).round
            on_layout = sp.positive? && (d - k * sp).abs <= 1.0 / 8
            on_stud = studs.any? { |c| (c - d).abs <= 1.0 / 8 }
            next if on_layout || on_stud
            name = pid == 'BP' ? 'Bottom plate' : 'Top plate'
            near = [k, 1].max * sp
            issues << Issue.new("SPLICE:#{pid}", "#{name} splice", ['splice'],
                                "#{name} splice at #{Framing.fmt_len(d)} from the arrow end isn't centered on a stud.",
                                "A plate splice has to land in the middle of a stud so both pieces bear on it. Layout marks fall every #{sp == sp.round ? sp.round : sp}\" from the arrow end - a full 16' piece always lands on one.",
                                { 'role' => name, 'size' => '', 'length' => near, 'length_text' => "splice at #{Framing.fmt_len(near)} from the arrow end" })
          end
        end

        # Header height marks on the kings vs the head height on the plans
        (wall['hdr_marks'] || {}).each do |mk, z|
          o = (wall['openings'] || []).find { |x| x['mark'] == mk } or next
          next if (z.to_f - o['height'].to_f).abs <= 1.0 / 16
          issues << Issue.new("HDRMARK:#{mk}", "#{mk} header mark", ['mark'],
                              "The header mark on the #{mk} kings is at #{Framing.fmt_len(z.to_f)} - it doesn't match the head height on the plans.",
                              'Check the head height on the plans (window schedule or elevations), then click a king to move the mark. Jacks are cut to the mark.',
                              { 'role' => 'Header mark', 'size' => '', 'length' => o['height'].to_f,
                                'length_text' => "mark at #{Framing.fmt_len(o['height'].to_f)}" })
        end

        id = wall['id'] || 'Wall'
        total = slots.size + extra
        wrong = issues.size - blank
        summary = if issues.empty?
                    "#{id}: PASSED - all #{total} members are correct."
                  else
                    parts = []
                    parts << "#{wrong} member#{wrong == 1 ? '' : 's'} with errors" if wrong > 0
                    parts << "#{blank} not filled in" if blank > 0
                    "#{id}: #{parts.join(', ')} (#{correct} of #{total} correct)."
                  end
        issues = shape_for_level(issues, level)
        { 'wall_id' => id, 'total' => total, 'correct' => correct, 'blank' => blank,
          'wrong' => wrong, 'issues' => issues, 'summary' => summary, 'level' => level }
      end

      def ply_issue(slot, have, bad)
        x = slot.expected
        msg = "Header has #{have} of #{slot.plies} plies."
        msg += ' A ply is the wrong size.' if bad.include?('size')
        msg += ' A ply is the wrong length.' if bad.include?('length')
        hint = 'A built-up header uses enough plies to match the wall depth (2 plies + 1/2" spacer in a 2x4 wall, 3 plies in a 2x6 wall).'
        hint += ' ' + LENGTH_HINTS['Header'] if bad.include?('length')
        Issue.new(slot.id, slot.label, (['plies'] + bad).uniq, msg, hint,
                  { 'role' => x['role'], 'size' => x['size'], 'length' => x['length'],
                    'length_text' => "#{slot.plies} plies x #{Framing.fmt_len(x['length'])}" })
      end

      def build_issue(slot, entry, bad)
        x = slot.expected
        role = x['role']
        msgs = []
        hints = []
        if bad.include?('role')
          msgs << 'Wrong member for this location.'
          hints << ROLE_HINTS[role]
        end
        if bad.include?('size')
          msgs << 'Wrong lumber size.'
          hints << SIZE_HINT
        end
        if bad.include?('length')
          diff = entry['length'].to_f - x['length'].to_f
          msgs << (diff > 0 ? 'Cut length is too long.' : 'Cut length is too short.')
          hints << LENGTH_HINTS[role]
        end
        fix = { 'role' => x['role'], 'size' => x['size'], 'length' => x['length'],
                'length_text' => Framing.fmt_len(x['length']) }
        Issue.new(slot.id, slot.label, bad, msgs.join(' '), hints.compact.uniq.join(' '), fix)
      end

      # Strip information the instructor's feedback level doesn't allow.
      # ---------- job-site order ----------

      def slot_done?(slot, entry)
        return false unless complete?(entry)
        return entry['full'] != false if slot.id == 'TP:2' || Framing.plate?(slot) # every piece on
        return (entry['pieces'] || []).size >= slot.plies.to_i if slot.id.start_with?('HDR:') && entry['pieces']
        true
      end

      # Why a slot can't be framed yet (nil = go ahead).
      def gate(slot, entries, by_id)
        missing = (slot.deps || []).reject { |id| (s = by_id[id]).nil? || slot_done?(s, entries[id]) }
        return nil if missing.empty?
        return 'Plates first - cut and set the bottom plate and top plate.' if (missing & %w[BP TP:1]).any?
        role = slot.expected['role']
        case slot.phase
        when 'dtp' then 'Double top plates go on after every wall is framed and standing - use Double top plates in the Framing panel.'
        when 'commons' then 'Finish every opening unit first, then lay out and nail the commons.'
        else
          if role == 'Jack Stud' then 'Nail the king first - the jack gets nailed to the king.'
          elsif role == 'Header' then 'Both jacks go in before the header - the header sits on them.'
          elsif role == 'Rough Sill' then 'Set the header first, then pull the rough opening down from the top of the jack to find the sill.'
          elsif slot.label.include?('header block') then 'Header first - header blocks fill from the header up to the top plate.'
          elsif slot.label.include?('under sill') then 'Sill first - cripples run from the bottom plate up to the sill.'
          else 'Not yet - something has to go in before this.'
          end
        end
      end

      def shape_for_level(issues, level)
        case level
        when 'count' then []
        when 'locate'
          issues.map { |i| Issue.new(i.slot_id, i.label, i.fields, i.message, nil, nil) }
        when 'coach'
          issues.map { |i| Issue.new(i.slot_id, i.label, i.fields, i.message, i.hint, nil) }
        else issues
        end
      end
    end
  end
end
