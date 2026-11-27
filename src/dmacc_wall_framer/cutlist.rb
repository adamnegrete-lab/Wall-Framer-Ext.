# The wall's cut list: one table the student fills in (any order) from the
# plans and their own measurements. Each row goes into the wall as soon as
# the job-site order allows it; a row that has to wait says why. Changing a
# row pulls the old pieces (to the offcut pile) and nails the new ones.
module DMACC
  module WallFramer
    module CutList
      CORNERS = { 'single' => 'Single stud', 'L' => 'L-corner post' }.freeze
      BACKING = { 'ladder' => 'Ladder blocking', 'channel' => '3-stud channel' }.freeze
      OCS = %w[16 19.2 24].freeze
      STUDS = 'Corners + stud layout'

      module_function

      def applying?
        @applying
      end

      def store(p)
        p['cutlist'] ||= {}
      end

      # ---------- rows ----------

      # [{key, section, label, input, size?, slots}] in build order
      def defs(p, slots = nil)
        slots ||= Builder.work_slots(p)
        rows = []
        add = ->(key, sec, label, input, ids, extra = {}) { rows << { 'key' => key, 'section' => sec, 'label' => label, 'input' => input, 'slots' => ids }.merge(extra) }
        add.call('plate:BP', 'Plates', 'Bottom plate', 'lens', ['BP'], 'size' => true)
        add.call('plate:TP:1', 'Plates', 'Top plate', 'lens', ['TP:1'], 'size' => true)
        p['openings'].each do |o|
          mk = o['mark']
          sec = "#{mk} - #{o['type'].downcase}, header #{Framing.header_label(o)}"
          mine = slots.select { |s| s.opening == mk }
          ids = ->(&blk) { mine.select(&blk).map(&:id) }
          add.call("king:#{mk}", sec, 'King studs', 'len', ids.call { |s| s.expected['role'] == 'King Stud' }, 'size' => true, 'opening' => mk)
          add.call("jack:#{mk}", sec, 'Jack studs', 'len', ids.call { |s| s.expected['role'] == 'Jack Stud' }, 'size' => true, 'opening' => mk)
          hdr = ids.call { |s| s.expected['role'] == 'Header' }
          plies = o['plies'].to_i
          add.call("header:#{mk}", sec, plies > 1 ? "Header (#{plies} plies, cut the same)" : 'Header', 'len', hdr, 'opening' => mk,
                                                                                                         'fixed' => Framing.header_label(o))
          if o['type'] == 'Window'
            add.call("sill:#{mk}", sec, 'Rough sill', 'len', ids.call { |s| s.expected['role'] == 'Rough Sill' }, 'size' => true, 'opening' => mk)
            add.call("under:#{mk}", sec, 'Cripples under the sill', 'len',
                     ids.call { |s| s.phase == 'cripples' && s.anchor == :bottom }, 'size' => true, 'opening' => mk, 'layout' => true)
          end
          add.call("above:#{mk}", sec, 'Header blocks (cripples above)', 'len',
                   ids.call { |s| s.phase == 'cripples' && s.anchor == :top }, 'size' => true, 'opening' => mk, 'layout' => true)
        end
        add.call('corner:start', STUDS, 'Corner at the layout start', 'corner', slots.select { |s| s.phase == 'commons' && corner_slot?(s, 'start') }.map(&:id))
        add.call('corner:end', STUDS, 'Corner at the opposite end', 'corner', slots.select { |s| s.phase == 'commons' && corner_slot?(s, 'end') }.map(&:id))
        add.call('oc', STUDS, 'Stud spacing (on center)', 'oc', [])
        add.call('common', STUDS, 'Common studs (also end studs + corner post pieces)', 'len',
                 slots.select { |s| s.phase == 'commons' && s.kind != :backing }.map(&:id), 'size' => true)
        (p['tee_need'] || []).each do |t|
          add.call("tee:#{t['id']}", STUDS, "Backing where #{t['id']} tees in", 'backing', ["TEE:#{t['id']}"])
        end
        rows
      end

      def corner_slot?(s, end_name)
        return s.id == "LPOST:#{end_name}" if s.kind == :post
        s.label.start_with?(end_name == 'start' ? 'Wall start' : 'Wall end')
      end

      # Which row a slot belongs to (for clicks in the model).
      def row_for(p, slot_id, corners: true)
        return 'plate:BP' if slot_id == 'BP'
        return 'plate:TP:1' if slot_id == 'TP:1'
        d = defs(p)
        d = d.reject { |r| r['key'].start_with?('corner:') } unless corners
        (d.find { |r| r['key'].start_with?('corner:') && r['slots'].include?(slot_id) } ||
          d.find { |r| r['slots'].include?(slot_id) })&.fetch('key')
      end

      # Rows with the student's values and where each one stands.
      def rows(p)
        slots = Builder.work_slots(p)
        by = slots.to_h { |s| [s.id, s] }
        e = p['entries'] || {}
        st = store(p)
        defs(p, slots).map do |r|
          v = st[r['key']] || {}
          r = r.merge('value' => v['v'].to_s, 'size_val' => v['size'] || p['stud'])
          r.merge(status(p, r, v, by, e))
        end
      end

      def status(p, r, v, by, e)
        key = r['key']
        case r['input']
        when 'corner'
          end_name = key.split(':').last
          return { 'state' => 'todo', 'note' => '' } if v['v'].to_s.empty?
          done = r['slots'].any? && r['slots'].all? { |id| Inspector.slot_done?(by[id], e[id]) }
          return { 'state' => 'placed', 'note' => 'In.' } if done
          st = store(p)
          other = end_name == 'start' ? 'end' : 'start'
          why = if !(st["corner:#{other}"] || {})['v'] then "pick the #{other == 'end' ? 'opposite end' : 'layout start'} corner too"
                elsif !(st['oc'] || {})['v'] then 'pick the stud spacing'
                elsif !(st['common'] || {})['v'] then 'type the common stud length'
                elsif !p['openings_done'] then 'enter the openings above first'
                else 'finish the openings first'
                end
          return { 'state' => 'waiting', 'note' => "Goes in with the common studs - #{why}." }
        when 'oc'
          return { 'state' => 'todo', 'note' => '' } if v['v'].to_s.empty?
          return { 'state' => 'placed', 'note' => 'Laid out from the layout start.' } if p['oc']
          return { 'state' => 'waiting', 'note' => 'Enter the openings above first - the layout skips over them.' } unless p['openings_done']
          return { 'state' => 'waiting', 'note' => 'Pick both corners - then the layout goes on the plates.' }
        end
        installed = r['slots'].map { |id| e[id] && Inspector.complete?(e[id]) ? pieces_text(e[id]) : nil }.compact
        have = r['slots'].count { |id| by[id] && Inspector.slot_done?(by[id], e[id]) }
        if v['v'].to_s.empty?
          return { 'state' => installed.any? ? 'placed' : 'todo', 'note' => installed.any? ? "In: #{installed.uniq.join(', ')}" : '' }
        end
        if v['err']
          return { 'state' => 'error', 'note' => v['err'] }
        end
        if r['slots'].empty?
          if r['layout'] && !p['oc']
            return { 'state' => 'waiting', 'note' => 'Lands on your stud layout - fill in the stud spacing and the studs go in first.' }
          end
          return { 'state' => 'none', 'note' => r['layout'] ? 'None on this layout.' : 'Nothing to place yet.' }
        end
        if have == r['slots'].size
          return { 'state' => 'placed', 'note' => r['slots'].size > 1 ? "All #{have} in." : 'In.' }
        end
        if r['input'] == 'lens' && (en = e[r['slots'].first]) && en['full'] == false
          return { 'state' => 'short', 'note' => "Short of the wall end - #{Framing.fmt_len(p['length'].to_f - (en['pieces'] || []).sum { |x| x['length'].to_f })} " \
                                                 'still to go. Splice in the next piece (comma between pieces).' }
        end
        why = r['slots'].map { |id| by[id] && !Inspector.slot_done?(by[id], e[id]) ? Builder.gate_reason(p, by[id]) : nil }.compact.first
        if key == 'common' && !p['oc']
          st = store(p)
          why = if !p['openings_done'] then 'Waits for the openings - enter them above (or No openings in this wall).'
                elsif !(st['corner:start'] || {})['v'] || !(st['corner:end'] || {})['v'] then 'Pick both corners first.'
                else 'Pick the stud spacing first.'
                end
        end
        { 'state' => 'waiting', 'note' => (have.positive? ? "#{have} of #{r['slots'].size} in. " : '') + (why || 'Waiting.') }
      end

      # Every row the student has to fill has a value (rows with nothing to place don't count).
      def all_filled?(rows)
        rows.all? { |r| !r['value'].to_s.empty? || r['state'] == 'none' || (r['slots'].empty? && %w[len lens].include?(r['input'])) }
      end

      def pieces_text(en)
        pcs = en['pieces'] || [en]
        return "#{pcs.size} x #{en['size']} x #{Framing.fmt_len(en['length'])}" if pcs.size > 1 && pcs.map { |x| x['length'].to_f.round(3) }.uniq.size == 1
        pcs.map { |x| "#{x['size']} x #{Framing.fmt_len(x['length'])}" }.join(' + ')
      end

      # ---------- setting a row ----------

      # Stores the student's value and places what it can. Returns an error
      # message for a value that can't be read, else nil.
      def set(group, key, text, size = nil)
        p = Builder.params_of(group)
        text = text.to_s.strip
        r = defs(p).find { |x| x['key'] == key } or return 'That row is gone - the wall changed.'
        val = { 'v' => text }
        val['size'] = size if size && !size.to_s.empty?
        unless text.empty?
          case r['input']
          when 'lens'
            lens = parse_list(text)
            return "Couldn't read \"#{text}\". Type each piece, a comma between: 16', 4' 1-1/2\"" unless lens
            if lens.any? { |l| l > Framing::STOCK_MAX + 1e-6 }
              return "Longest plate stock is 16'. Splice it: first piece from the arrow end with the splice centered on a stud, " \
                     "then a comma and the rest (like 12' 8\", 7' 4\")."
            end
          when 'len'
            l = Framing.parse_len(text)
            return "Couldn't read \"#{text}\". Try 92 5/8 or 7' 8-5/8\"." unless l && l > 0
          when 'oc'
            return 'Pick 16, 19.2 or 24.' unless OCS.include?(text)
          when 'corner'
            return 'Pick a corner.' unless CORNERS.key?(text)
          when 'backing'
            return 'Pick the backing.' unless BACKING.key?(text)
          end
        end
        p = Builder.params_of(group)
        st = store(p)
        if text.empty? then st.delete(key) else st[key] = val end
        Builder.set_params(group, p)
        clear_row(group, r) if text.empty?
        apply(group)
        nil
      end

      def parse_list(text)
        parts = text.split(/[,+;]/).map(&:strip).reject(&:empty?)
        lens = parts.map { |s| Framing.parse_len(s) }
        return nil if lens.empty? || lens.any? { |l| l.nil? || l <= 0 }
        lens
      end

      # A row emptied: its pieces come out.
      def clear_row(group, r)
        case r['input']
        when 'corner'
          p = Builder.params_of(group)
          (p['corners'] || {}).delete(r['key'].split(':').last)
          Builder.set_params(group, p)
        when 'oc'
          pull_layout(group)
          p = Builder.params_of(group)
          p.delete('oc')
          p['marks'] = []
          Builder.set_params(group, p)
        else
          @applying = true
          r['slots'].each { |id| pull(group, id) }
          @applying = false
        end
        orphans(group)
      end

      # ---------- placing ----------

      # Bring the wall in line with its cut list. Runs until nothing more can go in.
      def apply(group)
        Builder.deferring_rebuilds { apply_now(group) }
      end

      def apply_now(group)
        @applying = true
        6.times do
          layout(group)
          orphans(group)
          moved = false
          p = Builder.params_of(group)
          st = store(p)
          defs(p).each do |r|
            v = st[r['key']]
            next unless v && !v['v'].to_s.empty?
            moved |= apply_row(group, r, v)
          end
          break unless moved
        end
        Builder.rebuild(group)
      ensure
        @applying = false
      end

      # corners + O.C. -> p['corners'], p['oc'], layout marks
      def layout(group)
        p = Builder.params_of(group)
        st = store(p)
        corners = (p['corners'] || {}).dup
        %w[start end].each do |en|
          v = st["corner:#{en}"] && st["corner:#{en}"]['v']
          corners[en] = v if CORNERS.key?(v)
        end
        if corners != (p['corners'] || {})
          p['corners'] = corners
          Builder.set_params(group, p)
        end
        oc = st['oc'] && st['oc']['v']
        if oc && OCS.include?(oc) && corners['start'] && corners['end'] && p['openings_done']
          if p['oc'] && (p['oc'].to_f - oc.to_f).abs > 1e-6
            pull_layout(group)
            p = Builder.params_of(group)
          end
          p['oc'] = oc.to_f
          p['marks'] = Framing.auto_marks(p, oc)
          Builder.set_params(group, p)
        end
      end

      # Commons, cripples and backing come out (a new stud layout).
      def pull_layout(group)
        p = Builder.params_of(group)
        was = @applying
        @applying = true
        Builder.work_slots(p).select { |s| %w[commons cripples].include?(s.phase) || s.kind == :backing }.each { |s| pull(group, s.id) }
      ensure
        @applying = was
      end

      # Pieces left on spots that aren't there anymore (an opening moved, a corner changed).
      def orphans(group)
        p = Builder.params_of(group)
        by = Builder.work_slots(p).to_h { |s| [s.id, s] }
        (p['entries'] || {}).each do |id, e|
          next if id == 'TP:2'
          s = by[id]
          # gone, or the spot is a different piece now (a common that ended up under a new window)
          pull(group, id) if s.nil? || (e['role'] && s.kind != :backing && e['role'] != s.expected['role'])
        end
      end

      # Every piece out of a slot, onto the offcut pile.
      def pull(group, id)
        p = Builder.params_of(group)
        e = (p['entries'] || {})[id] or return
        p['entries'].delete(id)
        Builder.set_params(group, p)
        pcs = e['auto'] ? (e['pieces'] || []) : (e['pieces'] || [e])
        Yard.change do |y|
          pcs.each { |pc| y['offcuts'] << { 'id' => YardLogic.new_id(y, 'O'), 'size' => pc['size'], 'length' => pc['length'].to_f } if pc['size'] }
        end
      end

      # true if anything changed
      def apply_row(group, r, v)
        moved = false
        err = nil
        return false if v['err'] # a value that didn't go in waits for the student to change it
        p = Builder.params_of(group)
        case r['input']
        when 'backing'
          id = r['slots'].first
          slot = Builder.work_slots(p).find { |s| s.id == id } or return false
          cur = (p['entries'] || {})[id]
          return false if cur && cur['kind'] == v['v']
          return false if Builder.gate_reason(p, slot)
          pull(group, id) if cur
          err = Builder.install_tee(group, id.sub('TEE:', ''), v['v'])
          moved = err.nil?
        when 'len', 'lens'
          return false if r['key'] == 'common' && !p['oc'] # studs go in with the layout
          want_lens = r['input'] == 'lens' ? parse_list(v['v']) : [Framing.parse_len(v['v'])]
          return false unless want_lens
          by = Builder.work_slots(p).to_h { |s| [s.id, s] }
          r['slots'].each do |id|
            slot = by[id] or next
            p = Builder.params_of(group)
            size = r['fixed'] ? slot.expected['size'] : (v['size'] || p['stud'])
            want = if r['input'] == 'lens' then want_lens.map { |l| [size, l] }
                   else Array.new(slot.id.start_with?('HDR:') ? [slot.plies.to_i, 1].max : 1) { [size, want_lens.first] }
                   end
            cur = (e = (p['entries'] || {})[id]) ? (e['pieces'] || [e]).map { |x| [x['size'], x['length'].to_f] } : []
            next if same?(cur, want)
            next if Builder.gate_reason(p, slot)
            pull(group, id) unless cur.empty?
            want.each do |sz, l|
              err = Builder.nail_supplied(group, slot, sz, l)
              break if err
            end
            moved = true
            break if err
          end
        end
        p = Builder.params_of(group)
        st = store(p)
        if st[r['key']]
          if err then st[r['key']]['err'] = err else st[r['key']].delete('err') end
          Builder.set_params(group, p)
        end
        moved && err.nil?
      end

      def same?(a, b)
        a.size == b.size && a.zip(b).all? { |(s1, l1), (s2, l2)| s1 == s2 && (l1 - l2).abs < 1.0 / 64 }
      end

      # The Demo tool pulled a piece: its row empties so the table matches the wall.
      def forget(p, slot_id)
        return if applying?
        st = p['cutlist'] or return
        key = row_for(p, slot_id, corners: false) or return
        st.delete(key)
      end
    end
  end
end
