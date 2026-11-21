module Flk
  # Health while a machine runs (docs/health-design.md): the last result of
  # each of its [checks], in machines/ID/checks.json. Results belong to one
  # boot; a machine that has booted since starts with none. `flk deploy`
  # writes them as it waits for its checks, `flk check` runs the checks
  # again: by hand, or every minute from flk-check.timer with --due, for
  # the checks that have an `interval`. Checks report; nothing here acts on
  # a machine.
  module Checks
    SLACK = 15        # a timer's minute isn't exact: run a check this early rather than a minute late
    STALE_AFTER = 300 # no --due run for this long: the stored results can't be trusted
    TIMER = "flk-check.timer".freeze

    module_function

    def path(m) = m.path("checks.json")

    # {NAME => {"ok", "at", "since", "detail"}} of this boot.
    def results(m)
      h = Util.read_json(path(m), {})
      h["boot"] && h["boot"] == m.h["started_at"] ? h["checks"].to_h : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    # Stores one result and returns what it changed: :failed (it passed
    # before, or this is the boot's first result), :recovered, :passed (the
    # boot's first result) or nil. Locked, so two flk processes that see the
    # same change report it once.
    def record(m, c, ok, detail = nil, now: Time.now)
      File.open("#{path(m)}.lock", File::RDWR | File::CREAT, 0o644) do |l|
        l.flock(File::LOCK_EX)
        all = results(m)
        prev = all[c["name"]]
        at = now.utc.iso8601
        r = { "ok" => ok, "at" => at, "since" => prev && prev["ok"] == ok ? prev["since"] : at }
        r["detail"] = detail.to_s[0, 300] if detail && !ok
        all[c["name"]] = r
        Util.write_json(path(m), { "boot" => m.h["started_at"], "checks" => all })
        if ok then prev.nil? ? :passed : (:recovered unless prev["ok"])
        elsif prev.nil? || prev["ok"] then :failed
        end
      end
    end

    # Whether a --due run tries c now. Only checks with an interval. The
    # first try of a boot waits out the grace_period, so a slow start isn't
    # a failure. A log check that passed is a fact of this boot. A failing
    # check is tried at every run, so its recovery shows within a minute.
    def due?(c, result, booted, now = Time.now)
      return false unless c["interval"]
      return !in_grace?(c, booted, now) unless result
      return true unless result["ok"]
      return false if c["type"] == "log"
      now - Time.parse(result["at"]) >= c["interval"] - SLACK
    end

    def in_grace?(c, booted, now = Time.now) = now - booted < c["grace_period"].to_i

    # For status JSON: every configured check with its last result this
    # boot; ok is nil when it hasn't run since the boot (or the machine is
    # stopped).
    def summary(m)
      res = m.running? ? results(m) : {}
      Array(m.config["checks"]).to_h do |c|
        r = res[c["name"]] || {}
        [c["name"], { "type" => c["type"], "interval" => c["interval"], "ok" => r["ok"], "at" => r["at"],
                      "since" => r["since"], "detail" => r["detail"] }]
      end
    end

    # ---------- the runner (flk check --all --due, from flk-check.timer) ----------

    def run_path = File.join(ROOT, "check-run.json")

    def mark_run(started, rows)
      Util.write_json(run_path, { "at" => started.utc.iso8601, "took" => (Time.now - started).round(1),
                                  "ran" => rows.count { !_1["skipped"] },
                                  "failing" => rows.count { _1["ok"] == false } })
    rescue SystemCallError
      nil
    end

    def last_run
      Time.parse(Util.read_json(run_path, {})["at"].to_s)
    rescue ArgumentError, JSON::ParserError, SystemCallError
      nil
    end

    def timer_installed? = File.exist?("/etc/systemd/system/#{TIMER}")

    # Machines whose checks ask for an interval: someone has to run them.
    def interval_machines
      App.all.flat_map(&:machines).select { |m| Array(m.config["checks"]).any? { _1["interval"] } }
    end

    # [problem, fix] when checks ask for an interval and nothing runs them
    # (stored results would look healthy for ever); nil when all is well or
    # no check has an interval.
    def runner_problem(machines = interval_machines)
      return nil if machines.empty?
      apps = machines.map { _1.app.name }.uniq.join(", ")
      unless timer_installed?
        return ["checks with an interval (#{apps}) aren't run: #{TIMER} isn't installed",
                "sudo #{SETUP_HOST} --install-service (or by hand: flk check --all)"]
      end
      t = last_run
      return nil if t && Time.now - t < STALE_AFTER
      ["checks with an interval (#{apps}) #{t ? "last ran #{Util.ago(t.utc.iso8601)}" : 'have never run'}: is #{TIMER} running?",
       "systemctl status #{TIMER} flk-check.service"]
    end
  end
end
