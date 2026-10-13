require "socket"
require "io/console"

module Flk
  # flk-agent: a small static program (Go source in agent/) that every
  # release's rootfs gets as /flk/agent, started by /flk/init. It runs
  # commands for `flk exec` and `flk ssh console` over vsock: Firecracker
  # exposes the guest's vsock as a Unix socket in the machine dir, where the
  # host writes "CONNECT PORT\n" and gets "OK ...\n" back.
  # Wire format: see agent/main.go.
  module Agent
    PORT = 10_000
    SRC = File.join(File.dirname(SHARE), "agent")

    module_function

    def path = File.join(ROOT, "bin", "flk-agent")
    def sock(m) = m.path("v.sock")

    def go
      ENV["FLK_GO"] || Util.which("go") ||
        [File.join(Dir.home, ".local/go/bin/go"), "/usr/local/go/bin/go", "/usr/lib/go/bin/go"].find { File.executable?(_1) }
    end

    def stale?
      return true unless File.exist?(path)
      Dir[File.join(SRC, "*.go"), File.join(SRC, "go.mod")].map { File.mtime(_1) }.max.to_i > File.mtime(path).to_i
    end

    # The agent binary, built (again) from agent/ when its source is newer
    # and Go is here; nil when there's none (exec then isn't available in
    # the releases built meanwhile).
    def ensure!
      return path unless stale?
      bin = go
      unless bin
        return path if File.exist?(path)
        warn Util.yellow("⚠ no flk-agent (flk exec, flk ssh console): building it needs Go; " \
                         "install Go, or set FLK_GO, then flk setup")
        return nil
      end
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      out, st = Open3.capture2e({ "CGO_ENABLED" => "0" }, bin, "build", "-trimpath", "-ldflags=-s -w", "-o", tmp, ".", chdir: SRC)
      unless st.success?
        FileUtils.rm_f(tmp)
        warn Util.yellow("⚠ building flk-agent failed:\n#{out}")
        return File.exist?(path) ? path : nil
      end
      File.rename(tmp, path)
      path
    end

    # ---------- the host side of a session ----------

    def frame(type, data = "") = [type, data.bytesize].pack("aN") + data.b

    def read_frame(io)
      h = io.read(5) or return nil
      return nil if h.bytesize < 5
      t, n = h.unpack("aN")
      data = n.zero? ? +"" : io.read(n)
      return nil if data.nil? || data.bytesize < n
      [t, data]
    end

    def connect(m)
      raise Error, "machine #{m.id} isn't running" unless m.running?
      s = sock(m)
      unless File.socket?(s)
        raise Error, "machine #{m.id} has no exec socket: it booted before flk had flk exec; " \
                     "restart it (flk machine restart #{m.id}), and if it still has no agent, redeploy (flk deploy)"
      end
      # a machine that just booted: its agent may not be listening yet
      fresh = (Time.now - Time.parse(m.h["started_at"].to_s) rescue 999) < 20
      deadline = Time.now + (fresh ? 15 : 0)
      loop do
        io = UNIXSocket.new(s)
        io.write("CONNECT #{PORT}\n")
        line = io.wait_readable(5) && io.gets
        return io if line&.start_with?("OK")
        io.close
        break if Time.now >= deadline
        sleep 0.5
      end
      raise Error, "the agent in machine #{m.id} isn't answering: its release was built without one " \
                   "(redeploy with flk deploy; building it needs Go, see flk doctor)"
    end

    # Runs req (argv, env, tty, user, cwd) in machine m. stdin: forward
    # $stdin (else the command's stdin is closed at once). Returns the exit
    # status (128+N for a signal; 124 for timeout).
    def run(m, req, stdin: false, timeout: nil)
      io = connect(m)
      tty = req[:tty]
      if tty
        rows, cols = (IO.console&.winsize rescue nil) || [24, 80]
        req = req.merge(rows: rows, cols: cols, env: Array(req[:env]) + ["TERM=#{ENV['TERM'] || 'xterm'}"])
      end
      lock = Mutex.new
      send = ->(t, d = "") { lock.synchronize { io.write(frame(t, d)) } rescue nil }
      send.call("R", JSON.generate(req))
      old = {}
      if tty
        old["WINCH"] = trap("WINCH") do
          r, c = IO.console.winsize
          send.call("W", JSON.generate("Rows" => r, "Cols" => c))
        end
      else
        old["INT"] = trap("INT") { send.call("S", "2") }
        old["TERM"] = trap("TERM") { send.call("S", "15") }
      end
      reader = if stdin || tty
                 Thread.new do
                   loop do
                     data = $stdin.readpartial(65_536)
                     send.call("I", data)
                   end
                 rescue EOFError, IOError
                   send.call("E")
                 end
               else
                 send.call("E")
                 nil
               end
      timer = timeout && Thread.new do
        sleep timeout
        send.call("S", "9")
        :timed_out
      end
      status = nil
      body = proc do
        while (f = read_frame(io))
          t, data = f
          case t
          when "O" then $stdout.write(data)
          when "D" then $stderr.write(data)
          when "F" then raise Error, "in machine #{m.id}: #{data}"
          when "X"
            x = JSON.parse(data)
            status = x["status"]
            break
          end
        end
      end
      tty && $stdin.tty? ? $stdin.raw(&body) : body.call
      $stdout.flush
      raise Error, "the connection to machine #{m.id} closed before the command finished" if status.nil?
      timer && !timer.alive? && timer.value == :timed_out ? 124 : status
    ensure
      reader&.kill
      timer&.kill
      old&.each { |sig, h| trap(sig, h || "DEFAULT") }
      io&.close
    end
  end
end
