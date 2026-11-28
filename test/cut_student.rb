# A student who fills the Frame Wall cut list from the plans (the answer key).
# rows: in any order; returns the rows that never went in.
module CutStudent
  include DMACC::WallFramer
  module_function

  def frame_dialog
    UI::HtmlDialog.all.reverse.find { |d| d.file.to_s.end_with?('frame.html') }
  end

  def answer(p, r)
    CutList.answer(p, r)
  end

  # Fill every row (reverse order by default - "any order"). Returns the dialog.
  def fill(g, order: :reverse, only: nil, skip: [])
    Dialogs.open_frame(g)
    fd = frame_dialog
    fd.fire('ready')
    6.times do
      p = Builder.params_of(g)
      rows = CutList.rows(p)
      rows = rows.reverse if order == :reverse
      rows = rows.select { |r| only.include?(r['key']) } if only
      todo = rows.reject { |r| skip.include?(r['key']) || %w[placed none].include?(r['state']) && !r['value'].empty? }
      todo = todo.select { |r| r['value'].empty? || r['state'] == 'error' }
      break if todo.empty?
      todo.each do |r|
        v, size = answer(Builder.params_of(g), r)
        next unless v
        fd.fire('set_row', { 'key' => r['key'], 'v' => v, 'size' => size })
      end
    end
    fd
  end
end
