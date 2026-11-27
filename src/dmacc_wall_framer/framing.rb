# Pure-Ruby framing engine. No SketchUp API in here, so it can be
# unit-tested outside SketchUp. All dimensions are in inches.
#
# Wall-local coordinates:
#   x = along the wall (0 at the wall start = first click)
#   y = through the wall thickness (0 = reference face, + = into the wall)
#   z = up (0 = bottom of bottom plate = the wall's level datum)

module DMACC
  module WallFramer
    module Framing
      T = 1.5 # actual thickness of 2x lumber

      ACTUAL = {
        '2x4' => 3.5, '2x6' => 5.5, '2x8' => 7.25,
        '2x10' => 9.25, '2x12' => 11.25
      }.freeze
      SIZES = ACTUAL.keys.freeze

      # Roles a student can pick for a slot.
      ROLES = ['Bottom Plate', 'Top Plate', 'Double Top Plate', 'Common Stud',
               'King Stud', 'Jack Stud', 'Cripple Stud', 'Header', 'Rough Sill'].freeze

      # SIMPLIFIED default header table: max rough-opening width (in) => min header.
      # Placeholder only - the instructor should replace this with the table the
      # class uses (e.g. from IRC Table R602.7(1) for the assignment's loads).
      DEFAULT_HEADER_TABLE = [[42.0, '2x6'], [60.0, '2x8'], [78.0, '2x10'], [9999.0, '2x12']].freeze

      DEFAULT_WALL = {
        'stud' => '2x4', 'spacing' => 16.0, 'height' => 97.125,
        'top_plates' => 2, 'length' => 120.0, 'openings' => []
      }.freeze

      Member = Struct.new(:type, :nominal, :length, :x, :y, :z, :dx, :dy, :dz)

      # A slot is one framing member the student has to identify.
      #   id       stable key, e.g. "V:15.25:1.5", "HDR:W1"
      #   kind     :vertical or :horizontal
      #   anchor   :bottom (sits on z) or :top (hangs from z) - vertical only
      #   x, z     where it goes (left edge / anchor height)
      #   expected {'role','size','length'}
      #   label    human description of the location
      #   deps     slot ids that must be in before this one (job-site order)
      #   phase    'plates' | 'opening' | 'commons' | 'dtp'
      #   common   true for common studs on layout (students can mark these)
      Slot = Struct.new(:id, :kind, :anchor, :x, :z, :expected, :label, :opening, :plies, :deps, :phase, :common)

      module_function

      # ---------------- helpers ----------------

      def header_min_for(width, table = DEFAULT_HEADER_TABLE)
        row = table.sort_by { |w, _| w.to_f }.find { |w, _| width <= w.to_f + 1e-6 }
        row ? row[1] : table.last[1]
      end

      FLAT = '2x4F' # double 2x4 laid flat - interior non-bearing door/window headers
      RFI = 'RFI'   # header size not on the plans - waiting on an RFI answer

      # Header size the opening calls for. nil = waiting on an RFI.
      def header_for(opening, table = DEFAULT_HEADER_TABLE)
        plan = opening['header']
        return plan if SIZES.include?(plan) || plan == FLAT
        return nil if plan == RFI
        header_min_for(opening['width'].to_f, table) # models from older versions
      end

      # { 'size','height','plies','flat' } for an opening's header in a wall this deep.
      def header_dims(o, d, table = DEFAULT_HEADER_TABLE)
        h = header_for(o, table)
        return nil unless h
        return { 'size' => '2x4', 'height' => 2 * T, 'plies' => 2, 'flat' => true } if h == FLAT
        { 'size' => h, 'height' => ACTUAL[h], 'plies' => (o['plies'] || (d / T).floor).to_i, 'flat' => false }
      end

      HDR_PICK = '-- pick from the plans --'
      HDR_FLAT = '(2) 2x4 flat'
      HDR_RFI = 'Not on plans - submit RFI'

      # Header choices for pop-ups and the openings form.
      def header_choices
        [HDR_PICK, HDR_FLAT] + SIZES.reject { |x| x == '2x4' } + [HDR_RFI]
      end

      def header_from_choice(c)
        return FLAT if c == HDR_FLAT
        return RFI if c == HDR_RFI
        SIZES.include?(c) ? c : nil
      end

      def header_choice(h)
        return HDR_FLAT if h == FLAT
        return HDR_RFI if h == RFI
        SIZES.include?(h) ? h : HDR_PICK
      end

      def header_label(o)
        h = o['header']
        return '(2) 2x4 flat' if h == FLAT
        return 'RFI pending' if h == RFI
        o['plies'] ? "(#{o['plies']}) #{h}" : h.to_s
      end

      # Trade convention: a window's RO height is the opening itself (sill to
      # header); a door's RO height is measured from the subfloor. Internally
      # 'height' = head height (bottom of header) and 'sill' = top of rough sill.
      def ro_height(o)
        o['type'] == 'Window' ? o['height'].to_f - o['sill'].to_f : o['height'].to_f
      end

      # From what's on the plans: RO width x RO height + head height.
      def opening_from_ro(type, ro_h, head)
        if type == 'Window'
          { 'height' => head.to_f, 'sill' => head.to_f - ro_h.to_f }
        else
          { 'height' => ro_h.to_f, 'sill' => 0.0 }
        end
      end

      def stud_length(w)
        w['height'].to_f - T * (1 + w['top_plates'].to_i)
      end

      def jack_count(o)
        return o['jacks'].to_i if o['jacks'].to_i > 0 # from the span table / RFI answer
        o['width'].to_f > 72.0 ? 2 : 1
      end

      def depth(w)
        ACTUAL[w['stud']]
      end

      def r(v)
        (v.to_f * 1000).round / 1000.0
      end

      # ---------------- validation of wall inputs ----------------

      def validate(wall, table = DEFAULT_HEADER_TABLE)
        w = DEFAULT_WALL.merge(wall)
        errs = []
        len = w['length'].to_f
        errs << 'Wall length must be at least 12".' if len < 12
        errs << 'Stud size must be 2x4 or 2x6.' unless %w[2x4 2x6].include?(w['stud'])
        errs << 'Wall height is too short.' if stud_length(w) < 24
        stud_top = T + stud_length(w)
        ops = (w['openings'] || []).sort_by { |o| o['x'].to_f }
        marks = ops.map { |o| o['mark'].to_s.strip.upcase }
        dup = marks.select { |m| marks.count(m) > 1 }.uniq
        errs << "Opening mark used twice on this wall: #{dup.join(', ')}" unless dup.empty?
        ops.each_with_index do |o, i|
          name = o['mark'].to_s.empty? ? "#{o['type']} ##{i + 1}" : o['mark']
          jc = jack_count(o)
          left = o['x'].to_f - (jc + 1) * T
          right = o['x'].to_f + o['width'].to_f + (jc + 1) * T
          errs << "#{name}: needs a mark from the plans (e.g. W1, D2)." if o['mark'].to_s.strip.empty?
          errs << "#{name}: width must be more than 0." if o['width'].to_f <= 0
          errs << "#{name}: too close to the wall start - no room for king + jack." if left < T
          errs << "#{name}: too close to the wall end - no room for king + jack." if right > len - T
          # an L-corner post sits behind the end stud where another wall butts in
          need = w['corner_need'] || {}
          post = ACTUAL[w['stud']].to_f
          if left >= T && (need['start'] || {})['type'] == 'L' && left < T + post - 1e-6
            errs << "#{name}: the king stud would land on the corner post at the wall start - move the opening over."
          end
          if right <= len - T && (need['end'] || {})['type'] == 'L' && right > len - T - post + 1e-6
            errs << "#{name}: the king stud would land on the corner post at the wall end - move the opening over."
          end
          # a partition tees in: its backing needs that spot
          (w['tee_need'] || []).each do |t|
            next unless left < t['a1'].to_f + T && right > t['a0'].to_f - T
            errs << "#{name}: #{t['id']} tees into this wall right there - the opening can't go where the partition lands. Check the plans."
          end
          hd = header_dims(o, depth(w), table)
          if hd && o['height'].to_f + hd['height'] > stud_top + 1e-3
            errs << "#{name}: head height + #{header_label(o)} header won't fit under the top plate."
          end
          if o['type'] == 'Window'
            errs << "#{name}: RO height is too tall for that head height - the sill would be at #{fmt_in(o['sill'])}, down at the bottom plate." if o['sill'].to_f < 2 * T + 1
            errs << "#{name}: RO height must be more than 0." if o['sill'].to_f >= o['height'].to_f
          end
          nxt = ops[i + 1]
          next unless nxt
          nleft = nxt['x'].to_f - (jack_count(nxt) + 1) * T
          errs << "#{name} and #{nxt['mark']}: kings overlap - openings too close." if right > nleft
        end
        errs
      end

      # ---------------- layout ----------------

      # Layout can be pulled from either end of the wall ('layout_from' = 'end'),
      # so walls across the house can share a layout and studs line up.
      def from_end?(w)
        w['layout_from'] == 'end'
      end

      # Distance from the layout end <-> distance from the wall start.
      def layout_dist(w, x)
        from_end?(w) ? w['length'].to_f - x.to_f : x.to_f
      end

      # Left edge of each layout stud (from the wall start), with the tape hooked
      # on the layout end. sp defaults to the wall type's spacing.
      def layout_marks(w, sp = nil)
        sp = (sp || w['spacing']).to_f
        len = w['length'].to_f
        out = []
        k = 1
        loop do
          c = k * sp # stud center, from the layout end
          break if c > len - T / 2.0
          out << (from_end?(w) ? len - c - T / 2.0 : c - T / 2.0)
          k += 1
        end
        out.sort
      end

      # ---------------- slots (the answer) ----------------

      def slots(wall, table = DEFAULT_HEADER_TABLE)
        w = DEFAULT_WALL.merge(wall)
        d = depth(w)
        size = w['stud']
        len = w['length'].to_f
        sl = stud_length(w)
        stud_top = T + sl
        ops = (w['openings'] || []).sort_by { |o| o['x'].to_f }
        layout = layout_marks(w)                     # commons: the plans' spacing
        clayout = layout_marks(w, w['oc'] || w['spacing']) # cripples follow the layout the crew picked
        out = []

        exp = ->(role, sz, l) { { 'role' => role, 'size' => sz, 'length' => r(l) } }
        vslot = lambda do |x, z, anchor, role, l, label, op = nil, deps = [], phase = 'opening', common = false|
          id = "V:#{r(x)}:#{anchor == :top ? 'T' : 'B'}#{r(z)}"
          s = Slot.new(id, :vertical, anchor, r(x), r(z), exp.call(role, size, l), label, op, nil, deps, phase, common)
          out << s
          s
        end
        end_name = from_end?(w) ? 'layout end' : 'wall start'
        where = ->(x) { "#{fmt_len(layout_dist(w, x))} from #{end_name}" }
        plates = ['BP', 'TP:1']

        # Bottom plate: cut full length (door cutouts come out after framing)
        out << Slot.new('BP', :horizontal, nil, 0.0, 0.0, exp.call('Bottom Plate', size, len), 'Bottom plate',
                        nil, nil, [], 'plates', false)
        w['top_plates'].to_i.times do |i|
          role = i.zero? ? 'Top Plate' : 'Double Top Plate'
          out << Slot.new("TP:#{i + 1}", :horizontal, nil, 0.0, r(stud_top + i * T), exp.call(role, size, len), role,
                          nil, nil, [], i.zero? ? 'plates' : 'dtp', false)
        end

        blocked = ops.map do |o|
          jc = jack_count(o)
          [o['x'].to_f - (jc + 1) * T, o['x'].to_f + o['width'].to_f + (jc + 1) * T]
        end

        unit_ids = []
        ops.each do |o|
          ox = o['x'].to_f
          ow = o['width'].to_f
          oh = o['height'].to_f
          mk = o['mark'].to_s
          jc = jack_count(o)
          hd = header_dims(o, d, table)
          hdr_len = ow + 2 * jc * T
          hdr_x = ox - jc * T

          kl = vslot.call(ox - (jc + 1) * T, T, :bottom, 'King Stud', sl, "#{mk} left king", mk, plates)
          kr = vslot.call(ox + ow + jc * T, T, :bottom, 'King Stud', sl, "#{mk} right king", mk, plates)
          unit_ids.push(kl.id, kr.id)
          jacks = []
          prev_l = kl.id
          prev_r = kr.id
          jc.times do |j|
            tag = jc > 1 ? " ##{j + 1}" : ''
            jl = vslot.call(ox - (j + 1) * T, T, :bottom, 'Jack Stud', oh - T, "#{mk} left jack#{tag}", mk, [prev_l])
            jr = vslot.call(ox + ow + j * T, T, :bottom, 'Jack Stud', oh - T, "#{mk} right jack#{tag}", mk, [prev_r])
            prev_l = jl.id
            prev_r = jr.id
            jacks.push(jl.id, jr.id)
          end
          unit_ids.concat(jacks)

          hsize = hd ? hd['size'] : nil
          hdr = Slot.new("HDR:#{mk}", :horizontal, nil, r(hdr_x), r(oh), exp.call('Header', hsize, hdr_len),
                         "#{mk} header", mk, hd ? hd['plies'] : 2, jacks, 'opening', false)
          hdr.anchor = :flat if hd && hd['flat']
          out << hdr
          unit_ids << hdr.id

          sill = nil
          if o['type'] == 'Window'
            sill_bot = o['sill'].to_f - T
            sill = Slot.new("SILL:#{mk}", :horizontal, nil, r(ox), r(sill_bot), exp.call('Rough Sill', size, ow),
                            "#{mk} rough sill", mk, nil, [hdr.id], 'opening', false)
            out << sill
            unit_ids << sill.id
          end

          # Cripples + header blocks: after the studs, on the crew's layout
          if hd && stud_top - (oh + hd['height']) > 0.25
            clayout.each do |x|
              next unless x >= hdr_x - 1e-3 && x + T <= hdr_x + hdr_len + 1e-3
              vslot.call(x, stud_top, :top, 'Cripple Stud', stud_top - oh - hd['height'],
                         "#{mk} header block, #{where.call(x)}", mk, [hdr.id], 'cripples')
            end
          end
          next unless sill

          xs = [ox, ox + ow - T]
          clayout.each do |x|
            next unless x >= ox && x + T <= ox + ow
            xs << x unless xs.any? { |e| (e - x).abs < T }
          end
          xs.sort.each do |x|
            vslot.call(x, T, :bottom, 'Cripple Stud', sill_bot - T, "#{mk} cripple under sill, #{where.call(x)}", mk, [sill.id], 'cripples')
          end
        end

        # End studs + commons (+ corner posts, tee backing): after every opening unit
        cdeps = plates + unit_ids
        vslot.call(0.0, T, :bottom, 'Common Stud', sl, 'Wall start (end stud)', nil, cdeps, 'commons')
        vslot.call(len - T, T, :bottom, 'Common Stud', sl, 'Wall end (end stud)', nil, cdeps, 'commons')
        layout.each do |x|
          next if x < T || x + T > len - T
          next if blocked.any? { |a, b| x + T > a && x < b }
          vslot.call(x, T, :bottom, 'Common Stud', sl, "Common stud, #{where.call(x)}", nil, cdeps, 'commons', true)
        end
        (w['corner_need'] || {}).each do |en, need|
          next unless need['type'] == 'L'
          out << lpost_slot(w, en, need['side'], cdeps)
        end
        (w['tee_need'] || []).each { |t| out << tee_slot(w, t, cdeps) }
        # Double top plate goes on last
        all_ids = out.map(&:id) - ['TP:2']
        out.each { |s| s.deps = all_ids if s.id == 'TP:2' }

        out.sort_by { |s| [s.kind == :horizontal ? 0 : 1, s.x, s.z] }
      end

      # Where an interior wall tees in: needs backing (ladder blocking or a
      # 3-stud channel) so the partition's end stud and drywall have something to nail to.
      def tee_slot(wall, t, deps)
        w = DEFAULT_WALL.merge(wall)
        s = Slot.new("TEE:#{t['id']}", :backing, nil, r(t['a0'].to_f - T), r(T),
                     { 'role' => 'Partition Backing', 'size' => w['stud'], 'length' => r(t['a1'].to_f - t['a0'].to_f + 2 * T),
                       'height' => r(stud_length(w)) },
                     "#{t['id']} tee - partition backing", nil, nil, deps, 'commons', false)
        s.anchor = t['side'] == 'out' ? :out : :in
        s
      end

      # L-corner post: a stud turned flat behind the end stud, at the face the
      # other wall butts into, so that wall's drywall has something to nail to.
      def lpost_slot(wall, end_name, side, deps)
        w = DEFAULT_WALL.merge(wall)
        sl = stud_length(w)
        width = ACTUAL[w['stud']]
        x = end_name == 'start' ? T : w['length'].to_f - T - width
        Slot.new("LPOST:#{end_name}", :post, :bottom, r(x), r(T),
                 { 'role' => 'Corner Stud', 'size' => w['stud'], 'length' => r(sl) },
                 "#{end_name == 'start' ? 'Wall start' : 'Wall end'} corner post (L)", nil, nil, deps, 'commons', false).tap do |s|
          s.anchor = side == 'out' ? :out : :in
        end
      end

      # Where commons may NOT be marked (between kings of an opening).
      def opening_zones(wall)
        (wall['openings'] || []).map do |o|
          jc = jack_count(o)
          [o['x'].to_f - (jc + 1) * T, o['x'].to_f + o['width'].to_f + (jc + 1) * T, o['mark']]
        end
      end

      # A slot for a common stud the student marked at x (left edge).
      def mark_slot(wall, x, deps)
        w = DEFAULT_WALL.merge(wall)
        sl = stud_length(w)
        Slot.new("V:#{r(x)}:B#{r(T)}", :vertical, :bottom, r(x), r(T),
                 { 'role' => 'Common Stud', 'size' => w['stud'], 'length' => r(sl) },
                 "Common stud, your mark at #{fmt_len(x)}", nil, nil, deps, 'commons', true)
      end

      # Slots the student actually works with. With student layout on, the
      # commons come from the student's own marks instead of the answer.
      def work_slots(wall, table = DEFAULT_HEADER_TABLE, student_layout = false)
        all = slots(wall, table)
        chosen = wall['corners'] || {}
        unless chosen.empty?
          deps = all.find { |s| s.phase == 'commons' }&.deps || []
          all = all.reject { |s| s.id.start_with?('LPOST:') }
          chosen.each do |end_name, type|
            next unless type == 'L'
            side = ((wall['corner_need'] || {})[end_name] || {})['side'] || 'in'
            all << lpost_slot(wall, end_name, side, deps)
          end
        end
        return all unless student_layout
        keep = all.reject(&:common)
        deps = all.find { |s| s.common || s.label.start_with?('Wall start') }&.deps || []
        have = keep.map(&:id)
        marks = (wall['marks'] || []).map { |x| mark_slot(wall, x.to_f, deps) }.reject { |m| have.include?(m.id) }
        (keep + marks).sort_by { |s| [s.kind == :horizontal ? 0 : 1, s.x, s.z] }
      end

      # Snap a student's mark to the true layout if within tol.
      # Stud layout for a chosen O.C. (left edge of each stud, from the wall start),
      # skipping openings and the end studs.
      def auto_marks(wall, oc)
        w = DEFAULT_WALL.merge(wall)
        len = w['length'].to_f
        zones = opening_zones(w)
        layout_marks(w.merge('spacing' => oc.to_f)).select do |x|
          x >= T && x + T <= len - T && zones.none? { |a, b, _| x + T > a && x < b }
        end.map { |x| r(x) } # stored like student marks: the stud's left edge
      end

      def snap_mark(wall, x, tol = 0.125)
        exact = layout_marks(DEFAULT_WALL.merge(wall)).find { |m| (m - x).abs <= tol }
        exact || (x * 16).round / 16.0
      end

      # ---------------- geometry for what the STUDENT entered ----------------

      # Returns Members to draw for one slot given the student's entry
      # (role/size/length). Geometry follows the student's numbers, so a wrong
      # size or length is visible in the model.
      def members_for_entry(wall, slot, entry)
        w = DEFAULT_WALL.merge(wall)
        d = depth(w)
        size = entry['size']
        len = entry['length'].to_f
        width = ACTUAL[size] || d
        role = entry['role']
        return [] if len <= 0

        case slot.kind
        when :backing
          # geometry worked out when the backing went in (ladder or channel)
          (entry['geom'] || []).map do |g|
            Member.new(g['role'] || role, g['size'] || size, g['length'].to_f, g['x'], g['y'], g['z'], g['dx'], g['dy'], g['dz'])
          end
        when :post
          y = slot.anchor == :out ? 0.0 : d - T
          [Member.new(role, size, len, slot.x, y, slot.z, ACTUAL[size] || d, T, len)]
        when :vertical
          z = slot.anchor == :top ? slot.z - len : slot.z
          [Member.new(role, size, len, slot.x, 0.0, z, T, width, len)]
        else
          if slot.id.start_with?('HDR:')
            exp_len = slot.expected['length'].to_f
            cx = slot.x + exp_len / 2.0
            # Pieces installed one ply at a time; older form entries = full header
            plies = entry['pieces'] || Array.new(slot.plies || 2) { { 'size' => size, 'length' => len } }
            plies.each_with_index.map do |pc, i|
              pl = pc['length'].to_f
              ph = ACTUAL[pc['size']] || width
              if slot.anchor == :flat # 2x4s laid flat, stacked
                Member.new(role, pc['size'], pl, cx - pl / 2.0, 0.0, slot.z + i * T, pl, ph, T)
              else
                Member.new(role, pc['size'], pl, cx - pl / 2.0, i * T, slot.z, pl, T, ph)
              end
            end
          elsif slot.id.start_with?('SILL:')
            exp_len = slot.expected['length'].to_f
            cx = slot.x + exp_len / 2.0
            [Member.new(role, size, len, cx - len / 2.0, 0.0, slot.z, len, width, T)]
          elsif slot.id == 'TP:2' && entry['segs']
            # double top plate placed as a building step: lapped / broken at joints
            entry['segs'].map { |a, b| Member.new(role, size, b - a, a, 0.0, slot.z, b - a, width, T) }
          elsif plate?(slot)
            # plates: one member per piece (spliced plates show the joint); bottom plate cut out at doors
            cuts = slot.id == 'BP' ? door_cuts(w) : []
            plate_spans(w, entry).flat_map do |a0, b0|
              segs = [[a0, b0]]
              cuts.each do |ca, cb|
                segs = segs.flat_map { |a, b| cb <= a || ca >= b ? [[a, b]] : [[a, ca], [cb, b]].select { |x, y| y - x > 0.01 } }
              end
              segs.map { |a, b| Member.new(role, size, b0 - a0, a, 0.0, slot.z, b - a, width, T) }
            end
          else
            [Member.new(role, size, len, slot.x, 0.0, slot.z, len, width, T)]
          end
        end
      end

      PLATE_IDS = %w[BP TP:1].freeze
      STOCK_MAX = 192.0 # longest plate stock (16')

      def plate?(slot_or_id)
        PLATE_IDS.include?(slot_or_id.respond_to?(:id) ? slot_or_id.id : slot_or_id)
      end

      # Plate entry built from its pieces (laid from the layout end). 'full' once it reaches the wall end.
      def plate_entry(wall, role, pieces)
        total = pieces.sum { |pc| pc['length'].to_f }
        { 'role' => role, 'size' => pieces.first['size'], 'length' => total, 'pieces' => pieces,
          'full' => total >= wall['length'].to_f - 1.0 / 16 || wall['length'].to_f <= STOCK_MAX }
      end

      # Splice positions, measured from the layout end (the arrow).
      def plate_splices(entry)
        pcs = entry['pieces'] || []
        return [] if pcs.size < 2
        acc = 0.0
        pcs[0..-2].map { |pc| acc += pc['length'].to_f }
      end

      # [a, b] spans along the wall (from the start) for each plate piece.
      def plate_spans(wall, entry)
        len = wall['length'].to_f
        pcs = entry['pieces'] || [{ 'length' => entry['length'] }]
        acc = 0.0
        pcs.map do |pc|
          a = acc
          acc += pc['length'].to_f
          from_end?(wall) ? [len - acc, len - a] : [a, acc]
        end
      end

      def door_cuts(w)
        (w['openings'] || []).select { |o| o['type'] == 'Door' }
                             .map { |o| [o['x'].to_f, o['x'].to_f + o['width'].to_f] }.sort
      end

      # Local [x0, z0, x1, z1] box a slot occupies when framed correctly
      # (used only to hit-test the cursor - never shown as a length).
      def slot_box(slot)
        l = slot.expected['length'].to_f
        if slot.kind == :post
          return [slot.x, slot.z, slot.x + ACTUAL[slot.expected['size']].to_f, slot.z + l]
        end
        return [slot.x, slot.z, slot.x + l, slot.z + slot.expected['height'].to_f] if slot.kind == :backing
        if slot.kind == :vertical
          z0 = slot.anchor == :top ? slot.z - l : slot.z
          [slot.x, z0, slot.x + T, z0 + l]
        else
          h = if slot.id.start_with?('HDR:')
                slot.anchor == :flat ? 2 * T : (ACTUAL[slot.expected['size']] || 9.25) # 9.25 = RFI placeholder
              else
                T
              end
          [slot.x, slot.z, slot.x + l, slot.z + h]
        end
      end

      # Slot under wall-local point (x, z), or nil. Studs get a little extra
      # width so they're easy to hit.
      def slot_at(slots, x, z, pad = 1.0)
        # An exact hit beats a near miss; the pad only helps when nothing is hit.
        exact = slot_hits(slots, x, z, 0.0)
        return smallest(exact) unless exact.empty?
        smallest(slot_hits(slots, x, z, pad))
      end

      def smallest(hits)
        hits.min_by do |s|
          x0, z0, x1, z1 = slot_box(s)
          (x1 - x0) * (z1 - z0)
        end
      end

      def slot_hits(slots, x, z, pad)
        slots.select do |s|
          x0, z0, x1, z1 = slot_box(s)
          px = s.kind == :vertical ? pad : 0.0
          pz = s.kind == :vertical ? 0.0 : 0.5
          x >= x0 - px && x <= x1 + px && z >= z0 - pz && z <= z1 + pz
        end
      end

      # The correct members for a wall (answer key / auto cut list).
      def expected_members(wall, table = DEFAULT_HEADER_TABLE)
        slots(wall, table).flat_map do |s|
          ms = members_for_entry(wall, s, s.expected)
          s.id == 'BP' ? ms.first(1) : ms # one full-length plate, even if drawn cut out at doors
        end
      end

      # Ghost placeholder (layout mark) geometry for an unconfirmed slot.
      # Vertical: a thin tile at the anchor - shows WHERE, not how long.
      # Horizontal: a thin strip showing the run.
      def ghost_for(wall, slot)
        w = DEFAULT_WALL.merge(wall)
        d = depth(w)
        g = 0.375
        if slot.kind == :post
          y = slot.anchor == :out ? 0.0 : d - T
          return Member.new('Layout Mark', '', 0, slot.x, y, slot.z, ACTUAL[slot.expected['size']].to_f, T, g)
        end
        if slot.kind == :vertical
          z = slot.anchor == :top ? slot.z - g : slot.z
          Member.new('Layout Mark', '', 0, slot.x, 0.0, z, T, d, g)
        else
          Member.new('Layout Mark', '', 0, slot.x, 0.0, slot.z, slot.expected['length'].to_f, d, g)
        end
      end

      # ---------------- formatting ----------------

      # 92.625 -> 7' 8-5/8"
      def fmt_len(inches)
        neg = inches.to_f < 0
        sixteenths = (inches.to_f.abs * 16).round
        ft = sixteenths / 192
        rem = sixteenths % 192
        whole = rem / 16
        frac = rem % 16
        fs = ''
        if frac > 0
          g = frac.gcd(16)
          fs = "-#{frac / g}/#{16 / g}"
        end
        s = ft > 0 ? %(#{ft}' #{whole}#{fs}") : %(#{whole}#{fs}")
        neg ? "-#{s}" : s
      end

      # 92.625 -> 92-5/8"  (inches only, how precuts are named)
      def fmt_in(inches)
        sixteenths = (inches.to_f * 16).round
        whole = sixteenths / 16
        frac = sixteenths % 16
        return %(#{whole}") if frac.zero?
        g = frac.gcd(16)
        return %(#{frac / g}/#{16 / g}") if whole.zero?
        %(#{whole}-#{frac / g}/#{16 / g}")
      end

      # Parses what students type: 92 5/8, 92-5/8, 7' 8-5/8", 7'8.625, 92.625
      def parse_len(str)
        s = str.to_s.strip.downcase.tr('”“', '"').tr('’‘', "'")
        return nil if s.empty?
        ft = 0.0
        if s.include?("'")
          a, s = s.split("'", 2)
          ft = Float(a.strip)
          s = s.to_s
        end
        s = s.delete('"').strip.sub(/^-/, '').strip
        inch = 0.0
        unless s.empty?
          parts = s.split(/[\s-]+/)
          parts.each do |p|
            if p.include?('/')
              n, dd = p.split('/')
              inch += Float(n) / Float(dd)
            else
              inch += Float(p)
            end
          end
        end
        ft * 12 + inch
      rescue ArgumentError, TypeError, ZeroDivisionError
        nil
      end

      PRECUTS = { 92.625 => '92-5/8" precut', 104.625 => '104-5/8" precut',
                  116.625 => '116-5/8" precut' }.freeze

      def stock_for(len)
        PRECUTS.each { |l, label| return label if (len - l).abs < 0.01 }
        ft = [8, 10, 12, 14, 16, 18, 20].find { |f| f * 12 >= len - 0.001 }
        ft ? "#{ft}'" : 'Splice / order long'
      end

      # [size, length] => qty  (header plies count as separate pieces)
      def cut_list(members)
        h = Hash.new(0)
        members.each { |m| h[[m.nominal, r(m.length)]] += 1 }
        h
      end
    end
  end
end
