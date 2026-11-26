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

      ROLE_COLORS = {
        'Common Stud' => [235, 215, 175], 'King Stud' => [150, 190, 110],
        'Jack Stud' => [120, 170, 90], 'Cripple Stud' => [120, 160, 200],
        'Header' => [196, 150, 100], 'Rough Sill' => [100, 140, 190],
        'Bottom Plate' => [225, 200, 160], 'Top Plate' => [225, 200, 160],
        'Double Top Plate' => [210, 185, 145]
      }.freeze

      module_function

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
                       'length' => vec.length.to_f, 'openings' => [], 'entries' => {}, 'flags' => [])
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
        return nil unless Project.settings['jobsite_order']
        if slot.id == 'TP:2'
          return 'Double top plates go on after every wall stands - use Double top plates (top view) in the Framing panel.'
        end
        slots ||= work_slots(params)
        by = slots.to_h { |s| [s.id, s] }
        Inspector.gate(slot, params['entries'] || {}, by)
      end

      # ---------- guided stages ----------

      # 'plates' | 'openings' | 'units' | 'commons' | 'framed'
      def stage(p)
        e = p['entries'] || {}
        ws = work_slots(p)
        done = ->(phase) { ws.select { |s| s.phase == phase }.all? { |s| Inspector.slot_done?(s, e[s.id]) } }
        return 'plates' unless done.call('plates')
        return 'openings' unless p['openings_done']
        return 'units' unless done.call('opening')
        return 'commons' unless (p['marks'] || []).any? && done.call('commons')
        'framed'
      end

      # Next open slots the student can frame now (job-site order).
      def next_slots(p)
        ws = work_slots(p)
        by = ws.to_h { |s| [s.id, s] }
        e = p['entries'] || {}
        ws.reject { |s| s.id == 'TP:2' || Inspector.slot_done?(s, e[s.id]) }
          .select { |s| Inspector.gate(s, e, by).nil? }
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
        t = g.transformation
        { 'id' => p['id'], 'o' => [t.origin.x.to_f, t.origin.y.to_f], 'dir' => [t.xaxis.x.to_f, t.xaxis.y.to_f],
          'len' => p['length'].to_f, 'depth' => Framing.depth(p), 'elev' => t.origin.z.to_f, 'level' => p['level'] }
      end

      def level_walls(level)
        all_walls.select { |w| params_of(w)['level'] == level && params_of(w)['top_plates'].to_i == 2 }
      end

      def dtp_order
        Project.data['dtp_order'] || []
      end

      def dtp_context(level)
        ws = level_walls(level)
        shapes = ws.map { |w| wall_shape(w) }
        [ws, shapes, Joints.find(shapes)]
      end

      # Walls on this level that still have work before double plates. [] = ready.
      def dtp_blockers(level)
        return [] unless Project.settings['jobsite_order']
        level_walls(level).map do |w|
          p = params_of(w)
          e = p['entries'] || {}
          open = work_slots(p).reject { |s| s.id == 'TP:2' || Inspector.slot_done?(s, e[s.id]) }
          open.empty? ? nil : "#{p['id']} (#{open.size} open)"
        end.compact
      end

      # Re-cut every placed double plate on this level for the current order.
      def recompute_dtps(level)
        ws, shapes, joints = dtp_context(level)
        order = dtp_order
        ws.each do |w|
          p = params_of(w)
          e = (p['entries'] || {})['TP:2']
          next unless e && e['auto']
          sh = shapes.find { |x| x['id'] == p['id'] }
          segs = Joints.segments(sh, shapes, joints, order)
          e['segs'] = segs
          e['length'] = segs.sum { |a, b| b - a }
          p['entries']['TP:2'] = e
          set_params(w, p)
          rebuild(w)
        end
      end

      # Preview of the segments if this wall's double plate went on next.
      def dtp_preview(g)
        p = params_of(g)
        _ws, shapes, joints = dtp_context(p['level'])
        sh = shapes.find { |x| x['id'] == p['id'] }
        Joints.segments(sh, shapes, joints, dtp_order - [p['id']] + [p['id']])
      end

      # Returns error or nil
      def place_dtp(g)
        p = params_of(g)
        return "#{p['id']} has a single top plate." unless p['top_plates'].to_i == 2
        e = p['entries'] || {}
        return "#{p['id']} already has its double plate - right-click to take it off." if e['TP:2']
        blockers = dtp_blockers(p['level'])
        return "Stand every wall first. Still framing: #{blockers.join(', ')}." unless blockers.empty?
        segs = dtp_preview(g)
        kerf = (Project.settings['kerf'] || YardLogic::KERF).to_f
        pieces = err = nil
        Yard.change do |y|
          pieces, err = YardLogic.pull_for(y, p['stud'], segs.sum { |a, b| b - a }, kerf)
          pieces.each { |pc| YardLogic.install(y, pc['id']) } unless err
        end
        return err if err
        Project.update { |d| d['dtp_order'] = (d['dtp_order'] || []) - [p['id']] + [p['id']] }
        p = params_of(g)
        (p['entries'] ||= {})['TP:2'] = { 'role' => 'Double Top Plate', 'size' => p['stud'], 'length' => segs.sum { |a, b| b - a },
                                          'segs' => segs, 'auto' => true,
                                          'pieces' => pieces.map { |pc| { 'id' => pc['id'], 'size' => pc['size'], 'length' => pc['length'] } } }
        set_params(g, p)
        recompute_dtps(p['level'])
        nil
      end

      def remove_dtp(g)
        p = params_of(g)
        e = (p['entries'] || {})['TP:2']
        return nil unless e
        p['entries'].delete('TP:2')
        set_params(g, p)
        Yard.change { |y| (e['pieces'] || []).each { |pc| YardLogic.return_piece(y, pc) }; y['hand'] = nil }
        Project.update { |d| d['dtp_order'] = (d['dtp_order'] || []) - [p['id']] }
        rebuild(g)
        recompute_dtps(p['level'])
        e
      end

      def interlock(level)
        _ws, shapes, joints = dtp_context(level)
        Joints.check(shapes, joints, dtp_order)
      end

      # Expected members for the whole model, with ideal interlocked double plates.
      def expected_members_all
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
            return [nil, 'There is a stud nailed on that mark - right-click it to pull it first.']
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
          return "Header already has #{pcs.size} plies - right-click to pull one." if pcs.size >= slot.plies.to_i
          pcs += [pc]
          p['entries'][slot_id] = { 'role' => slot.expected['role'], 'size' => pcs.first['size'],
                                    'length' => pcs.first['length'], 'pieces' => pcs }
        else
          return 'Something is already nailed in there - right-click it to pull it.' if Inspector.complete?(e)
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
        if rest.empty?
          p['entries'].delete(slot_id)
        else
          p['entries'][slot_id] = e.merge('pieces' => rest, 'size' => rest.first['size'], 'length' => rest.first['length'])
        end
        touch(p, slot_id)
        set_params(group, p)
        rebuild(group)
        piece
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
        t = group.transformation
        o = t.origin.offset(t.xaxis, delta)
        group.transformation = Geom::Transformation.axes(o, t.xaxis, t.yaxis, t.zaxis)
        set_params(group, p)
        rebuild(group)
        []
      end

      def plan_dir(group)
        x = group.transformation.xaxis
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

      # Small arrow on top of the wall at the start end, pointing down the wall.
      def add_start_arrow(model, ents, params)
        z = params['height'].to_f + 0.25
        d = Framing.depth(params)
        pts = [[0, 0, z], [10, d / 2.0, z], [0, d, z]]
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
        t = group.transformation
        a = t.origin
        b = a.offset(t.xaxis, p['length'].to_f)
        [a, b]
      end

      def snapshot_wall(group)
        p = params_of(group)
        t = group.transformation
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
