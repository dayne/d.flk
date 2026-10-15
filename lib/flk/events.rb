module Flk
  # A history of what happened to apps and machines: one JSON object per
  # line in STATE/events.jsonl, appended by every flk process (lifecycle
  # commands, deploys, backups, the tmux exit hook), rotated to
  # events.jsonl.1 past MAX_BYTES. `flk events` reads and follows it.
  # Writing an event never fails the command that emits it.
  module Events
    MAX_BYTES = 4 * 1024 * 1024

    # The fixed set of types (documented in the guide); detail is free text.
    TYPES = {
      "machine.created" => "a new machine booted (deploy, scale)",
      "machine.started" => "a stopped machine booted (machine start, resume, after a backup)",
      "machine.updated" => "a machine booted on a new release or config (deploy, rollback)",
      "machine.restarted" => "the restart policy brought back a machine that exited",
      "machine.stopped" => "flk stopped a machine (detail says why)",
      "machine.exited" => "a machine stopped on its own (detail: the app's exit status)",
      "machine.gave_up" => "the restart policy stopped restarting a machine",
      "machine.rolled_back" => "a machine that failed its health checks went back to its previous release",
      "machine.paused" => "a machine was frozen (pause-mode backup)",
      "machine.resumed" => "a frozen machine runs again",
      "machine.destroyed" => "a machine was deleted",
      "check.passed" => "a health check passed during a deploy",
      "check.failed" => "a health check failed during a deploy",
      "deploy.started" => "a deploy or rollback began rolling a release",
      "deploy.succeeded" => "every machine is on the new release",
      "deploy.failed" => "a deploy or rollback stopped (detail: why)",
      "backup.succeeded" => "a volume backup was made (detail: file, check)",
      "backup.failed" => "a volume backup failed",
      "backup.copied" => "a backup was copied to backup_copy_to",
      "backup.copy_failed" => "copying a backup elsewhere failed",
      "volume.restored" => "a volume's data was replaced from a backup",
      "port.forwarded" => "a host port now forwards to a machine",
      "port.dropped" => "a host port no longer forwards to that machine"
    }.freeze

    module_function

    def path = File.join(ROOT, "events.jsonl")

    def emit(type, app: nil, machine: nil, release: nil, detail: nil)
      raise ArgumentError, "unknown event type #{type}" unless TYPES.key?(type)
      ev = { "at" => Time.now.utc.iso8601(3), "app" => app, "machine" => machine, "type" => type }
      ev["release"] = release if release
      ev["detail"] = detail.to_s if detail
      FileUtils.mkdir_p(ROOT)
      rotate if (File.size?(path) || 0) > MAX_BYTES
      # one write of one short line with O_APPEND: whole lines, even from
      # several flk processes at once
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) { _1.write("#{JSON.generate(ev)}\n") }
      Hosts.changed! if type.start_with?("machine.")
      ev
    rescue ArgumentError
      raise
    rescue StandardError
      nil
    end

    def machine(type, m, detail = nil) = emit(type, app: m.app.name, machine: m.id, release: m.release, detail: detail)

    def rotate
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |l|
        l.flock(File::LOCK_EX)
        File.rename(path, "#{path}.1") if (File.size?(path) || 0) > MAX_BYTES
      end
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    # Events from the rotated and the current file, oldest first.
    def read(app: nil, since: nil)
      ["#{path}.1", path].flat_map { File.exist?(_1) ? File.readlines(_1) : [] }
                         .filter_map { parse(_1) }
                         .select { match?(_1, app, since) }
    end

    def match?(ev, app, since) = (app.nil? || ev["app"] == app) && (since.nil? || ev["at"].to_s >= since)

    # Yields the last `backlog` matching events (all since `since`, when
    # given), then new ones as they're appended, across rotations, until
    # interrupted. History and the live part come from one open file, so
    # nothing falls in between.
    def follow(app: nil, since: nil, backlog: 20)
      f = File.exist?(path) ? File.open(path) : nil
      ino = f&.stat&.ino
      old = File.exist?("#{path}.1") ? File.readlines("#{path}.1") : []
      hist = (old + f&.read.to_s.lines).filter_map { parse(_1) }.select { match?(_1, app, since) }
      (since ? hist : hist.last(backlog)).each { yield _1 }
      pending = +""
      emit_lines = lambda do |chunk|
        pending << chunk
        *full, pending = pending.split("\n", -1)
        pending ||= +""
        full.each { |l| (ev = parse(l)) && match?(ev, app, since) && yield(ev) }
      end
      loop do
        emit_lines.call(f.read.to_s) if f
        now = (File.stat(path).ino rescue nil)
        if now && now != ino # rotated (or created): finish the old file, start the new one
          emit_lines.call(f.read.to_s) if f
          f&.close
          f = File.open(path)
          ino = now
          next
        end
        sleep 0.5
      end
    ensure
      f&.close
    end
  end
end
