# Pure-Ruby check of a student's manual takeoff (cut list) against the model.
module DMACC
  module WallFramer
    module Takeoff
      module_function

      # rows: [{'size'=>'2x4','length'=>'92 5/8','qty'=>12, 'note'=>''}]
      # expected: { [size, length_in] => qty }
      # level: same feedback levels as the inspector
      def check(rows, expected, level: 'coach')
        student = Hash.new(0)
        bad_rows = []
        rows.each_with_index do |row, i|
          len = Framing.parse_len(row['length'])
          qty = row['qty'].to_i
          size = row['size'].to_s
          if len.nil? || len <= 0 || qty <= 0 || !Framing::SIZES.include?(size)
            bad_rows << { 'row' => i + 1, 'message' => "Row #{i + 1}: needs a size, a cut length and a quantity." }
            next
          end
          key = match_key(expected, size, len) || [size, Framing.r(len)]
          student[key] += qty
        end

        lines = []
        matched = 0
        extra = 0
        (expected.keys | student.keys).sort_by { |s, l| [s, -l] }.each do |key|
          e = expected[key] || 0
          s = student[key] || 0
          matched += [e, s].min
          extra += [s - e, 0].max
          status = if e == s then 'ok'
                   elsif e.zero? then 'not_needed'
                   elsif s.zero? then 'missing'
                   elsif s < e then 'short'
                   else 'over'
                   end
          lines << { 'size' => key[0], 'length' => key[1], 'length_text' => Framing.fmt_len(key[1]),
                     'student_qty' => s, 'expected_qty' => e, 'status' => status }
        end
        total_expected = expected.values.sum
        denom = total_expected + extra
        score = denom.zero? ? 0 : (100.0 * matched / denom).round(1)

        missing_items = lines.count { |l| l['status'] == 'missing' }
        lines = shape(lines, level)
        { 'score' => score, 'missing_items' => missing_items, 'pieces_expected' => total_expected, 'pieces_entered' => student.values.sum,
          'matched' => matched, 'lines' => lines, 'row_errors' => bad_rows, 'level' => level }
      end

      def match_key(expected, size, len)
        expected.keys.find { |s, l| s == size && (l - len).abs <= Inspector::LENGTH_TOL + 1e-9 }
      end

      MESSAGES = {
        'ok' => 'Correct.',
        'not_needed' => 'No pieces of this size and length are in the model.',
        'missing' => 'Missing from your takeoff.',
        'short' => 'Quantity is short.',
        'over' => 'Quantity is over.'
      }.freeze

      def shape(lines, level)
        case level
        when 'count' then []
        when 'fix'
          lines.map { |l| l.merge('message' => MESSAGES[l['status']]) }
        else
          # don't reveal items the student hasn't found, or the right quantity
          lines.map do |l|
            if l['status'] == 'missing'
              nil
            else
              l.merge('expected_qty' => nil, 'message' => MESSAGES[l['status']])
            end
          end.compact
        end
      end
    end
  end
end
