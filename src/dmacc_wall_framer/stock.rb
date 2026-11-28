module DMACC
  module WallFramer
    # Lumber for the pieces students cut. A framer cuts and places; where the
    # stock comes from isn't the lesson, so there's no yard to manage - a piece
    # is just a size and a length. Materials come out of the framed model.
    module Stock
      MAX = 192.0 # longest plate stock (16')

      module_function

      def piece(size, len)
        @n = (@n || 0) + 1
        { 'id' => "P#{(Time.now.to_f * 1000).to_i.to_s(36)}#{@n}", 'size' => size, 'length' => len.to_f }
      end

      # A run longer than stock, in 16' pieces plus the rest.
      def run(size, len)
        left = len.to_f
        out = []
        while left > MAX + 1e-6
          out << piece(size, MAX)
          left -= MAX
        end
        out << piece(size, left) if left > 1e-6
        out
      end

      # Models from before 0.20 have a material yard drawn beside the house: take it out.
      def clear_old_yard(model = Sketchup.active_model)
        return unless model
        old = model.entities.to_a.select { |e| e.is_a?(Sketchup::Group) && !e.deleted? && e.get_attribute('dmacc_wf_yard', 'yard') }
        return if old.empty?
        model.start_operation('Remove Material Yard', true)
        old.each(&:erase!)
        model.commit_operation
      rescue StandardError
        model.abort_operation rescue nil
      end
    end
  end
end
