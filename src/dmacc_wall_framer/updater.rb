require 'json'

module DMACC
  module WallFramer
    # Reload code in place after installing over the top, and check a web
    # address for newer builds (version.json next to the .rbz files).
    #
    # version.json looks like:
    #   { "version": "0.6.1", "rbz": "https://.../WallFramer_v0.6.1.rbz", "notes": "What changed" }
    module Updater
      PREF = 'DMACC_WallFramer'.freeze
      DEFAULT_URL = 'https://raw.githubusercontent.com/adamnegrete-lab/Wall-Framer-Ext./main/version.json'.freeze
      FILES = %w[version framing corners joints inspector takeoff answer_key yard_logic shop project builder
                 yard_view tools install_tool guided_tool dialogs updater main].freeze

      class << self
        # ---------- reload ----------

        def reload!
          dir = __dir__
          old = $VERBOSE
          $VERBOSE = nil # constants get redefined - that's expected
          FILES.each { |f| load File.join(dir, "#{f}.rb") }
          $VERBOSE = old
          Dialogs.instance_variables.each { |v| Dialogs.instance_variable_set(v, nil) }
          Sketchup.status_text = "Wall Framer #{VERSION} reloaded."
          true
        rescue StandardError, ScriptError => e
          $VERBOSE = old
          UI.messagebox("Reload failed - close and reopen SketchUp.\n\n#{e.message}")
          false
        end

        # ---------- versions ----------

        def newer?(a, b)
          (a.to_s.split('.').map(&:to_i) <=> b.to_s.split('.').map(&:to_i)) == 1
        end

        def url
          u = Sketchup.read_default(PREF, 'update_url', '').to_s
          u.empty? ? DEFAULT_URL : u
        end

        def set_url
          res = UI.inputbox(['Update address (link to version.json)'], [url], 'Wall Framer Updates')
          return unless res
          Sketchup.write_default(PREF, 'update_url', res[0].strip)
          check(quiet: false) unless res[0].strip.empty?
        end

        # Look for a newer build. quiet = only speak up if there is one.
        def check(quiet: true)
          u = url
          if u.empty?
            set_url unless quiet
            return
          end
          fetch(u) do |ok, body|
            unless ok
              UI.messagebox("Couldn't reach the update address:\n#{u}") unless quiet
              next
            end
            info = begin
              JSON.parse(body)
            rescue JSON::ParserError
              nil
            end
            if info.nil? || info['version'].nil? || info['rbz'].nil?
              UI.messagebox("The update address didn't return a Wall Framer version file.") unless quiet
              next
            end
            if newer?(info['version'], VERSION)
              msg = "Wall Framer #{info['version']} is available (you have #{VERSION})."
              msg += "\n\n#{info['notes']}" if info['notes']
              msg += "\n\nUpdate now?"
              install(info) if UI.messagebox(msg, MB_YESNO) == IDYES
            elsif !quiet
              UI.messagebox("Wall Framer is up to date (#{VERSION}).")
            end
          end
        end

        def install(info)
          fetch(info['rbz']) do |ok, body|
            unless ok && body && body.bytesize > 1000
              UI.messagebox("Couldn't download the update:\n#{info['rbz']}")
              next
            end
            path = File.join(Sketchup.temp_dir, "WallFramer_#{info['version']}.rbz")
            File.binwrite(path, body)
            begin
              Sketchup.install_from_archive(path, false)
            rescue StandardError => e
              UI.messagebox("Install failed: #{e.message}")
              next
            end
            reload!
            UI.messagebox("Updated to Wall Framer #{VERSION}.")
          end
        end

        # GET a URL; yields (ok, body). Keeps the request alive until it finishes.
        def fetch(u, &blk)
          @requests ||= []
          req = Sketchup::Http::Request.new(u, Sketchup::Http::GET)
          @requests << req
          req.start do |_r, res|
            @requests.delete(req)
            ok = res && res.status_code.to_i.between?(200, 299)
            blk.call(ok, ok ? res.body : nil)
          end
        rescue StandardError
          blk.call(false, nil)
        end
      end
    end
  end
end
