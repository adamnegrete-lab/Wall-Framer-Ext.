# Pure-Ruby shop drawing: a printable wall elevation with plate layout and
# (optionally) a cut list. Grayscale so it prints on any printer.
module DMACC
  module WallFramer
    module Shop
      LETTERS = {
        'Common Stud' => 'X', 'King Stud' => 'K', 'Jack Stud' => 'J', 'Cripple Stud' => 'C',
        'Header' => 'H', 'Rough Sill' => 'S'
      }.freeze
      GROUP_ORDER = ['Bottom Plate', 'Top Plate', 'Double Top Plate', 'Common Stud', 'King Stud',
                     'Jack Stud', 'Header', 'Rough Sill', 'Cripple Stud'].freeze

      module_function

      def h(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      # opts: 'letters' (bool), 'cutlist' (bool), 'elevation' (bool: draw every member)
      def html(wall, opts, table = Framing::DEFAULT_HEADER_TABLE)
        slots = Framing.slots(wall, table)
        <<~HTML
          <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
          <title>Shop Drawing #{h(wall['id'])}</title>
          <style>
            body{font:12px/1.4 Arial,Helvetica,sans-serif;color:#000;margin:18px}
            h1{font-size:17px;margin:0}
            .meta{color:#333;margin:2px 0 10px}
            h2{font-size:13px;margin:16px 0 4px;border-bottom:1px solid #000;padding-bottom:2px}
            ol,ul{margin:4px 0 0 18px;padding:0}
            .cols{columns:3;column-gap:24px}
            .note{color:#333;font-size:11px}
            .bar{margin:0 0 10px}
            button{font:inherit;padding:5px 12px}
            @media print{.bar{display:none} body{margin:0}}
          </style></head><body>
          <div class="bar"><button onclick="window.print()">Print</button></div>
          <h1>Shop Drawing - #{h(wall['id'])} (#{h(wall['type'])})</h1>
          <div class="meta">#{h(wall['level'])} | #{Framing.fmt_len(wall['length'])} long |
          #{h(wall['stud'])} @ #{wall['spacing']}" O.C. | #{Framing.fmt_len(wall['height'])} overall |
          #{wall['top_plates'].to_i == 2 ? 'double' : 'single'} top plate | viewed from the framing side, wall start on the LEFT</div>
          #{svg(wall, slots, opts)}
          #{legend(opts)}
          <h2>Plate layout - tape hooked on the wall start</h2>
          #{tape(slots, opts)}
          #{openings(wall, table)}
          #{opts['cutlist'] ? cut_list(wall, slots, opts) : '<h2>Cut list</h2><p>Not provided for this assignment - work out every cut from the plans and this layout.</p>'}
          </body></html>
        HTML
      end

      def svg(wall, slots, opts)
        len = wall['length'].to_f
        ht = wall['height'].to_f
        w = 1000.0
        s = [(w - 60) / len, 5.0].min
        hpx = ht * s
        ox = 30.0
        oy = 40.0 + hpx
        out = []
        r = lambda do |x0, z0, x1, z1, fill = '#fff', sw = 0.8|
          out << format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" stroke="#000" stroke-width="%.1f"/>',
                        ox + x0 * s, oy - z1 * s, (x1 - x0) * s, (z1 - z0) * s, fill, sw)
        end
        tx = lambda do |x, y, t, size = 10, anchor = 'middle', weight = 'normal'|
          out << format('<text x="%.1f" y="%.1f" font-size="%d" text-anchor="%s" font-weight="%s" font-family="Arial">%s</text>',
                        x, y, size, anchor, weight, h(t))
        end
        # wall outline
        r.call(0, 0, len, ht, '#fff', 1.4)
        # openings (RO)
        (wall['openings'] || []).each do |o|
          x0 = o['x'].to_f
          x1 = x0 + o['width'].to_f
          z1 = o['height'].to_f
          z0 = o['type'] == 'Window' ? o['sill'].to_f : Framing::T
          out << format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#fff" stroke="#000" stroke-dasharray="5 3"/>',
                        ox + x0 * s, oy - z1 * s, (x1 - x0) * s, (z1 - z0) * s)
          tx.call(ox + (x0 + x1) / 2 * s, oy - (z0 + z1) / 2 * s, o['mark'], 14, 'middle', 'bold')
          tx.call(ox + (x0 + x1) / 2 * s, oy - (z0 + z1) / 2 * s + 15, "RO #{Framing.fmt_in(o['width'])} x #{Framing.fmt_in(Framing.ro_height(o))}", 9)
        end
        # members
        if opts['elevation']
          slots.each do |sl|
            x0, z0, x1, z1 = Framing.slot_box(sl)
            fill = sl.expected['role'] =~ /Plate/ ? '#d9d9d9' : sl.expected['role'] == 'Header' ? '#bfbfbf' : '#efefef'
            r.call(x0, z0, x1, z1, fill)
          end
        else
          # plates only
          slots.select { |sl| sl.expected['role'] =~ /Plate/ }.each { |sl| r.call(*Framing.slot_box(sl), '#d9d9d9') }
        end
        # layout marks on the bottom plate
        verts = slots.select { |sl| sl.kind == :vertical }
        last = [-99.0, -99.0, -99.0] # last label x in each of 3 rows
        verts.group_by(&:x).sort_by(&:first).each do |x, group|
          px = ox + x * s
          out << format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#000" stroke-width="1"/>', px, oy + 2, px, oy + 14)
          out << format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#000" stroke-width="1"/>', px + Framing::T * s, oy + 2, px + Framing::T * s, oy + 14)
          if opts['letters']
            l = group.map { |g| LETTERS[g.expected['role']] }.uniq.join('/')
            cx = px + Framing::T * s / 2
            row = (0..2).find { |i| cx - last[i] >= 9 * l.size + 4 } || 2
            last[row] = cx
            tx.call(cx, oy + 26 + row * 12, l, 10, 'middle', 'bold')
          end
        end
        # horizontal member letters
        if opts['letters']
          slots.select { |sl| %w[Header Rough\ Sill].include?(sl.expected['role']) }.each do |sl|
            x0, z0, x1, z1 = Framing.slot_box(sl)
            tx.call(ox + (x0 + x1) / 2 * s, oy - z1 * s - 3, LETTERS[sl.expected['role']], 10, 'middle', 'bold')
          end
        end
        # start arrow + overall dimension
        tx.call(ox, oy + 66, 'START', 9, 'start', 'bold')
        out << format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#000"/>', ox, oy + 74, ox + len * s, oy + 74)
        tx.call(ox + len * s / 2, oy + 86, Framing.fmt_len(len), 10)
        height = hpx + 140
        %(<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 #{w.round} #{height.round}" role="img" aria-label="Wall elevation">#{out.join}</svg>)
      end

      def legend(opts)
        return '' unless opts['letters']
        '<p class="note">Layout marks: X = common stud, K = king, J = jack (trimmer), C = cripple, H = header, S = rough sill.</p>'
      end

      def tape(slots, opts)
        marks = slots.select { |sl| sl.kind == :vertical }.group_by(&:x).sort_by(&:first).map do |x, group|
          l = opts['letters'] ? " #{group.map { |g| LETTERS[g.expected['role']] }.uniq.join('/')}" : ''
          "<li>#{h(Framing.fmt_len(x))}#{h(l)}</li>"
        end
        %(<p class="note">Distance to the LEFT edge of each stud, measured from the wall start.</p><ol class="cols">#{marks.join}</ol>)
      end

      def openings(wall, table)
        ops = (wall['openings'] || []).sort_by { |o| o['x'].to_f }
        return '' if ops.empty?
        li = ops.map do |o|
          sill = o['type'] == 'Window' ? ", head height #{Framing.fmt_in(o['height'])}" : ''
          "<li><strong>#{h(o['mark'])}</strong> #{h(o['type'])}: RO #{Framing.fmt_in(o['width'])} x #{Framing.fmt_in(Framing.ro_height(o))}#{sill}, " \
            "left edge of RO at #{h(Framing.fmt_len(o['x']))} from start, header #{h(Framing.header_for(o, table))}</li>"
        end
        "<h2>Openings</h2><ul>#{li.join}</ul>"
      end

      def cut_list(wall, slots, opts)
        rows = Hash.new(0)
        slots.each do |sl|
          n = sl.plies || 1
          key = opts['letters'] ? [sl.expected['role'], sl.expected['size'], sl.expected['length']] : ['', sl.expected['size'], sl.expected['length']]
          rows[key] += n
        end
        sorted = rows.sort_by { |(role, size, len), _| [GROUP_ORDER.index(role) || 0, size, -len] }
        li = sorted.map do |(role, size, len), q|
          label = role == 'Header' ? 'Header ply' : role
          name = role.empty? ? '' : " - #{label}#{q > 1 ? 's' : ''}"
          "<li>(#{q}) #{h(size)} x #{h(Framing.fmt_len(len))}#{h(name)}</li>"
        end
        note = opts['letters'] ? '' : '<p class="note">Pieces are listed by size and length only. You decide where each one goes.</p>'
        "<h2>Cut list - #{wall['id']}</h2>#{note}<ul>#{li.join}</ul>" \
          '<p class="note">Header plies are listed as separate pieces. Saw kerf is 1/8" - plan your cuts so offcuts can be used for cripples.</p>'
      end
    end
  end
end
