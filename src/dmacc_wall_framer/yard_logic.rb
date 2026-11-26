# Pure-Ruby lumber yard: piles of stock, a cart of cut pieces, an offcut
# pile, and a saw with a kerf. Works on a plain Hash so it can be stored as
# JSON in the model and tested outside SketchUp.
module DMACC
  module WallFramer
    module YardLogic
      KERF = 0.125        # saw blade
      MIN_OFFCUT = 1.0    # shorter than this goes in the scrap bin
      MATCH = 1.0 / 32    # "same length" tolerance

      PRECUTS = [92.625, 104.625, 116.625].freeze
      PLATE_STOCK_FT = [8, 10, 12, 14, 16].freeze
      HEADER_STOCK_FT = [8, 12].freeze

      module_function

      def empty
        { 'piles' => [], 'offcuts' => [], 'cart' => [], 'hand' => nil,
          'pulled' => [], 'scrap' => 0.0, 'next' => 1 }
      end

      def new_id(y, prefix)
        id = "#{prefix}#{y['next']}"
        y['next'] += 1
        id
      end

      # stud_types: [{'stud'=>'2x6','stud_length'=>92.625}, ...]
      # header_sizes: sizes used for headers (e.g. ['2x8','2x10','2x12'])
      def default_piles(stud_types, header_sizes)
        y = empty
        sizes = stud_types.map { |t| t['stud'] }.uniq.sort
        stud_types.map { |t| [t['stud'], t['stud_length'].to_f] }.uniq.each do |size, len|
          next unless PRECUTS.any? { |p| (p - len).abs < 0.01 }
          y['piles'] << pile(y, size, len, "#{Framing.fmt_in(len)} precut studs")
        end
        sizes.each do |size|
          PLATE_STOCK_FT.each { |ft| y['piles'] << pile(y, size, ft * 12.0, "#{ft}' stock") }
        end
        (header_sizes - sizes).uniq.sort_by { |s| Framing::ACTUAL[s] }.each do |size|
          HEADER_STOCK_FT.each { |ft| y['piles'] << pile(y, size, ft * 12.0, "#{ft}' header stock") }
        end
        y
      end

      def pile(y, size, length, label, qty = nil)
        { 'id' => new_id(y, 'P'), 'size' => size, 'length' => length, 'label' => "#{size} #{label}", 'qty' => qty }
      end

      def find(list, id)
        list.find { |p| p['id'] == id }
      end

      # Pull one board from a pile, or pick up an offcut. Returns [piece, error].
      def take(y, source_id)
        if (p = find(y['piles'], source_id))
          return [nil, "The #{p['label']} pile is empty."] if p['qty'] && p['qty'] <= 0
          p['qty'] -= 1 if p['qty']
          piece = { 'id' => new_id(y, 'B'), 'size' => p['size'], 'length' => p['length'], 'from' => p['label'] }
          y['pulled'] << { 'size' => p['size'], 'length' => p['length'] }
        elsif (o = find(y['offcuts'], source_id))
          y['offcuts'].delete(o)
          piece = o.merge('from' => 'offcut')
        elsif (c = find(y['cart'], source_id))
          y['hand'] = c['id']
          return [c, nil]
        else
          return [nil, 'That piece is gone.']
        end
        y['cart'] << piece
        y['hand'] = piece['id']
        [piece, nil]
      end

      # Cut a piece in the cart to length. Returns [piece, offcut_or_nil, error].
      def cut(y, piece_id, length, kerf = KERF)
        piece = find(y['cart'], piece_id)
        return [nil, nil, 'Pick up a board first.'] unless piece
        len = length.to_f
        return [nil, nil, 'Cut length must be more than 0.'] if len <= 0
        if len > piece['length'] + MATCH
          return [nil, nil, "Too long - that board is only #{Framing.fmt_len(piece['length'])}."]
        end
        return [piece, nil, nil] if (len - piece['length']).abs <= MATCH # no cut needed

        rest = piece['length'] - len - kerf
        piece['length'] = len
        off = nil
        if rest >= MIN_OFFCUT
          off = { 'id' => new_id(y, 'O'), 'size' => piece['size'], 'length' => rest }
          y['offcuts'] << off
        else
          y['scrap'] += [rest, 0].max
        end
        y['scrap'] += kerf
        [piece, off, nil]
      end

      # Piece leaves the cart (nailed into the wall).
      def install(y, piece_id)
        piece = find(y['cart'], piece_id)
        return nil unless piece
        y['cart'].delete(piece)
        y['hand'] = nil if y['hand'] == piece_id
        piece
      end

      # Piece pried out of the wall goes back on the cart, in hand.
      def return_piece(y, piece)
        p = { 'id' => piece['id'] || new_id(y, 'B'), 'size' => piece['size'], 'length' => piece['length'].to_f,
              'from' => 'pulled from wall' }
        y['cart'] << p
        y['hand'] = p['id']
        p
      end

      def discard(y, piece_id)
        piece = find(y['cart'], piece_id) || find(y['offcuts'], piece_id)
        return nil unless piece
        y['cart'].delete(piece)
        y['offcuts'].delete(piece)
        y['scrap'] += piece['length'].to_f
        y['hand'] = nil if y['hand'] == piece_id
        piece
      end

      # Smallest offcut of this size that can give a piece of length len.
      def best_offcut(y, size, len, kerf = KERF)
        y['offcuts'].select do |o|
          o['size'] == size && (o['length'] >= len + kerf - 1e-9 || (o['length'] - len).abs <= MATCH)
        end.min_by { |o| o['length'] }
      end

      # The "saw stop": sticky stock + cut length. Pull a board (or the
      # best-fit offcut) and cut it, ready to nail. Returns [piece, error].
      def refill(y, kerf = KERF)
        pile = find(y['piles'], y['stock'])
        return [nil, 'Pick a stock first (panel or click a pile).'] unless pile
        len = y['cut'] ? y['cut'].to_f : pile['length'].to_f
        if y['use_offcuts'] && (o = best_offcut(y, pile['size'], len, kerf))
          piece, err = take(y, o['id'])
        else
          return [nil, "#{pile['label']} is only #{Framing.fmt_len(pile['length'])} - can't cut #{Framing.fmt_len(len)}."] if len > pile['length'] + MATCH
          piece, err = take(y, pile['id'])
        end
        return [nil, err] if err
        piece, _off, err = cut(y, piece['id'], len, kerf) if y['cut']
        [piece, err]
      end

      # Pull and cut boards to cover a run of plate (splices if no board is long enough).
      # Returns [pieces, error]. Pieces stay on the cart; caller installs them.
      def pull_for(y, size, len, kerf = KERF)
        stock = y['piles'].select { |p| p['size'] == size && !p['label'].include?('precut') && (p['qty'].nil? || p['qty'] > 0) }
                          .sort_by { |p| p['length'] }
        return [[], "No #{size} plate stock in the yard."] if stock.empty?
        pieces = []
        left = len.to_f
        while left > MATCH
          pile = stock.find { |p| p['length'] >= left - MATCH } || stock.last
          pc, err = take(y, pile['id'])
          return [pieces, err] if err
          cut_to = [left, pc['length']].min
          pc, _off, err = cut(y, pc['id'], cut_to, kerf)
          return [pieces, err] if err
          pieces << pc
          left -= cut_to
        end
        y['hand'] = nil
        [pieces, nil]
      end

      # Guided mode: get a piece of this size/length the way a framer would -
      # a drop from the offcut pile if one fits, else the shortest stock that's
      # long enough (an exact precut needs no cut). Returns [piece, error].
      def supply(y, size, len, kerf = KERF)
        len = len.to_f
        if (o = best_offcut(y, size, len, kerf))
          pc, err = take(y, o['id'])
        else
          pile = y['piles'].select { |p| p['size'] == size && (p['qty'].nil? || p['qty'] > 0) && p['length'] >= len - MATCH }
                           .min_by { |p| [(p['length'] - len).abs <= MATCH ? 0 : 1, p['length']] }
          return [nil, "Nothing in the yard is long enough for a #{size} at #{Framing.fmt_len(len)}."] unless pile
          pc, err = take(y, pile['id'])
        end
        return [nil, err] if err
        pc, _off, err = cut(y, pc['id'], len, kerf)
        [pc, err]
      end

      # What the next click would nail (for previews), without changing anything.
      def next_piece(y)
        h = hand(y)
        return h if h
        pile = find(y['piles'], y['stock'])
        return nil unless pile
        { 'size' => pile['size'], 'length' => y['cut'] ? y['cut'].to_f : pile['length'].to_f }
      end

      def hand(y)
        y['hand'] && find(y['cart'], y['hand'])
      end

      # installed_in: total length (in) of pieces nailed into walls
      def stats(y, installed_in)
        pulled = y['pulled'].sum { |p| p['length'].to_f }
        {
          'pulled_lf' => (pulled / 12.0).round(1),
          'installed_lf' => (installed_in / 12.0).round(1),
          'cart_lf' => (y['cart'].sum { |p| p['length'].to_f } / 12.0).round(1),
          'offcut_lf' => (y['offcuts'].sum { |p| p['length'].to_f } / 12.0).round(1),
          'scrap_lf' => (y['scrap'].to_f / 12.0).round(1),
          'boards_pulled' => y['pulled'].size,
          'waste_pct' => pulled.zero? ? 0.0 : (100.0 * (pulled - installed_in) / pulled).round(1)
        }
      end
    end
  end
end
