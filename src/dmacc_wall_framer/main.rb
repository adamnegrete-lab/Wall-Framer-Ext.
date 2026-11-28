require 'sketchup.rb'
require 'json'

%w[version updater views framing corners joints inspector takeoff answer_key stock shop project builder cutlist tools corner_tool guided_tool demo_tool dialogs instructor].each do |f|
  Sketchup.require(File.join(__dir__, f))
end

module DMACC
  module WallFramer
    class << self
      # ---------- walls ----------

      def draw_wall
        d = Project.data
        levels = d['levels'].map { |l| l['name'] }
        types = d['wall_types'].map { |t| t['name'] }
        @last_level = levels.first unless levels.include?(@last_level)
        @last_type = types.first unless types.include?(@last_type)
        res = UI.inputbox(['Level', 'Wall type'], [@last_level, @last_type],
                          [levels.join('|'), types.join('|')], 'Place Wall')
        return unless res
        @last_level, @last_type = res
        Sketchup.active_model.select_tool(DrawWallTool.new(@last_level, @last_type))
      end

      def frame_wall
        Builder.ensure_unique_ids
        walls = Builder.selected_walls
        return UI.messagebox('Select one wall first (click it with the Select tool).') unless walls.size == 1
        Dialogs.start_wall(walls.first)
      end

      def change_wall_type
        walls = Builder.selected_walls
        return UI.messagebox('Select one or more walls first.') if walls.empty?
        types = Project.data['wall_types'].map { |t| t['name'] }
        res = UI.inputbox(['Wall type'], [Builder.params_of(walls.first)['type']], [types.join('|')], 'Change Wall Type')
        return unless res
        type = Project.wall_type(res[0])
        Dialogs.operation('Change Wall Type') do
          walls.each do |w|
            p = Builder.apply_type(Builder.params_of(w), type)
            p['last_inspection'] = nil
            p['flags'] = []
            errs = Framing.validate(p, Project.header_table)
            if errs.empty?
              Builder.set_params(w, p)
              Builder.rebuild(w)
            else
              UI.messagebox("#{p['id']} not changed:\n" + errs.join("\n"))
            end
          end
        end
      end

      # ---------- reports ----------

      def export_cut_list
        unless Project.settings['auto_cutlist'] || Project.instructor?
          return UI.messagebox('Your instructor has turned off the automatic cut list. Use Takeoff to build your own.')
        end
        walls = Builder.selected_walls
        walls = Builder.all_walls if walls.empty?
        return UI.messagebox('No walls found.') if walls.empty?
        members = Builder.expected_members_all
        path = UI.savepanel('Save Cut List', '', 'framing_cut_list.csv') or return
        path += '.csv' unless path.downcase.end_with?('.csv')
        q = ->(s) { %("#{s.to_s.gsub('"', '""')}") }
        lines = ['Size,Cut length,Inches,Qty,Cut from']
        Framing.cut_list(members).sort_by { |(s, l), _| [s, -l] }.each do |(size, len), qty|
          lines << [size, q.call(Framing.fmt_len(len)), len, qty, q.call(Framing.stock_for(len))].join(',')
        end
        lines << ''
        members.group_by(&:nominal).sort.each { |n, ms| lines << "#{n} total,#{(ms.sum(&:length) / 12.0).round(1)} LF" }
        File.write(path, lines.join("\n"))
        UI.messagebox("Cut list saved:\n#{path}")
      end

      def require_instructor
        return true if Project.instructor?
        UI.messagebox('Instructor only. Unlock in Project Setup.')
        false
      end

      def student_snapshot
        table = Project.header_table
        d = Project.data
        walls = Builder.all_walls
        framing = {}
        walls.each do |w|
          p = Builder.params_of(w)
          r = Inspector.inspect_wall(p, p['entries'], level: 'fix', table: table, student_layout: Project.settings['student_layout'])
          framing[p['id']] = { 'correct' => r['correct'], 'total' => r['total'] }
        end
        { 'walls' => walls.map { |w| Builder.snapshot_wall(w) }, 'framing' => framing,
          'takeoff' => d['takeoff_score'] ? { 'score' => d['takeoff_score'] } : nil,
          'log' => d['log'], 'takeoff_log' => d['takeoff_log'] }
      end

      def export_key
        return unless require_instructor
        Builder.ensure_unique_ids
        walls = Builder.all_walls
        return UI.messagebox('No walls in this model.') if walls.empty?
        path = UI.savepanel('Save Answer Key', '', 'answer_key.json') or return
        path += '.json' unless path.downcase.end_with?('.json')
        key = { 'format' => 'dmacc-wall-framer-key-1', 'created' => Time.now.strftime('%Y-%m-%d %H:%M'),
                'model' => Sketchup.active_model.title, 'walls' => walls.map { |w| Builder.snapshot_wall(w) } }
        File.write(path, JSON.pretty_generate(key))
        UI.messagebox("Answer key saved (#{walls.size} walls):\n#{path}\n\nKeep this file off student computers.")
      end

      def grade_against_key
        return unless require_instructor
        path = UI.openpanel('Open Answer Key', '', 'Answer key|*.json||') or return
        key = JSON.parse(File.read(path))
        return UI.messagebox("That isn't a Wall Framer answer key.") unless key['walls']
        Builder.ensure_unique_ids
        res = AnswerKey.compare(key, student_snapshot)
        show_report(report_html(res, key))
      rescue JSON::ParserError
        UI.messagebox("Couldn't read that file.")
      end

      def h(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end

      def report_html(res, key)
        m = Sketchup.active_model
        d = Project.data
        rows = res['sections'].map do |s|
          v = s['score'].nil? ? 'not checked' : "#{s['score']}%"
          "<li><strong>#{h(s['name'])}:</strong> #{v}</li>"
        end.join
        notes = res['notes'].group_by { |n| n['area'] }.map do |area, ns|
          "<h3>#{h(area)}</h3><ul>" + ns.map { |n| "<li>#{h(n['text'])}</li>" }.join + '</ul>'
        end.join
        notes = '<p>No differences found.</p>' if notes.empty?
        log = d['log'].last(40).map do |l|
          next "<li>#{h(l['time'])} - #{h(l['summary'])}</li>" unless l['total']
          "<li>#{h(l['time'])} - #{h(l['wall'])}: #{l['correct']}/#{l['total']} correct, #{l['wrong']} wrong, #{l['blank']} blank</li>"
        end.join
        tk = d['takeoff_log'].map { |l| "<li>#{h(l['time'])} - #{l['score']}%</li>" }.join
        <<~HTML
          <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Wall Framer Grade Report</title>
          <style>body{font:13px/1.45 "Segoe UI",Arial,sans-serif;color:#111;margin:20px;max-width:820px}
          h1{font-size:18px;margin:0 0 4px}h2{font-size:15px;border-bottom:1px solid #999;padding-bottom:2px;margin-top:20px}
          h3{font-size:13px;margin:12px 0 2px}.meta{color:#444}ul{margin:4px 0 4px 18px;padding:0}
          @media print{button{display:none}}</style></head><body>
          <h1>Wall Framer Grade Report</h1>
          <div class="meta">Student file: #{h(m.title.empty? ? '(unsaved model)' : m.title)}<br>
          Answer key: #{h(key['model'])} (#{h(key['created'])})<br>
          Graded: #{Time.now.strftime('%Y-%m-%d %H:%M')}</div>
          <h2>Scores by area</h2><ul>#{rows}</ul>
          <p>Walls matched: #{res['walls_matched']} of #{res['walls_in_key']}. Inspections requested: #{res['inspections']}. Takeoff checks: #{res['takeoff_checks']}.</p>
          <h2>Inspector catches</h2>#{catches_html}
          <h2>Differences from the key</h2>#{notes}
          <h2>Double top plate interlock</h2>#{interlock_html}
          <h2>Student field notes</h2>#{field_notes_html}
          <h2>Inspection history (last 40)</h2><ul>#{log.empty? ? '<li>None</li>' : log}</ul>
          <h2>Takeoff history</h2><ul>#{tk.empty? ? '<li>None</li>' : tk}</ul>
          <p style="color:#444">Framing members are scored against the correct framing for the walls and openings as the student modeled them. Wall and opening errors are scored separately above.</p>
          </body></html>
        HTML
      end

      def interlock_html
        levels = Builder.all_walls.map { |w| Builder.params_of(w)['level'] }.uniq
        rows = levels.flat_map { |lv| Builder.interlock(lv) }
        return '<p>No joints between walls.</p>' if rows.empty?
        ok = rows.count { |r| r['ok'] }
        "<p>#{ok} of #{rows.size} joints interlocked.</p><ul>" + rows.reject { |r| r['ok'] }.map { |r| "<li>#{h(r['text'])}</li>" }.join + '</ul>'
      end

      # Mistakes the inspector caught along the way (fixed or not). Inspection is optional,
      # so this is what separates right-the-first-time from fixed-after-inspection.
      def catches_html
        cs = Project.data['catches'] || []
        members = Builder.all_walls.sum { |w| Builder.work_slots(Builder.params_of(w)).size }
        caught = cs.size
        first = members.positive? ? ((members - caught).clamp(0, members) * 100.0 / members).round(1) : 100.0
        head = "<p><strong>First-time right: #{first}%</strong> (#{members - caught} of #{members} framing locations never flagged). " \
               "Mistakes caught: #{caught}#{cs.any? { |c| c['times'].to_i > 1 } ? " - #{cs.count { |c| c['times'].to_i > 1 }} caught more than once" : ''}.</p>"
        return head + '<p>None - nothing the inspector flagged.</p>' if cs.empty?
        head + '<ul>' + cs.sort_by { |c| [c['wall'], c['label'].to_s] }.map do |c|
          "<li>#{h(c['wall'])} #{h(c['label'])}: #{h(c['message'])}#{c['times'].to_i > 1 ? " (caught #{c['times']} times)" : ''}</li>"
        end.join + '</ul>'
      end

      def field_notes_html
        ns = Project.data['student_notes'] || []
        return '<p>None.</p>' if ns.empty?
        '<ul>' + ns.map { |n| "<li>#{h(n['text'])}</li>" }.join + '</ul>'
      end

      def show_report(html)
        dlg = UI::HtmlDialog.new(dialog_title: 'Grade Report', width: 860, height: 760,
                                 preferences_key: 'dmacc_wf_report', style: UI::HtmlDialog::STYLE_DIALOG)
        dlg.set_html(html)
        dlg.show
        if UI.messagebox('Save this report as an HTML file (opens in any browser, prints clean)?', MB_YESNO) == IDYES
          path = UI.savepanel('Save Report', '', "#{Sketchup.active_model.title}_grade_report.html")
          File.write(path.end_with?('.html') ? path : "#{path}.html", html) if path
        end
      end

      def show_log
        return unless require_instructor
        d = Project.data
        lines = d['log'].last(30).map { |l| l['total'] ? "#{l['time']}  #{l['wall']}: #{l['correct']}/#{l['total']}" : "#{l['time']}  #{l['summary']}" }
        UI.messagebox("Inspections: #{d['log'].size}\nTakeoff checks: #{d['takeoff_log'].size}\n\n#{lines.join("\n")}")
      end
    end

    # ---------- toolbar actions (in job-site order) ----------
    class << self
      def frame_tool
        Builder.close_edits
        return UI.messagebox('Place some walls first.') if Builder.all_walls.empty?
        if (w = Builder.selected_walls.first)
          Dialogs.focus_wall(Builder.params_of(w)['id'])
        end
        Stock.clear_old_yard
        Dialogs.activate_tool
        Dialogs.tool.set_mode('guided')
      end

      def corners_tool
        Builder.close_edits
        return UI.messagebox('Place some walls first.') if Builder.all_walls.empty?
        Sketchup.active_model.select_tool(CornerTool.new)
      end

      def tape_tool
        Builder.close_edits
        Sketchup.send_action('selectMeasureTool:')
        Sketchup.status_text = 'Tape Measure: when you are done measuring, click Continue framing in the Frame Wall form (or the Frame tool).'
      end

      def demo_tool
        Builder.close_edits
        return UI.messagebox('Place some walls first.') if Builder.all_walls.empty?
        @demo ||= DemoTool.new
        Sketchup.active_model.select_tool(@demo)
      end

      def dtp_tool
        Builder.close_edits
        return UI.messagebox('Place some walls first.') if Builder.all_walls.empty?
        Dialogs.activate_tool
        Dialogs.tool.set_mode('dtp')
        Dialogs.top_view
      end

      def inspect_tool
        Builder.close_edits
        Dialogs.open_yard
        Dialogs.inspect_focus_level
        Dialogs.refresh_yard
        Dialogs.refresh_frame
      end

      def shop_tool
        g = Dialogs.focus_group or return UI.messagebox('Place some walls first.')
        Dialogs.open_shop(g)
      end

      # Lists toolbar: the Frame Wall form for the wall you're on.
      def cut_list_tool
        g = Dialogs.focus_group or return UI.messagebox('Place some walls first.')
        Dialogs.start_wall(g)
      end

      def header_table_tool
        g = Dialogs.focus_group or return UI.messagebox('Place some walls first - the Header table opens in the Frame Wall form.')
        Dialogs.open_frame(g, header_table: true)
      end

    end

    # ---------- menus ----------
    @old_session = file_loaded?(__FILE__) if @old_session.nil? # SketchUp started on an older version (Reload After Update)
    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('Wall Framer')
      menu.add_item('Project Setup...') { Dialogs.open_setup }
      menu.add_item('Framing Panel') { Dialogs.open_yard }
      menu.add_item('Demo Tool (pull pieces)') { demo_tool }
      menu.add_item('Header Table') { header_table_tool }
      menu.add_item('Change Wall Type of Selected...') { change_wall_type }
      menu.add_item('Export Auto Cut List (CSV)...') { export_cut_list }
      menu.add_separator
      inst = menu.add_submenu('Instructor')
      inst.add_item('Draw Test House (empty model)') { Instructor.draw_test_house }
      inst.add_item("Fill This Wall's Cut List (right answers)") { Instructor.fill_wall }
      inst.add_item('Frame Every Wall on This Floor') { Instructor.frame_floor }
      inst.add_item('Reset This Wall') { Instructor.reset_wall }
      inst.add_separator
      inst.add_item('Export Answer Key...') { export_key }
      inst.add_item('Grade This Model Against Key...') { grade_against_key }
      inst.add_item('Show Attempt Log') { show_log }
      inst.add_item('Lock Again (end instructor session)') { Project.relock }
      menu.add_separator
      menu.add_item('Check for Updates...') { Updater.check(quiet: false) }
      menu.add_item('Reload After Update') { Updater.reload! }
      menu.add_item('Set Update Address...') { Updater.set_url }
      UI.start_timer(8, false) { Updater.check(quiet: true) } # quiet check at startup

      # (context menu handler is registered below, so a reload picks up new code)
      file_loaded(__FILE__)
    end

    # Right-click menu (SketchUp's own): a Wall Framer submenu on selected walls.
    def self.context_menu(cm, submenu: true)
      return unless submenu && Builder.selected_walls.size >= 1
      sub = cm.add_submenu('Wall Framer')
      if Builder.selected_walls.size == 1
        sub.add_item('Frame This Wall') { frame_tool }
        sub.add_item('Frame Wall Form...') { Dialogs.start_wall(Builder.selected_walls.first) }
        sub.add_item('Redo Corners + Stud Layout') do
          w = Builder.selected_walls.first
          Dialogs.operation('Redo Stud Layout') { Builder.reset_commons(w) }
          Dialogs.refresh_yard
        end
        sub.add_item('Shop Drawing...') { Dialogs.open_shop(Builder.selected_walls.first) }
      end
      sub.add_item('Change Wall Type...') { change_wall_type }
      sub.add_item('Delete Selected Wall(s)...') do
        ws = Builder.selected_walls
        ids = ws.map { |w| Builder.params_of(w)['id'] }
        if UI.messagebox("Delete #{ids.join(', ')}? Its framing goes with it.", MB_YESNO) == IDYES
          Dialogs.operation('Delete Wall') do
            ws.each { |w| w.locked = false; w.erase! }
            Builder.forget_dtp(ids)
            Builder.refresh_corner_needs
          end
        end
      end
    end

    unless file_loaded?('dmacc_wf_ctx_v2')
      # An older handler from before a reload already adds the Wall Framer submenu - don't double it.
      sub = !@old_session
      UI.add_context_menu_handler { |cm| WallFramer.context_menu(cm, submenu: sub) }
      file_loaded('dmacc_wf_ctx_v2')
    end

    # ---------- toolbars: Steps (the tools, in job order) + Lists (the framing data) ----------
    # (their own guard, so "Reload After Update" can add them without a restart)
    def self.make_toolbar(name, items)
      tb = UI::Toolbar.new(name)
      icons = File.join(__dir__, 'icons')
      items.each do |label, icon, blk|
        cmd = UI::Command.new(label, &blk)
        cmd.tooltip = label
        cmd.status_bar_text = label
        cmd.small_icon = File.join(icons, "#{icon}_24.png")
        cmd.large_icon = File.join(icons, "#{icon}_32.png")
        tb.add_item(cmd)
      end
      tb.show
      tb
    end

    unless file_loaded?('dmacc_wf_toolbars_v4')
      # retire the one-toolbar layout from before 0.20
      %w[Wall\ Framer Wall\ Framer\ Tools Wall\ Framer\ Steps].each do |old|
        UI.toolbar(old).hide if UI.respond_to?(:toolbar_names) && UI.toolbar_names.include?(old)
      end
      make_toolbar('Wall Framer - Steps', [
        ['Place Walls (plan view) - outside walls counterclockwise', 'wall', proc { draw_wall }],
        ['Corners - which walls run through (plan view)', 'corners', proc { corners_tool }],
        ['Frame - click a wall to frame it on the table', 'frame', proc { frame_tool }],
        ['Tape Measure (Continue framing in the form when done)', 'tape', proc { tape_tool }],
        ['Demo - click a piece to pull it (Esc when done)', 'demo', proc { demo_tool }],
        ['Double Top Plates (top view)', 'dtp', proc { dtp_tool }],
        ['Request Inspection (whole floor)', 'inspect', proc { inspect_tool }]
      ])
      make_toolbar('Wall Framer - Lists', [
        ['Cut List - the Frame Wall form for this wall', 'cutlist', proc { cut_list_tool }],
        ['Framing Panel - this wall, job notes, building', 'yard', proc { Dialogs.open_yard }],
        ['Header Table', 'header', proc { header_table_tool }],
        ['Shop Drawing', 'shop', proc { shop_tool }],
        ['Takeoff', 'takeoff', proc { Dialogs.open_takeoff }]
      ])
      file_loaded('dmacc_wf_toolbars_v4')
    end
  end
end
