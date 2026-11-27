require 'json'

module DMACC
  module WallFramer
    # Turns wall data into SketchUp geometry. Every wall is a group that
    # carries its data (ID, level, type, openings, student entries); every
    # member is a component instance that carries its own data too.
    module Builder
      DICT = 'dmacc_wall_framer'.freeze
      TAG_FRAMING = 'Framing'.freeze
      TAG_MARKS = 'Framing - Layout Marks'.freeze
      TAG_LABELS = 'Framing - Wall Labels'.freeze

      ROLE_COLORS = {
        'Common Stud' => [235, 215, 175], 'King Stud' => [150, 190, 110],
        'Jack Stud' => [120, 170, 90], 'Cripple Stud' => [120, 160, 200],
        'Header' => [196, 150, 100], 'Rough Sill' => [100, 140, 190],
        'Bottom Plate' => [225, 200, 160], 'Top Plate' => [225, 200, 160],
        'Double Top Plate' => [210, 185, 145]
      }.freeze

      module_function

      # ---------- editing context ----------

      # If a student double-clicked into a wall (or anything), SketchUp reports
      # positions relative to that open group. Framing tools work from the
      # model level, so close any open group first.
      def close_edits
        m = Sketchup.active_model
        10.times do
          break if m.active_path.nil? || m.active_path.empty?
          m.close_active
        end
        # A locked wall that's selected draws red - framing tools start with nothing selected
        m.selection.clear if m.selection.respond_to?(:clear)
      rescue StandardError
        nil
      end

      def lock(group)
        group.locked = true if group.respond_to?(:locked=)
      end

      # ---------- framing table: frame it flat beside the house, then stand it up ----------

      # Where the wall belongs (its chalk line). A wall out on the framing table keeps its
      # home in its params; everything about the plan (corners, tees, spans, grading) reads this.
      def home(g)
        h = params_of(g)['home']
        return g.transformation unless h
        x = Geom::Vector3d.new(*h['x'])
        Geom::Transformation.axes(Geom::Point3d.new(*h['o']), x, Z_AXIS * x, Z_AXIS)
      end

      def on_table?(g)
        !!params_of(g)['home']
      end

      def table_walls
        all_walls.select { |w| on_table?(w) }
      end

      # Lying flat beside the house, outside face up, bottom plate toward the viewer.
      def table_transform(g)
        p = params_of(g)
        pts = all_walls.reject { |w| w == g }.flat_map { |w| endpoints(w) }
        pts += endpoints(g)
        xmax = pts.map { |pt| pt.x.to_f }.max || 0.0
        ymin = pts.map { |pt| pt.y.to_f }.min || 0.0
        elev = home(g).origin.z.to_f
        o = Geom::Point3d.new(xmax + 120, ymin, elev + Framing.depth(p))
        Geom::Transformation.axes(o, Geom::Vector3d.new(1, 0, 0), Geom::Vector3d.new(0, 0, -1), Geom::Vector3d.new(0, 1, 0))
      end

      def move_group(g, t)
        g.locked = false if g.respond_to?(:locked=)
        g.transformation = t
        lock(g)
      end

      # Take a wall to the framing table (any other unframed wall there goes back to its line).
      def lay_down(g)
        return if on_table?(g)
        table_walls.each { |w| stand_up(w) }
        t = g.transformation
        p = params_of(g)
        p['home'] = { 'o' => t.origin.to_a.map(&:to_f), 'x' => t.xaxis.to_a.map(&:to_f) }
        set_params(g, p)
        move_group(g, table_transform(g))
      end

      # Raise it and set it on its chalk line.
      def stand_up(g)
        return unless on_table?(g)
        t = home(g)
        p = params_of(g)
        p.delete('home')
        set_params(g, p)
        move_group(g, t)
      end

      # ---------- finding walls ----------

      def wall?(ent)
        return false unless ent.is_a?(Sketchup::Group) && !ent.deleted?
        raw = ent.get_attribute(DICT, 'params')
        !raw.nil? && raw.include?('"id"') # v0.1 walls (no id) are ignored
      end

      def params_of(group)
        JSON.parse(group.get_attribute(DICT, 'params'))
      end

      def set_params(group, params)
        group.set_attribute(DICT, 'params', JSON.generate(params))
      end

      def selected_walls
        Sketchup.active_model.selection.select { |e| wall?(e) }
      end

      def all_walls
        Sketchup.active_model.entities.select { |e| wall?(e) }
      end

      def find_wall(id)
        all_walls.find { |w| params_of(w)['id'] == id }
      end

      # Copying a wall with the Move tool duplicates its ID. Give copies new IDs.
      def ensure_unique_ids
        seen = {}
        all_walls.each do |w|
          p = params_of(w)
          if seen[p['id']]
            p['id'] = Project.next_wall_id(p['level'])
            set_params(w, p)
            w.name = "#{p['id']} - #{p['type']} - #{p['level']}"
          end
          seen[p['id']] = true
        end
      end

      # ---------- type / level snapshots ----------

      TYPE_KEYS = %w[stud spacing height top_plates function bearing].freeze

      def apply_type(params, type)
        TYPE_KEYS.each { |k| params[k] = type[k] }
        params['type'] = type['name']
        params
      end

      # ---------- creating ----------

      def create_wall(pt1, pt2, level_name, type_name)
        model = Sketchup.active_model
        level = Project.level(level_name)
        type = Project.wall_type(type_name)
        return nil unless level && type
        elev = level['elev'].to_f
        a = Geom::Point3d.new(pt1.x, pt1.y, elev)
        b = Geom::Point3d.new(pt2.x, pt2.y, elev)
        vec = b - a
        return nil if vec.length < 12

        params = apply_type({}, type)
        params.merge!('id' => Project.next_wall_id(level_name), 'level' => level_name,
                       'length' => vec.length.to_f, 'openings' => [], 'entries' => {}, 'flags' => [],
                       'layout' => { 'p1' => [a.x.to_f, a.y.to_f], 'p2' => [b.x.to_f, b.y.to_f] }, 's0' => 0.0)
        xaxis = vec.normalize
        yaxis = Z_AXIS * xaxis # wall body sits LEFT of the pick direction
        group = model.entities.add_group
        group.transformation = Geom::Transformation.axes(a, xaxis, yaxis, Z_AXIS)
        set_params(group, params)
        rebuild(group)
        group
      end

      # ---------- installing pieces (carpentry mode) ----------

      # Slots the student works with in this model (student layout setting).
      def work_slots(params)
        Framing.work_slots(params, Project.header_table, Project.settings['student_layout'])
      end

      def slot_by_id(params, id)
        work_slots(params).find { |s| s.id == id }
      end

      # nil = can be framed now; otherwise the job-site reason it can't.
      def gate_reason(params, slot, slots = nil)
        # An opening waiting on an RFI is on hold - nothing in it gets framed yet
        if slot.opening && (op = params['openings'].find { |o| o['mark'] == slot.opening }) && op['header'] == Framing::RFI && !op['rfi']
          return "#{slot.opening} is on hold - your RFI isn't submitted yet. Click any #{slot.opening} spot to write it."
        end
        if slot.opening && (op = params['openings'].find { |o| o['mark'] == slot.opening }) && op['header'] == Framing::RFI && op['rfi_new']
          return "RFI ##{op['rfi_new']} is answered - click #{slot.opening} to read it and update the opening."
        end
        if slot.opening && (op = params['openings'].find { |o| o['mark'] == slot.opening }) && op['header'] == Framing::RFI
          return "#{slot.opening} is on hold - waiting on the answer to RFI ##{op['rfi']} (header size). Frame another opening or wall in the meantime."
        end
        return nil unless Project.settings['jobsite_order']
        if slot.id == 'TP:2'
          return 'Double top plates go on after every wall stands - use Double top plates (top view) in the Framing panel.'
        end
        slots ||= work_slots(params)
        by = slots.to_h { |s| [s.id, s] }
        e = params['entries'] || {}
        if slot.phase == 'cripples' && slots.any? { |s| s.phase == 'commons' && !Inspector.slot_done?(s, e[s.id]) }
          return 'Lay out and frame the studs first - cripples and header blocks follow your stud layout.'
        end
        if slot.kind == :backing && !params['oc']
          return 'Lay out and frame the studs first - the backing goes in with the studs.'
        end
        Inspector.gate(slot, e, by)
      end

      # ---------- plan corners (runs through / butts) ----------

      def layout_of(w)
        p = params_of(w)
        return p['layout'] if p['layout']
        a, b = endpoints(w) # walls from older versions: their current line
        { 'p1' => [a.x.to_f, a.y.to_f], 'p2' => [b.x.to_f, b.y.to_f] }
      end

      def plan_input(level)
        all_walls.select { |w| params_of(w)['level'] == level }.map do |w|
          p = params_of(w)
          l = layout_of(w)
          { 'id' => p['id'], 'p1' => l['p1'], 'p2' => l['p2'], 'depth' => Framing.depth(p), 'run' => p['run'] }
        end
      end

      # [ {id=>{'s','e'}}, corners ] for a level
      def plan_corners(level)
        Corners.resolve(plan_input(level))
      end

      def framed?(p)
        (p['entries'] || {}).any? || (p['marks'] || []).any?
      end

      # Walls whose length would change if this wall's run setting changed.
      def affected_by_run(group, run)
        p = params_of(group)
        input = plan_input(p['level'])
        before, = Corners.resolve(input)
        after, = Corners.resolve(input.map { |x| x['id'] == p['id'] ? x.merge('run' => run) : x })
        after.keys.reject { |id| after[id] == before[id] }
      end

      def set_run(group, run)
        p = params_of(group)
        p['run'] = run
        set_params(group, p)
        resolve_layout(p['level'])
      end

      # Trim / extend every wall on a level from its layout line and the corners.
      # A wall whose length changes after framing started has its framing reset.
      def resolve_layout(level)
        out, = plan_corners(level)
        all_walls.select { |w| params_of(w)['level'] == level }.each do |w|
          p = params_of(w)
          r = out[p['id']] or next
          l = layout_of(w)
          s = r['s']
          len = r['e'] - s
          next if (len - p['length'].to_f).abs < 1e-6 && (s - p['s0'].to_f).abs < 1e-6 && p['layout']
          delta = s - p['s0'].to_f
          a = Geom::Point3d.new(l['p1'][0], l['p1'][1], home(w).origin.z)
          u = Geom::Vector3d.new(l['p2'][0] - l['p1'][0], l['p2'][1] - l['p1'][1], 0)
          u.normalize!
          o = a.offset(u, s)
          if p['home'] # out on the framing table: its chalk line moves, the wall stays put
            p['home'] = { 'o' => o.to_a.map(&:to_f), 'x' => u.to_a.map(&:to_f) }
          else
            w.transformation = Geom::Transformation.axes(o, u, Z_AXIS * u, Z_AXIS)
          end
          p['layout'] = l
          p['s0'] = s
          p['length'] = len
          p['openings'] = p['openings'].map { |op| op.merge('x' => op['x'].to_f - delta) }
          if framed?(p)
            pulled = (p['entries'] || {}).values.flat_map { |e| e['pieces'] || [] }
            Yard.change { |y| pulled.each { |pc| y['offcuts'] << { 'id' => YardLogic.new_id(y, 'O'), 'size' => pc['size'], 'length' => pc['length'].to_f } } }
            %w[marks pencil corners oc last_inspection].each { |k| p.delete(k) }
            p['entries'] = {}
            p['flags'] = []
            forget_dtp([p['id']])
          end
          set_params(w, p)
          rebuild(w)
        end
        refresh_corner_needs(level)
      end

      # Corners on this wall that still need a decision (unset / conflict).
      def open_corners(p)
        _out, corners = plan_corners(p['level'])
        corners.select { |c| c['walls'].include?(p['id']) && %w[unset conflict].include?(c['status']) }
      end

      # ---------- corners ----------

      # What each end of each wall needs, from how the walls actually meet:
      # another wall butting into this end -> L-corner post (on that side);
      # this wall butting into another, or a free end -> single end stud.
      def refresh_corner_needs(level = nil)
        levels = level ? [level] : all_walls.map { |w| params_of(w)['level'] }.uniq
        levels.each do |lv|
          ws = all_walls.select { |w| params_of(w)['level'] == lv }
          shapes = ws.map { |w| wall_shape(w) }
          joints = Joints.find(shapes)
          ws.each do |w|
            p = params_of(w)
            sh = shapes.find { |x| x['id'] == p['id'] }
            need = { 'start' => { 'type' => 'single' }, 'end' => { 'type' => 'single' } }
            joints.each do |j|
              next unless j['through'] == p['id'] && j['kind'] == 'corner'
              end_name = j['a0'] <= sh['depth'] + 0.5 ? 'start' : 'end'
              other = shapes.find { |x| x['id'] == j['butt'] }
              # which face of this wall the other wall sits against
              mid = Joints.at(other, j['end'] == 'start' ? 0.0 : other['len'], other['depth'] / 2.0)
              side = Joints.local(sh, mid)[1] > sh['depth'] / 2.0 ? 'in' : 'out'
              need[end_name] = { 'type' => 'L', 'side' => side, 'by' => j['butt'] }
            end
            tees = []
            joints.each do |j|
              next unless j['through'] == p['id'] && j['kind'] == 'tee'
              other = shapes.find { |x| x['id'] == j['butt'] }
              mid = Joints.at(other, j['end'] == 'start' ? 0.0 : other['len'], other['depth'] / 2.0)
              side = Joints.local(sh, mid)[1] > sh['depth'] / 2.0 ? 'in' : 'out'
              tees << { 'id' => j['butt'], 'a0' => j['a0'].round(4), 'a1' => j['a1'].round(4), 'side' => side }
            end
            next if p['corner_need'] == need && (p['tee_need'] || []) == tees
            p['corner_need'] = need
            p['tee_need'] = tees
            set_params(w, p)
          end
        end
      end

      # ---------- partition backing at tees ----------

      # kind: 'ladder' (flat blocks between the studs either side, at the
      # instructor's spacing) or 'channel' (two studs flanking the partition).
      def install_tee(group, tee_id, kind)
        p = params_of(group)
        slot = work_slots(p).find { |s| s.id == "TEE:#{tee_id}" } or return 'That tee is gone.'
        why = gate_reason(p, slot)
        return why if why
        t = (p['tee_need'] || []).find { |x| x['id'] == tee_id }
        d = Framing.depth(p)
        size = p['stud']
        w = Framing::ACTUAL[size]
        tt = Framing::T
        sl = Framing.stud_length(p)
        a0 = t['a0'].to_f
        a1 = t['a1'].to_f
        stud = ->(x) { { 'role' => 'Backing Stud', 'size' => size, 'length' => sl, 'x' => x, 'y' => 0.0, 'z' => tt, 'dx' => tt, 'dy' => d, 'dz' => sl } }
        geom = []
        if kind == 'channel'
          geom << stud.call(a0 - tt) << stud.call(a1)
        else
          # studs already in the wall on each side of the partition
          xs = work_slots(p).select { |s| s.kind == :vertical && s.anchor == :bottom && Inspector.slot_done?(s, (p['entries'] || {})[s.id]) }
                            .map(&:x)
          left = xs.select { |x| x + tt <= a0 + 0.01 }.max
          right = xs.select { |x| x >= a1 - 0.01 }.min
          if left.nil? || a0 - (left + tt) > 24
            geom << stud.call(a0 - tt)
            left = a0 - tt
          end
          if right.nil? || right - a1 > 24
            geom << stud.call(a1)
            right = a1
          end
          x0 = left + tt
          len = right - x0
          y = t['side'] == 'out' ? 0.0 : d - tt
          oc = (Project.settings['ladder_oc'] || 24).to_f
          z = tt + oc - w / 2.0
          while z + w < tt + sl - 1
            geom << { 'role' => 'Ladder Block', 'size' => size, 'length' => len, 'x' => x0, 'y' => y, 'z' => z, 'dx' => len, 'dy' => tt, 'dz' => w }
            z += oc
          end
        end
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        pieces = []
        geom.each do |g|
          pc = err = nil
          Yard.change { |y| y['hand'] = nil; pc, err = YardLogic.supply(y, g['size'], g['length'], kerf); YardLogic.install(y, pc['id']) if pc }
          return err if err
          pieces << { 'id' => pc['id'], 'size' => pc['size'], 'length' => pc['length'] }
        end
        p = params_of(group)
        (p['entries'] ||= {})[slot.id] = { 'role' => 'Partition Backing', 'size' => size, 'length' => geom.sum { |g| g['length'] },
                                           'auto' => true, 'kind' => kind, 'geom' => geom, 'pieces' => pieces }
        touch(p, slot.id)
        set_params(group, p)
        rebuild(group)
        nil
      end

      # Corners chosen + O.C. chosen -> lay out and nail every common, end stud
      # and corner post with precuts from the yard. Returns error or nil.
      def auto_frame_commons(group)
        p = params_of(group)
        p['marks'] = Framing.auto_marks(p, p['oc'])
        set_params(group, p)
        rebuild(group)
        work_slots(params_of(group)).select { |s| s.phase == 'commons' && s.kind != :backing }.each do |s|
          next if Inspector.slot_done?(s, (params_of(group)['entries'] || {})[s.id])
          err = nail_supplied(group, s, s.expected['size'], s.expected['length'])
          return err if err
        end
        nil
      end

      # Pull every common / end stud / corner post and clear the layout.
      def reset_commons(group)
        p = params_of(group)
        e = p['entries'] || {}
        pulled = []
        work_slots(p).select { |s| %w[commons cripples].include?(s.phase) }.each do |s|
          next unless e[s.id]
          (e[s.id]['pieces'] || [e[s.id]]).each { |pc| pulled << pc }
          e.delete(s.id)
        end
        p['entries'] = e
        p['marks'] = []
        p.delete('corners')
        p.delete('oc')
        (p['cutlist'] || {}).reject! { |k, _| k =~ /\A(corner:|oc\z|common\z|under:|above:|tee:)/ }
        p['last_inspection'] = nil
        p['flags'] = []
        set_params(group, p)
        Yard.change do |y|
          pulled.each { |pc| y['offcuts'] << { 'id' => YardLogic.new_id(y, 'O'), 'size' => pc['size'], 'length' => pc['length'].to_f } }
        end
        rebuild(group)
      end

      # Pull the stud layout from the other end of the wall (so studs line up
      # with the wall across the house). Framed studs + cripples come out.
      def set_layout_from(group, from_end)
        p = params_of(group)
        return if Framing.from_end?(p) == from_end
        keep = p['cutlist'] && JSON.parse(JSON.generate(p['cutlist']))
        reset_commons(group) if p['oc'] || (p['marks'] || []).any?
        p = params_of(group)
        if from_end then p['layout_from'] = 'end' else p.delete('layout_from') end
        p['cutlist'] = keep if keep
        set_params(group, p)
        rebuild(group)
        CutList.apply(group) if keep && keep.any?
      end

      # ---------- guided stages ----------

      # 'plates' | 'openings' | 'units' | 'commons' | 'framed'
      def stage(p)
        e = p['entries'] || {}
        ws = work_slots(p)
        done = ->(phase) { ws.select { |s| s.phase == phase }.all? { |s| Inspector.slot_done?(s, e[s.id]) } }
        return 'corners' if !p['entries']&.any? && open_corners(p).any?
        return 'plates' unless done.call('plates')
        return 'openings' unless p['openings_done']
        return 'units' unless done.call('opening')
        return 'commons' unless p['oc'] && done.call('commons')
        return 'cripples' unless done.call('cripples')
        'framed'
      end

      # Next open slots the student can frame now (job-site order).
      def next_slots(p)
        ws = work_slots(p)
        by = ws.to_h { |s| [s.id, s] }
        e = p['entries'] || {}
        ws.reject { |s| s.id == 'TP:2' || Inspector.slot_done?(s, e[s.id]) }
          .select { |s| Inspector.gate(s, e, by).nil? }
          .select { |s| gate_reason(p, s, ws).nil? }
      end

      # Nail pieces (supplied from the yard) into a slot. Returns error or nil.
      def nail_supplied(group, slot, size, len, count = 1)
        p = params_of(group)
        why = gate_reason(p, slot)
        return why if why
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        count.times do
          pc = err = nil
          Yard.change { |y| y['hand'] = nil; pc, err = YardLogic.supply(y, size, len, kerf) }
          return err if err
          err = install_piece(group, slot.id, pc)
          if err
            Yard.change { |y| y['hand'] = nil } # piece stays on the cart
            return err
          end
          Yard.change { |y| YardLogic.install(y, pc['id']) }
        end
        nil
      end

      def set_flag(group, key, val)
        p = params_of(group)
        p[key] = val
        set_params(group, p)
      end

      # ---------- double top plates (building step) ----------

      def wall_shape(g)
        p = params_of(g)
        t = home(g)
        { 'id' => p['id'], 'o' => [t.origin.x.to_f, t.origin.y.to_f], 'dir' => [t.xaxis.x.to_f, t.xaxis.y.to_f],
          'len' => p['length'].to_f, 'depth' => Framing.depth(p), 'elev' => t.origin.z.to_f, 'level' => p['level'] }
      end

      def level_walls(level)
        all_walls.select { |w| params_of(w)['level'] == level && params_of(w)['top_plates'].to_i == 2 }
      end

      # Placing order, one record per piece: { 'wall', 'x', 'len', 'pieces' }.
      def dtp_seq
        d = Project.data
        return d['dtp_seq'] if d['dtp_seq']
        seq = [] # models from older versions: one record per old segment
        (d['dtp_order'] || []).each do |id|
          g = find_wall(id) or next
          e = (params_of(g)['entries'] || {})['TP:2'] or next
          (e['segs'] || []).each_with_index do |(a, b), i|
            seq << { 'wall' => id, 'x' => (a + b) / 2.0, 'len' => b - a, 'pieces' => i.zero? ? (e['pieces'] || []) : [] }
          end
        end
        Project.update { |dd| dd['dtp_seq'] = seq }
        seq
      end

      # Wall ids in the order their first double plate piece went on.
      def dtp_order
        dtp_seq.map { |r| r['wall'] }.uniq.select { |id| find_wall(id) }
      end

      # Walls deleted or reset: their double plate records go too.
      def forget_dtp(ids)
        Project.update do |d|
          d['dtp_order'] = (d['dtp_order'] || []) - ids
          d['dtp_seq'] = (d['dtp_seq'] || []).reject { |r| ids.include?(r['wall']) }
        end
      end

      # Walls to click in double plate mode: the lowest level that still has double
      # plates to set (on a 2-story model the upper walls sit right on top of them).
      def dtp_level_walls
        lv = all_walls.map { |w| params_of(w)['level'] }.uniq.sort_by { |l| (Project.level(l) || {})['elev'].to_f }
                      .find { |l| level_walls(l).any? { |w| dtp_free(w).any? } }
        lv ? all_walls.select { |w| params_of(w)['level'] == lv } : all_walls
      end

      def dtp_context(level)
        ws = level_walls(level)
        shapes = ws.map { |w| wall_shape(w) }
        [ws, shapes, Joints.find(shapes)]
      end

      def dtp_spans(level)
        _ws, shapes, joints = dtp_context(level)
        Joints.replay(shapes, joints, dtp_seq)
      end

      # Walls on this level that still have work before double plates. [] = ready.
      def dtp_blockers(level)
        return [] unless Project.settings['jobsite_order']
        level_walls(level).map do |w|
          p = params_of(w)
          e = p['entries'] || {}
          open = work_slots(p).reject { |s| s.id == 'TP:2' || Inspector.slot_done?(s, e[s.id]) }
          next "#{p['id']} (#{open.size} open)" unless open.empty?
          on_table?(w) ? "#{p['id']} (still on the framing table - stand it up)" : nil
        end.compact
      end

      # Re-cut every double plate piece on this level for the current order and
      # write them onto the walls. Pieces that changed length get re-cut from the yard.
      def recompute_dtps(level)
        ws, shapes, joints = dtp_context(level)
        seq = dtp_seq.map(&:dup)
        spans, bad = Joints.replay(shapes, joints, seq)
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        # records that no longer fit: their boards go back
        unless bad.empty?
          Yard.change { |y| bad.each { |i| (seq[i]['pieces'] || []).each { |pc| YardLogic.return_piece(y, pc) } }; y['hand'] = nil }
          seq = seq.each_with_index.reject { |_r, i| bad.include?(i) }.map(&:first)
          spans, = Joints.replay(shapes, joints, seq)
        end
        spans.each_value do |list|
          list.each do |sp|
            rec = seq[sp['i']]
            len = sp['b'] - sp['a']
            next if rec['len'] && (rec['len'].to_f - len).abs < 0.01
            wp = ws.map { |w| params_of(w) }.find { |p| p['id'] == rec['wall'] }
            if rec['cuts']
              last = len - rec['cuts'][0..-2].sum
              rec['cuts'] = last.positive? && last <= Framing::STOCK_MAX ? rec['cuts'][0..-2] + [last] : nil
            end
            Yard.change { |y| (rec['pieces'] || []).each { |pc| YardLogic.return_piece(y, pc) }; y['hand'] = nil }
            pcs, = supply_cuts(wp, rec['cuts'], len)
            rec['pieces'] = pcs
            rec['len'] = len
          end
        end
        Project.update { |d| d['dtp_seq'] = seq }
        ws.each do |w|
          p = params_of(w)
          list = (spans[p['id']] || []).sort_by { |sp| sp['a'] }
          sh = shapes.find { |x| x['id'] == p['id'] }
          old = (p['entries'] || {})['TP:2']
          if list.empty?
            next unless old
            p['entries'].delete('TP:2')
          else
            (p['entries'] ||= {})['TP:2'] = {
              'role' => 'Double Top Plate', 'size' => p['stud'], 'auto' => true,
              'length' => list.sum { |sp| sp['b'] - sp['a'] },
              'segs' => list.flat_map { |sp| split_at(sp, dtp_splice_xs(p, sp, seq[sp['i']]['cuts'])) },
              'nums' => list.map { |sp| sp['n'] },
              'full' => Joints.free(sh, joints, spans).empty?,
              'pieces' => list.flat_map { |sp| seq[sp['i']]['pieces'] || [] }
            }
          end
          set_params(w, p)
          rebuild(w)
        end
      end

      def split_at(sp, xs)
        pts = ([sp['a']] + xs.sort + [sp['b']])
        pts.each_cons(2).map { |a, b| [a.round(4), b.round(4)] }
      end

      # The piece a click at local x would set on this wall, or nil.
      def dtp_preview(g, x = nil)
        p = params_of(g)
        _ws, shapes, joints = dtp_context(p['level'])
        spans, = Joints.replay(shapes, joints, dtp_seq)
        sh = shapes.find { |s| s['id'] == p['id'] } or return nil
        Joints.region(sh, shapes.to_h { |s| [s['id'], s] }, joints, spans, (x || p['length'].to_f / 2).to_f)
      end

      # Open pieces left on a wall: [[a, b], ...]
      def dtp_free(g)
        p = params_of(g)
        _ws, shapes, joints = dtp_context(p['level'])
        spans, = Joints.replay(shapes, joints, dtp_seq)
        sh = shapes.find { |s| s['id'] == p['id'] } or return []
        Joints.free(sh, joints, spans)
      end

      # The placed piece under local x on this wall: { 'a','b','n','i' } or nil.
      def dtp_piece_at(g, x)
        p = params_of(g)
        spans, = dtp_spans(p['level'])
        (spans[p['id']] || []).find { |sp| x >= sp['a'] - 0.5 && x <= sp['b'] + 0.5 }
      end

      # Set the double plate piece under local x. Returns error or nil.
      # Stud centers along a wall (from the wall start): its layout + every stud in it.
      def stud_centers(p)
        sp = (p['oc'] || p['spacing']).to_f
        len = p['length'].to_f
        lay = []
        k = 0
        while sp.positive? && k * sp <= len + 0.01
          lay << Framing.layout_dist(p, k * sp) # layout_dist flips back to wall-x
          k += 1
        end
        lay + work_slots(p).select { |s| s.kind == :vertical }.map { |s| s.x + Framing::T / 2.0 }
      end

      # Wall-x of each splice in a double plate piece, laid from the arrow-end side of [a, b].
      def dtp_splice_xs(p, sp, cuts)
        return [] if cuts.nil? || cuts.size < 2
        acc = 0.0
        cuts[0..-2].map do |c|
          acc += c.to_f
          Framing.from_end?(p) ? sp['b'] - acc : sp['a'] + acc
        end
      end

      # nil = good; otherwise the hint for the student.
      def dtp_splice_problem(g, sp, cuts)
        p = params_of(g)
        return "Every piece has to come out of 16' stock." if cuts.any? { |c| c.to_f > Framing::STOCK_MAX + 1e-6 || c.to_f <= 0 }
        studs = stud_centers(p)
        tp = Framing.plate_splices((p['entries'] || {})['TP:1'] || {}).map { |d| Framing.layout_dist(p, d) }
        dtp_splice_xs(p, sp, cuts).each do |x|
          unless studs.any? { |c| (c - x).abs <= 1.0 / 8 }
            near = studs.min_by { |c| (c - x).abs }
            return "That splice lands at #{Framing.fmt_len(Framing.layout_dist(p, x))} from the arrow end - it isn't centered on a stud. " \
                   "Double plate splices land in the middle of a stud, same as the plates#{near ? " (closest stud center: #{Framing.fmt_len(Framing.layout_dist(p, near))})" : ''}."
          end
          close = tp.find { |t| (t - x).abs < 24 - 1e-6 }
          next unless close
          gap = (close - x).abs
          where = gap < 1.0 / 8 ? 'lands right over the top plate splice below it' : "is only #{Framing.fmt_len(gap)} from the top plate splice below it"
          return "That splice #{where}. " \
                 "Double plate splices have to be at least 24\" from any top plate splice so the two plates lock together."
        end
        nil
      end

      # Pieces of stock for a double plate run (cuts = piece lengths from the arrow-end side).
      def supply_cuts(p, cuts, len)
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        pieces = []
        err = nil
        Yard.change do |y|
          y['hand'] = nil
          if cuts && cuts.size > 1
            cuts.each do |c|
              pc, err = YardLogic.supply(y, p['stud'], c.to_f, kerf)
              break if err
              YardLogic.install(y, pc['id'])
              pieces << pc
            end
          else
            pieces, err = YardLogic.pull_for(y, p['stud'], len, kerf)
            pieces.each { |pc| YardLogic.install(y, pc['id']) } unless err
          end
        end
        [pieces.map { |pc| { 'id' => pc['id'], 'size' => pc['size'], 'length' => pc['length'] } }, err]
      end

      # Set the double plate piece under local x. Runs over 16' need cuts (piece lengths). Returns error or nil.
      def place_dtp(g, x = nil, cuts = nil)
        p = params_of(g)
        return "#{p['id']} has a single top plate." unless p['top_plates'].to_i == 2
        blockers = dtp_blockers(p['level'])
        return "Stand every wall first. Still framing: #{blockers.join(', ')}." unless blockers.empty?
        x = (x || p['length'].to_f / 2).to_f
        sp = dtp_preview(g, x)
        return "That part of #{p['id']} already has its double plate - click a piece to take it off." unless sp
        len = sp['b'] - sp['a']
        if len > Framing::STOCK_MAX + 1e-6
          return 'SPLICE' unless cuts && cuts.size > 1
          cuts = cuts.map(&:to_f)
          return "The pieces add up to #{Framing.fmt_len(cuts.sum)} - this run is #{Framing.fmt_len(len)}." if (cuts.sum - len).abs > 1.0 / 16
          why = dtp_splice_problem(g, sp, cuts)
          return why if why
        else
          cuts = nil
        end
        pieces, err = supply_cuts(p, cuts, len)
        return err if err
        rec = { 'wall' => p['id'], 'x' => x, 'len' => len, 'pieces' => pieces }
        rec['cuts'] = cuts if cuts
        seq = dtp_seq
        Project.update { |d| d['dtp_seq'] = seq + [rec]; d['dtp_order'] = ((d['dtp_order'] || []) - [p['id']]) + [p['id']] }
        recompute_dtps(p['level'])
        nil
      end

      # Take off the piece under local x (whole wall's plate when x is nil). Returns its record or nil.
      def remove_dtp(g, x = nil)
        p = params_of(g)
        spans, = dtp_spans(p['level'])
        list = spans[p['id']] || []
        hit = x ? list.select { |sp| x >= sp['a'] - 0.5 && x <= sp['b'] + 0.5 } : list
        return nil if hit.empty?
        seq = dtp_seq
        idx = hit.map { |sp| sp['i'] }
        recs = idx.map { |i| seq[i] }
        Yard.change { |y| recs.each { |r| (r['pieces'] || []).each { |pc| YardLogic.return_piece(y, pc) } }; y['hand'] = nil }
        Project.update { |d| d['dtp_seq'] = seq.each_with_index.reject { |_r, i| idx.include?(i) }.map(&:first) }
        recompute_dtps(p['level'])
        recs.first.merge('n' => hit.first['n'])
      end

      def interlock(level)
        _ws, shapes, joints = dtp_context(level)
        spans, = Joints.replay(shapes, joints, dtp_seq)
        Joints.check_spans(shapes, joints, spans)
      end

      # Expected members for the whole model, with ideal interlocked double plates.
      def expected_members_all
        refresh_corner_needs
        table = Project.header_table
        all_walls.flat_map do |w|
          p = params_of(w)
          ms = Framing.expected_members(p, table).reject { |m| m.type == 'Double Top Plate' }
          if p['top_plates'].to_i == 2
            _ws, shapes, joints = dtp_context(p['level'])
            sh = shapes.find { |x| x['id'] == p['id'] }
            Joints.segments(sh, shapes, joints, [], ideal: true).each do |a, b|
              ms << Framing::Member.new('Double Top Plate', p['stud'], b - a, a, 0, 0, b - a, 0, 0)
            end
          end
          ms
        end
      end

      # ---------- student layout marks ----------

      # Pencil marks: where the student pulled the tape to, on the plate.
      def add_pencil(group, x)
        p = params_of(group)
        x = (x.to_f * 16).round / 16.0
        return [nil, 'That is off the end of the plate.'] if x <= 0 || x >= p['length'].to_f
        marks = (p['pencil'] || []).map(&:to_f)
        return ["There's already a pencil mark at #{Framing.fmt_len(x)}.", nil] if marks.any? { |m| (m - x).abs < 1e-6 }
        p['pencil'] = (marks + [x]).sort
        set_params(group, p)
        rebuild(group)
        ["Pencil mark at #{Framing.fmt_len(x)}.", nil]
      end

      def remove_pencil(group, x)
        p = params_of(group)
        p['pencil'] = (p['pencil'] || []).map(&:to_f).reject { |m| (m - x).abs < 1e-6 }
        set_params(group, p)
        rebuild(group)
      end

      # Add (or remove, if one is already there) a common-stud layout mark.
      # Returns [message, error]
      def toggle_mark(group, x)
        p = params_of(group)
        marks = (p['marks'] || []).map(&:to_f)
        hit = marks.find { |m| (m - x).abs <= 1.0 }
        if hit
          ms = Framing.mark_slot(p, hit, [])
          if Inspector.complete?((p['entries'] || {})[ms.id])
            return [nil, 'There is a stud nailed on that mark - pull it with the Demo tool first.']
          end
          p['marks'] = marks - [hit]
          set_params(group, p)
          rebuild(group)
          return ["Removed the mark at #{Framing.fmt_len(hit)}.", nil]
        end
        len = p['length'].to_f
        return [nil, 'That is past the end of the plate.'] if x < 0 || x > len - Framing::T + 0.01
        zone = Framing.opening_zones(p).find { |a, b, _| x + Framing::T > a + 0.01 && x < b - 0.01 }
        return [nil, "That's inside #{zone[2]} - the opening unit has its own studs and cripples."] if zone
        if x < Framing::T || x > len - 2 * Framing::T
          return [nil, 'End studs are already part of the plate layout.']
        end
        xs = Framing.snap_mark(p, x)
        p['marks'] = (marks + [xs]).sort
        set_params(group, p)
        rebuild(group)
        ["Marked a stud at #{Framing.fmt_len(xs)}.", nil]
      end

      # A slot's stored entry is now out of date: clear its red flag and its
      # line in the last inspection (like editing a field on a form).
      def touch(p, slot_id)
        p['flags'] = (p['flags'] || []) - [slot_id]
        li = p['last_inspection']
        li['issues'] = li['issues'].reject { |i| i['slot_id'] == slot_id } if li
      end

      # Nail a piece into a slot. Returns nil or an error message.
      def install_piece(group, slot_id, piece)
        p = params_of(group)
        slot = slot_by_id(p, slot_id) or return 'That layout mark is gone.'
        why = gate_reason(p, slot)
        return why if why
        e = (p['entries'] ||= {})[slot_id]
        pc = { 'id' => piece['id'], 'size' => piece['size'], 'length' => piece['length'].to_f }
        if slot.id.start_with?('HDR:')
          pcs = e && e['pieces'] ? e['pieces'] : []
          return "Header already has #{pcs.size} plies - pull one with the Demo tool." if pcs.size >= slot.plies.to_i
          pcs += [pc]
          p['entries'][slot_id] = { 'role' => slot.expected['role'], 'size' => pcs.first['size'],
                                    'length' => pcs.first['length'], 'pieces' => pcs }
        elsif Framing.plate?(slot)
          # plates over 16' are spliced: pieces go on from the layout end until the plate reaches the wall end
          pcs = e && e['pieces'] ? e['pieces'] : []
          return 'That plate is already on - pull it with the Demo tool.' if e && e['full'] != false && Inspector.complete?(e)
          return "Longest plate stock is 16' - cut it shorter and splice." if pc['length'] > Framing::STOCK_MAX + 1e-6
          left = p['length'].to_f - pcs.sum { |x| x['length'].to_f }
          return "That's longer than what's left of the plate (#{Framing.fmt_len(left)})." if pcs.any? && pc['length'] > left + 1.0 / 16
          p['entries'][slot_id] = Framing.plate_entry(p, slot.expected['role'], pcs + [pc])
        else
          return 'Something is already nailed in there - pull it with the Demo tool.' if Inspector.complete?(e)
          p['entries'][slot_id] = { 'role' => slot.expected['role'], 'size' => pc['size'],
                                    'length' => pc['length'], 'pieces' => [pc] }
        end
        touch(p, slot_id)
        set_params(group, p)
        rebuild(group)
        nil
      end

      # Pry a piece out (last ply for headers). Returns the piece or nil.
      def remove_piece(group, slot_id)
        p = params_of(group)
        e = (p['entries'] || {})[slot_id]
        return nil unless e
        pcs = e['pieces'] || [{ 'size' => e['size'], 'length' => e['length'] }]
        piece = pcs.last
        rest = pcs[0..-2]
        CutList.forget(p, slot_id)
        if rest.empty?
          p['entries'].delete(slot_id)
        elsif Framing.plate?(slot_id)
          p['entries'][slot_id] = Framing.plate_entry(p, e['role'], rest).merge('full' => false)
        else
          p['entries'][slot_id] = e.merge('pieces' => rest, 'size' => rest.first['size'], 'length' => rest.first['length'])
        end
        touch(p, slot_id)
        set_params(group, p)
        rebuild(group)
        piece
      end

      # Partition backing comes out as a set (every block/stud). Returns the pieces.
      def remove_backing(group, slot_id)
        p = params_of(group)
        e = (p['entries'] || {})[slot_id]
        return [] unless e
        CutList.forget(p, slot_id)
        p['entries'].delete(slot_id)
        touch(p, slot_id)
        set_params(group, p)
        rebuild(group)
        e['pieces'] || []
      end

      # ---------- corner trims (chained walls) ----------

      # Change length at the END of a wall. Returns error list (empty = done).
      def extend_end(group, delta)
        p = params_of(group)
        p['length'] = p['length'].to_f + delta
        errs = Framing.validate(p, Project.header_table)
        return errs unless errs.empty?
        set_params(group, p)
        rebuild(group)
        []
      end

      # Move a wall's START along its length (delta > 0 = shorter).
      # Openings keep their place in the building.
      def shift_start(group, delta)
        p = params_of(group)
        p['length'] = p['length'].to_f - delta
        p['openings'] = p['openings'].map { |o| o.merge('x' => o['x'].to_f - delta) }
        p['entries'] = {} unless delta.zero? # layout moved - start framing over
        p['flags'] = []
        p['last_inspection'] = nil
        errs = Framing.validate(p, Project.header_table)
        return errs unless errs.empty?
        t = home(group)
        o = t.origin.offset(t.xaxis, delta)
        if p['home']
          p['home'] = { 'o' => o.to_a.map(&:to_f), 'x' => t.xaxis.to_a.map(&:to_f) }
        else
          group.transformation = Geom::Transformation.axes(o, t.xaxis, t.yaxis, t.zaxis)
        end
        set_params(group, p)
        rebuild(group)
        []
      end

      def plan_dir(group)
        x = home(group).xaxis
        [x.x.to_f, x.y.to_f]
      end

      # ---------- rebuilding ----------

      def rebuild(group)
        model = Sketchup.active_model
        params = params_of(group)
        table = Project.header_table
        show_marks = Project.settings['show_layout_marks']
        flags = params['flags'] || []
        entries = params['entries'] || {}

        group.make_unique if group.respond_to?(:make_unique)
        group.entities.clear!
        group.name = "#{params['id']} - #{params['type']} - #{params['level']}"
        group.layer = level_tag(model, params['level'])

        slots = work_slots(params)
        by = slots.to_h { |s| [s.id, s] }
        order = Project.settings['jobsite_order']
        slots.each do |slot|
          e = entries[slot.id]
          if Inspector.complete?(e)
            Framing.members_for_entry(params, slot, e).each do |m|
              place(model, group.entities, m, params, slot, flags.include?(slot.id))
            end
          elsif show_marks && (!order || (slot.id != 'TP:2' && Inspector.gate(slot, entries, by).nil?))
            place_ghost(model, group.entities, Framing.ghost_for(params, slot), slot)
          end
        end
        add_chalk_lines(model, group.entities, params)
        add_plate_marks(model, group.entities, params) if Inspector.complete?(entries['BP'])
        add_start_arrow(model, group.entities, params)
        add_wall_label(model, group.entities, params)
        lock(group) # can't be opened or nudged by accident; Tape Measure still snaps to it
        group
      end

      # Chalk line outline of the wall on the deck - measure this for plate length.
      def add_chalk_lines(model, ents, params)
        len = params['length'].to_f
        d = Framing.depth(params)
        pts = [[0, 0, 0], [len, 0, 0], [len, d, 0], [0, d, 0]].map { |c| Geom::Point3d.new(*c) }
        tg = tag(model, TAG_MARKS)
        4.times { |i| ents.add_line(pts[i], pts[(i + 1) % 4]).tap { |e| e.layer = tg if e } }
      end

      # Marks on top of the bottom plate: opening centerlines (CL) and the
      # student's common-stud layout marks (X), as real edges Tape Measure can snap to.
      def add_plate_marks(model, ents, params)
        d = Framing.depth(params)
        z = Framing::T + 0.02
        tg = tag(model, TAG_MARKS)
        line = lambda do |a, b|
          e = ents.add_line(Geom::Point3d.new(*a), Geom::Point3d.new(*b))
          e.layer = tg if e
        end
        (params['openings'] || []).each do |o|
          cx = o['x'].to_f + o['width'].to_f / 2.0
          line.call([cx, 0, z], [cx, d, z])
          t = ents.add_text("#{o['mark']} CL", Geom::Point3d.new(cx, 0, z))
          t.layer = tg if t.respond_to?(:layer=)
        end
        (params['pencil'] || []).each do |m|
          x = m.to_f
          line.call([x, 0, z], [x, d * 0.6, z])                 # pencil tick
          line.call([x - 0.4, 0, z], [x, 0.9, z])               # little V pointing at it
          line.call([x + 0.4, 0, z], [x, 0.9, z])
        end
        (params['marks'] || []).each do |m|
          x = m.to_f
          line.call([x, 0, z], [x, d, z])
          line.call([x + Framing::T, 0, z], [x + Framing::T, d, z])
          line.call([x, 0, z], [x + Framing::T, d, z])
          line.call([x + Framing::T, 0, z], [x, d, z])
        end
      end

      def rebuild_all(filter = nil)
        all_walls.each do |w|
          next if filter && !filter.call(params_of(w))
          rebuild(w)
        end
      end

      # Wall type edited -> every wall of that type updates (BIM: change once, update everywhere).
      def sync_type(type)
        all_walls.each do |w|
          p = params_of(w)
          next unless p['type'] == type['name']
          set_params(w, apply_type(p, type))
          rebuild(w)
        end
      end

      # Level elevation edited -> every wall hosted on it moves.
      def sync_level(level)
        all_walls.each do |w|
          p = params_of(w)
          next unless p['level'] == level['name']
          stand_up(w) if on_table?(w)
          o = w.transformation.origin
          w.transform!(Geom::Transformation.translation([0, 0, level['elev'].to_f - o.z]))
        end
      end

      # ---------- geometry helpers ----------

      def level_tag(model, name)
        model.layers[name] || model.layers.add(name)
      end

      def tag(model, name)
        model.layers[name] || model.layers.add(name)
      end

      def material(model, name, rgb, alpha = 1.0)
        mat = model.materials[name]
        unless mat
          mat = model.materials.add(name)
          mat.color = Sketchup::Color.new(*rgb)
          mat.alpha = alpha if alpha < 1.0
        end
        mat
      end

      def role_material(model, role)
        material(model, "Framing - #{role}", ROLE_COLORS[role] || [235, 215, 175])
      end

      def box_definition(model, name, key, dx, dy, dz)
        defn = model.definitions.find { |d| d.get_attribute(DICT, 'key') == key }
        return defn if defn

        defn = model.definitions.add(name)
        defn.set_attribute(DICT, 'key', key)
        face = defn.entities.add_face([0, 0, 0], [dx, 0, 0], [dx, dy, 0], [0, dy, 0])
        face.reverse! if face.normal.z < 0
        face.pushpull(dz)
        defn
      end

      def place(model, ents, m, params, slot, flagged)
        len_s = Framing.fmt_len(m.length)
        name = "#{m.nominal} #{m.type} #{len_s}"
        key = format('M|%s|%.4f|%.4f|%.4f', name, m.dx, m.dy, m.dz)
        defn = box_definition(model, name, key, m.dx, m.dy, m.dz)
        defn.set_attribute(DICT, 'role', m.type)
        defn.set_attribute(DICT, 'size', m.nominal)
        defn.set_attribute(DICT, 'length', m.length)

        inst = ents.add_instance(defn, Geom::Transformation.translation([m.x, m.y, m.z]))
        inst.name = "#{params['id']} | #{m.type} | #{m.nominal} x #{len_s}"
        inst.layer = tag(model, TAG_FRAMING)
        inst.material = flagged ? material(model, 'Framing - FLAGGED', [220, 40, 40]) : role_material(model, m.type)
        { 'slot' => slot.id, 'role' => m.type, 'size' => m.nominal, 'length' => m.length,
          'wall' => params['id'], 'level' => params['level'], 'wall_type' => params['type'],
          'location' => slot.label, 'status' => flagged ? 'Flagged' : 'Installed' }.each do |k, v|
          inst.set_attribute(DICT, k, v)
        end
        inst
      end

      def place_ghost(model, ents, g, slot)
        key = format('G|%.4f|%.4f|%.4f', g.dx, g.dy, g.dz)
        defn = box_definition(model, 'Layout Mark', key, g.dx, g.dy, g.dz)
        inst = ents.add_instance(defn, Geom::Transformation.translation([g.x, g.y, g.z]))
        inst.name = "Layout mark - #{slot.label}"
        inst.layer = tag(model, TAG_MARKS)
        inst.material = material(model, 'Framing - Layout Mark', [128, 128, 128], 0.45)
        inst.set_attribute(DICT, 'slot', slot.id)
        inst.set_attribute(DICT, 'status', 'Not confirmed')
        inst
      end

      # The wall's ID floating above the middle of the wall (its own tag, so it can be hidden).
      def add_wall_label(model, ents, params)
        t = ents.add_text(params['id'].to_s, Geom::Point3d.new(params['length'].to_f / 2.0, Framing.depth(params) / 2.0, params['height'].to_f + 12))
        return unless t
        t.layer = tag(model, TAG_LABELS) if t.respond_to?(:layer=)
        t.set_attribute(DICT, 'wall_label', true) if t.respond_to?(:set_attribute)
      end

      # Small arrow on top of the wall at the layout end (where the tape hooks), pointing down the wall.
      def add_start_arrow(model, ents, params)
        z = params['height'].to_f + 0.25
        d = Framing.depth(params)
        len = params['length'].to_f
        pts = Framing.from_end?(params) ? [[len, 0, z], [len - 10, d / 2.0, z], [len, d, z]] : [[0, 0, z], [10, d / 2.0, z], [0, d, z]]
        f = ents.add_face(pts)
        f.reverse! if f.normal.z < 0
        f.material = material(model, 'Framing - Start Arrow', [40, 40, 40])
        f.back_material = f.material
        f.edges.each { |e| e.layer = tag(model, TAG_MARKS) }
        f.layer = tag(model, TAG_MARKS)
      end

      # ---------- highlight a slot ----------

      def highlight(group, slot_id)
        model = Sketchup.active_model
        hl = material(model, 'Framing - HIGHLIGHT', [255, 220, 0])
        group.entities.grep(Sketchup::ComponentInstance).each do |i|
          next unless i.get_attribute(DICT, 'slot') == slot_id
          i.material = hl
        end
        model.selection.clear
        model.selection.add(group)
        model.active_view.zoom(group)
      end

      # ---------- snapshot for answer key / grading ----------

      def endpoints(group)
        p = params_of(group)
        t = home(group)
        a = t.origin
        b = a.offset(t.xaxis, p['length'].to_f)
        [a, b]
      end

      # Another level framed on top of this wall's level? (header carries a floor + wall)
      def floor_above?(group)
        p = params_of(group)
        lv = Project.level(p['level'])
        elev = lv ? lv['elev'].to_f : home(group).origin.z.to_f
        all_walls.any? do |w|
          q = params_of(w)
          next false if q['level'] == p['level']
          ql = Project.level(q['level'])
          (ql ? ql['elev'].to_f : home(w).origin.z.to_f) > elev + 12
        end
      end

      # Span of the roof/floor framing this wall carries: the house's width
      # across the wall (outside of the walls on this level, perpendicular to it).
      def building_span(group)
        p = params_of(group)
        t = home(group)
        ax = t.xaxis
        n = [-ax.y.to_f, ax.x.to_f] # across the wall, in plan
        vals = all_walls.select { |w| params_of(w)['level'] == p['level'] }.flat_map do |w|
          a, b = endpoints(w)
          d = Framing.depth(params_of(w))
          wt = home(w)
          off = [-wt.xaxis.y.to_f * d, wt.xaxis.x.to_f * d]
          [a, b].flat_map { |pt| [[pt.x.to_f, pt.y.to_f], [pt.x.to_f + off[0], pt.y.to_f + off[1]]] }
        end.map { |x, y| x * n[0] + y * n[1] }
        vals.empty? ? 0.0 : vals.max - vals.min
      end

      def snapshot_wall(group)
        p = params_of(group)
        t = home(group)
        a, b = endpoints(group)
        table = Project.header_table
        {
          'id' => p['id'], 'level' => p['level'], 'type' => p['type'],
          'p1' => [a.x.to_f, a.y.to_f], 'p2' => [b.x.to_f, b.y.to_f],
          'openings' => p['openings'].map do |o|
            c = a.offset(t.xaxis, o['x'].to_f + o['width'].to_f / 2.0)
            o.merge('center' => [c.x.to_f, c.y.to_f], 'header_size' => Framing.header_for(o, table))
          end
        }
      end
    end
  end
end
