# Pure-Ruby answer-key comparison. A "snapshot" describes a model:
# {
#   'walls' => [{ 'id','level','type','p1'=>[x,y],'p2'=>[x,y],
#                 'openings' => [{ 'mark','type','width','height','sill','header','center'=>[x,y] }] }],
#   'framing' => { wall_id => {'correct','total'} },     # student only
#   'takeoff' => { 'score' => 87.5 } or nil,               # student only
#   'log' => [ {...inspection attempts...} ]               # student only
# }
module DMACC
  module WallFramer
    module AnswerKey
      WALL_TOL = 3.0     # wall endpoints within 3" = same wall
      OPENING_TOL = 1.0  # opening location within 1"
      SIZE_TOL = 1.0 / 16

      module_function

      def dist(a, b)
        Math.sqrt((a[0] - b[0])**2 + (a[1] - b[1])**2)
      end

      def same_wall?(k, s)
        (dist(k['p1'], s['p1']) <= WALL_TOL && dist(k['p2'], s['p2']) <= WALL_TOL) ||
          (dist(k['p1'], s['p2']) <= WALL_TOL && dist(k['p2'], s['p1']) <= WALL_TOL)
      end

      def pct(a, b)
        b.zero? ? 100.0 : (100.0 * a / b).round(1)
      end

      def compare(key, student)
        notes = []
        s_walls = student['walls'].dup
        wall_pts = 0
        wall_max = 0
        pairs = []

        key['walls'].each do |kw|
          wall_max += 3 # found, level, type
          sw = s_walls.find { |w| same_wall?(kw, w) }
          if sw.nil?
            notes << { 'area' => 'Walls', 'ok' => false, 'text' => "Missing wall: key #{kw['id']} (#{kw['type']}, #{kw['level']}, #{Framing.fmt_len(dist(kw['p1'], kw['p2']))} long)." }
            next
          end
          s_walls.delete(sw)
          pairs << [kw, sw]
          wall_pts += 1
          if kw['level'] == sw['level'] then wall_pts += 1
          else notes << { 'area' => 'Walls', 'ok' => false, 'text' => "#{sw['id']}: on #{sw['level']}, key has #{kw['level']}." }
          end
          if kw['type'] == sw['type'] then wall_pts += 1
          else notes << { 'area' => 'Walls', 'ok' => false, 'text' => "#{sw['id']}: wall type #{sw['type']}, key has #{kw['type']}." }
          end
        end
        s_walls.each do |w|
          notes << { 'area' => 'Walls', 'ok' => false, 'text' => "Extra wall not in the key: #{w['id']}." }
          wall_max += 1
        end

        # Openings - by mark, anywhere in the model
        k_ops = key['walls'].flat_map { |w| (w['openings'] || []).map { |o| o.merge('wall' => w['id']) } }
        s_ops = student['walls'].flat_map { |w| (w['openings'] || []).map { |o| o.merge('wall' => w['id']) } }
        op_pts = 0
        op_max = 0
        k_ops.each do |ko|
          op_max += 5 # found, location, width, height, sill/header
          so = s_ops.find { |o| o['mark'].to_s.upcase == ko['mark'].to_s.upcase }
          if so.nil?
            notes << { 'area' => 'Openings', 'ok' => false, 'text' => "Missing opening #{ko['mark']} (#{ko['type']})." }
            next
          end
          s_ops.delete(so)
          op_pts += 1
          checks = []
          if dist(ko['center'], so['center']) <= OPENING_TOL then op_pts += 1
          else checks << "located #{Framing.fmt_len(dist(ko['center'], so['center']))} off"
          end
          if (ko['width'] - so['width']).abs <= SIZE_TOL then op_pts += 1
          else checks << "RO width #{Framing.fmt_len(so['width'])} (key #{Framing.fmt_len(ko['width'])})"
          end
          if (Framing.ro_height(ko) - Framing.ro_height(so)).abs <= SIZE_TOL then op_pts += 1
          else checks << "RO height #{Framing.fmt_len(Framing.ro_height(so))} (key #{Framing.fmt_len(Framing.ro_height(ko))})"
          end
          sill_ok = ko['type'] != 'Window' || (ko['height'].to_f - so['height'].to_f).abs <= SIZE_TOL
          hdr_ok = ko['header_size'] == so['header_size']
          if sill_ok && hdr_ok && ko['type'] == so['type'] then op_pts += 1
          else
            checks << "type #{so['type']} (key #{ko['type']})" unless ko['type'] == so['type']
            checks << "head height #{Framing.fmt_len(so['height'].to_f)} (key #{Framing.fmt_len(ko['height'].to_f)})" unless sill_ok
            checks << "header #{so['header_size']} (key #{ko['header_size']})" unless hdr_ok
          end
          notes << { 'area' => 'Openings', 'ok' => false, 'text' => "#{so['mark']}: #{checks.join('; ')}." } unless checks.empty?
        end
        s_ops.each do |o|
          notes << { 'area' => 'Openings', 'ok' => false, 'text' => "Extra opening not in the key: #{o['mark']} on #{o['wall']}." }
          op_max += 1
        end

        # Framing - members correct per student's own walls (from inspection)
        fr = student['framing'] || {}
        f_ok = fr.values.sum { |v| v['correct'].to_i }
        f_tot = fr.values.sum { |v| v['total'].to_i }
        fr.each do |wid, v|
          next if v['correct'] == v['total']
          notes << { 'area' => 'Framing', 'ok' => false, 'text' => "#{wid}: #{v['correct']} of #{v['total']} members correct." }
        end

        log = student['log'] || []
        tk = student['takeoff']

        {
          'sections' => [
            { 'name' => 'Walls (location, level, type)', 'score' => pct(wall_pts, wall_max) },
            { 'name' => 'Openings (marks, RO sizes, location, headers)', 'score' => pct(op_pts, op_max) },
            { 'name' => 'Framing members', 'score' => pct(f_ok, f_tot) },
            { 'name' => 'Takeoff', 'score' => tk ? tk['score'] : nil }
          ],
          'inspections' => log.size,
          'takeoff_checks' => (student['takeoff_log'] || []).size,
          'notes' => notes,
          'walls_matched' => pairs.size,
          'walls_in_key' => key['walls'].size
        }
      end
    end
  end
end
