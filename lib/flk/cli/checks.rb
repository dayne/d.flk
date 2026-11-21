module Flk
  # flk check: run health checks on running machines, now (lib/flk/checks.rb
  # keeps the results; the check kinds themselves are in cli/deploy.rb)
  class CLI
    private

    def cmd_check(_args, o)
      raise Error, "--all and -a don't go together" if o[:all] && @app_name
      raise Error, "-i names one app's machine: leave out --all" if o[:all] && o[:instance]
      started = Time.now
      ms = if o[:all] then App.all.flat_map(&:machines)
           else o[:instance] ? [app.machine!(o[:instance])] : app.machines
           end
      rows = ms.flat_map do |m|
        check_machine(m, due: o[:due])
      rescue SystemCallError, JSON::ParserError
        [] # destroyed while we looked: nothing to say about it
      end
      Checks.mark_run(started, rows) if o[:all] && o[:due]
      if o[:json]
        puts JSON.pretty_generate(rows)
      elsif rows.empty?
        puts check_nothing_to_do(o)
      else
        show_app = o[:all]
        Util.table([("APP" if show_app), "MACHINE", "CHECK", "WHAT", "RESULT"].compact, rows.map do |r|
          [(r["app"] if show_app), r["machine"], r["name"], r["what"], check_result_text(r)].compact
        end)
      end
      exit Commands::CLI_CHECK_FAILED if rows.any? { _1["ok"] == false }
    end

    def check_nothing_to_do(o)
      return "No checks were due" if o[:due]
      return "No machine has [checks]" if o[:all]
      app.machines.empty? ? "No machines. Run: flk deploy" : "#{app.name} has no [checks] (flk help config)"
    end

    # One line per check: what it found, and since when.
    def check_result_text(r)
      return "– #{r['skipped']}" if r["skipped"]
      for_how_long = Util.ago(r["since"]).delete_suffix(" ago")
      if r["ok"]
        return "#{Util.green('✔')} found since this boot" if r["type"] == "log"
        "#{Util.green('✔')} ok#{r['changed'] == 'recovered' ? ' again' : " for #{for_how_long}"}"
      else
        "#{Util.red('✘')} failing#{" for #{for_how_long}" unless r['changed'] == 'failed'}#{": #{r['detail']}" if r['detail']}"
      end
    end

    # Runs a machine's checks once (due: only those whose interval has come)
    # and stores what they found. A row per check looked at: its result, or
    # "skipped" and why. Events go out only when a result changes.
    def check_machine(m, due: false)
      cs = Array(m.config["checks"])
      row = lambda do |c, h|
        { "app" => m.app.name, "machine" => m.id, "name" => c["name"], "type" => c["type"],
          "what" => check_what(c), "interval" => c["interval"] }.merge(h)
      end
      unless m.running?
        return due ? [] : cs.map { row[_1, { "ok" => nil, "skipped" => "the machine is stopped" }] }
      end
      boot = m.h["started_at"]
      booted = (Time.parse(boot.to_s) rescue Time.at(0))
      cs.filter_map do |c|
        prev = Checks.results(m)[c["name"]]
        next if due && !Checks.due?(c, prev, booted)
        next row[c, prev.merge("changed" => nil)] if c["type"] == "log" && prev && prev["ok"] # a fact of this boot

        ok = check_once(m, c)
        detail = @check_detail
        unless ok
          # Not a failure to report: still booting, or flk itself is busy with it.
          skip = if prev.nil? && Checks.in_grace?(c, booted)
                   "starting: not passing yet, #{(Time.now - booted).round}s into its #{c['grace_period']}s grace period"
                 elsif (busy = check_machine_busy(m, boot))
                   "not checked: #{busy}"
                 end
          next row[c, { "ok" => nil, "skipped" => skip }] if skip
        end
        change = Checks.record(m, c, ok, detail)
        check_event(m, c, change, prev, detail)
        row[c, Checks.results(m)[c["name"]].to_h.merge("changed" => change&.to_s)]
      end
    end

    # One try; a failure is tried once more after 2s, so one slow answer
    # isn't a failed check. The log check reads the whole boot, however far
    # back its line is (flk logs --boot), not the deploy's last 256KB.
    def check_once(m, c)
      if c["type"] == "log"
        @check_detail = nil
        return true if boot_log_match?(m, Regexp.new(c["match"]))
        @check_detail = "no console line since boot matches /#{c['match']}/"
        return false
      end
      2.times do |i|
        sleep 2 if i == 1
        @check_detail = nil
        return true if check_passes?(m, c)
      end
      @check_detail ||= "no answer on #{c['type']} :#{c['port']}#{c['path']}" if c["port"]
      false
    end

    # Does this boot's console log match re? Read 1MB at a time, so a big
    # [flk] log_max_mb costs time and not memory. Only whole lines are
    # tried until the end (`$` is a line's end, not where a read stopped),
    # and each piece starts with the last lines of the one before, so a
    # match across two reads is found.
    LOG_PIECE = 1_048_576
    LOG_OVERLAP = 65_536

    def boot_log_match?(m, re)
      held = "".b
      boot_parts(m.path("console.log")).each do |file, from|
        File.open(file, "rb") do |f|
          f.seek(from)
          while (piece = f.read(LOG_PIECE))
            held << piece
            done = held.rindex("\n") or next
            return true if console_text(held[0..done]).match?(re)
            keep = done > LOG_OVERLAP ? held.index("\n", done - LOG_OVERLAP) + 1 : 0
            held = held[keep..]
          end
        end
      end
      console_text(held).match?(re)
    rescue SystemCallError
      false
    end

    # Why a failed try says nothing about the app: nil when it does.
    def check_machine_busy(m, boot)
      now = m.app.machines.find { _1.id == m.id }
      return "the machine was stopped or restarted meanwhile" unless now&.running? && now.h["started_at"] == boot
      return "flk is stopping the machine" if now.stopping?
      state = (VM.api(m.path("fc.sock"), "GET", "/")&.dig("state") rescue nil)
      "the machine is paused (a backup)" if state == "Paused"
    end

    def check_event(m, c, change, prev, detail)
      what = "#{c['name']} (#{check_what(c)})"
      case change
      when :failed then Events.machine("check.failed", m, "#{what}#{": #{detail}" if detail}")
      when :recovered
        Events.machine("check.recovered", m, "#{what} after #{Util.ago(prev['since']).delete_suffix(' ago')}")
      when :passed then Events.machine("check.passed", m, what)
      end
    end
  end
end
