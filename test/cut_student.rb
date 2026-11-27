# A student who fills the Frame Wall cut list from the plans (the answer key).
# rows: in any order; returns the rows that never went in.
module CutStudent
  include DMACC::WallFramer
  module_function

  def frame_dialog
    UI::HtmlDialog.all.reverse.find { |d| d.file.to_s.end_with?('frame.html') }
  end

  def answer(p, r)
    slots = Builder.work_slots(p)
    by = slots.to_h { |s| [s.id, s] }
    first = r['slots'].map { |id| by[id] }.compact.first
    case r['input']
    when 'corner'
      need = (p['corner_need'] || {})[r['key'].split(':').last]
      [need && need['type'] == 'L' ? 'L' : 'single']
    when 'oc'
      sp = p['spacing'].to_f
      [sp == sp.round ? sp.round.to_s : sp.to_s]
    when 'backing' then ['ladder']
    when 'lens'
      len = first.expected['length'].to_f
      pcs = []
      while len > Framing::STOCK_MAX + 1e-6
        pcs << Framing::STOCK_MAX
        len -= Framing::STOCK_MAX
      end
      pcs << len
      [pcs.map { |l| Framing.fmt_len(l) }.join(', '), first.expected['size']]
    else
      first ||= slots.find { |s| s.phase == 'commons' && s.kind == :vertical } if r['key'] == 'common'
      return nil unless first
      [Framing.fmt_len(first.expected['length']), first.expected['size']]
    end
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
