module Flk
  # The host's own health while it runs: what `flk doctor` checks, run on
  # a schedule by `flk check --all --due` (flk-check.timer) or by hand
  # with `flk check --host`. The last result of each check is kept in
  # STATE/host-checks.json, so a change is seen and said once: an event
  # when a check starts to warn or fail, another when it passes again.
  # flk doctor and flk context still look for themselves each time and
  # never write here.
  module HostChecks
    EVERY = 300 # seconds between scheduled runs
    RANK = { "pass" => 0, "warn" => 1, "fail" => 2 }.freeze

    module_function

    def path = File.join(ROOT, "host-checks.json")

    # { "at" => when they last ran, "checks" => { ID => { status, label, hint, since } } }
    def stored
      h = Util.read_json(path, nil)
      h.is_a?(Hash) && h["checks"].is_a?(Hash) ? h : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def due?(now = Time.now)
      at = Time.parse(stored&.dig("at").to_s)
      now - at >= EVERY - Checks::SLACK
    rescue ArgumentError
      true
    end

    # Doctor's rows as one result per id: a check that found several
    # problems (two disks, two mounts) is as bad as its worst, and says
    # all of them.
    def by_id(rows)
      rows.group_by { _1["id"] }.to_h do |id, rs|
        worst = rs.max_by { RANK[_1["status"]] || 0 }["status"]
        said = rs.select { _1["status"] == worst }
        [id, { "status" => worst, "label" => said.map { _1["label"] }.join(" · "), "hint" => said.filter_map { _1["hint"] }.first }]
      end
    end

    # Would storing these rows report a new problem? (Then the caller looks
    # once more before saying so.)
    def new_problem?(rows)
      before = stored or return false
      by_id(rows).any? { |id, r| (RANK[r["status"]] || 0) > (RANK[before["checks"].dig(id, "status")] || 0) }
    end

    # Two looks, a few seconds apart: a check is as good as its better
    # look, so something that was only passing through isn't a problem.
    def better(first, second)
      a, b = by_id(first), by_id(second)
      (a.keys & b.keys).map do |id|
        pick = (RANK[b[id]["status"]] || 0) <= (RANK[a[id]["status"]] || 0) ? b[id] : a[id]
        pick.merge("id" => id)
      end + (b.keys - a.keys).filter_map { |id| b[id].merge("id" => id) if b[id]["status"] == "pass" }
    end

    # Stores this run and returns it as rows: [{ id, status, label, hint,
    # since, changed }]. changed is "problem" (it passed before and now
    # warns or fails, or a warning became a failure), "recovered", or
    # nil. A check doctor no longer reports (the thing it watched is
    # gone) counts as passing. The first run only takes stock: nothing
    # changed, because nothing was known.
    def record(rows, now: Time.now)
      FileUtils.mkdir_p(ROOT)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |l|
        l.flock(File::LOCK_EX)
        before = stored
        was = before ? before["checks"] : {}
        at = now.utc.iso8601
        found = by_id(rows)
        out = found.map do |id, r|
          prev = was[id]
          rank = RANK[r["status"]] || 0
          prank = prev ? RANK[prev["status"]] || 0 : 0
          changed = if before.nil? || rank == prank then nil
                    elsif rank.zero? then "recovered"
                    elsif rank > prank then "problem"
                    end
          since = prev && prev["status"] == r["status"] ? prev["since"] : at
          r.merge("id" => id, "since" => since || at, "changed" => changed)
        end
        (was.keys - found.keys).each do |id|
          next if (RANK[was[id]["status"]] || 0).zero?
          out << { "id" => id, "status" => "pass", "label" => "no longer reported (was: #{was[id]['label']})", "hint" => nil,
                   "since" => at, "changed" => "recovered", "gone" => true }
        end
        keep = out.reject { _1["gone"] }.to_h { [_1["id"], _1.slice("status", "label", "hint", "since")] }
        Util.write_json(path, { "at" => at, "checks" => keep })
        out
      end
    end
  end
end
