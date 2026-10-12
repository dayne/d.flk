# mcshadow: a stand-in Minecraft Java server for testing flk (stdlib only).
#
# Answers the server-list-ping (status) protocol on $PORT (default 25565),
# so real clients and tests/lib/mcping.rb see it as a server. Login attempts
# get a polite disconnect. Like a real server it:
#   - logs "Done (...)!" once it's listening
#   - keeps world state on /data (a flk volume), counting boots and saves
#   - on SIGTERM, logs "Saving worlds", takes SAVE_SECONDS, then "Saved the game"
#
# The status JSON carries an extra "flk" object with what the guest saw
# (env, secret digest, boots, egress), which the tests assert against.
require "socket"
require "json"
require "digest"
require "stringio"
require "timeout"
require "resolv"

$stdout.sync = true
PORT     = Integer(ENV.fetch("PORT", "25565"))
DATA     = ENV.fetch("DATA_DIR", "/data")
SAVE_SEC = Float(ENV.fetch("SAVE_SECONDS", "2"))
STARTED  = Time.now

def log(msg) = puts("[#{Time.now.strftime('%H:%M:%S')}] [Server thread/INFO]: #{msg}")

# ---------- world state on the volume ----------
WORLD = File.join(DATA, "world", "level.json")

def load_world
  JSON.parse(File.read(WORLD))
rescue StandardError
  { "boots" => 0, "saves" => 0 }
end

def save_world(w)
  Dir.mkdir(File.dirname(WORLD)) unless Dir.exist?(File.dirname(WORLD))
  File.write("#{WORLD}.tmp", JSON.generate(w))
  File.rename("#{WORLD}.tmp", WORLD)
end

$world = load_world
$world["boots"] += 1
$world["last_boot"] = STARTED.utc.to_s
save_world($world)

# ---------- egress probe (proves NAT + DNS from inside the VM) ----------
$egress = { "tcp" => nil, "dns" => nil }
Thread.new do
  $egress["tcp"] = (Socket.tcp("1.1.1.1", 53, connect_timeout: 3) { true } rescue false)
  $egress["dns"] = (Timeout.timeout(5) { !Resolv.getaddress("example.com").empty? } rescue false)
end

def status_json
  secret = ENV["MC_SECRET"]
  {
    "version" => { "name" => "1.21.1 (flk shadow)", "protocol" => 767 },
    "players" => { "max" => 20, "online" => 0, "sample" => [] },
    "description" => { "text" => ENV.fetch("MOTD", "A flk shadow server") },
    "flk" => {
      "app" => ENV["FLY_APP_NAME"], "machine_id" => ENV["FLY_MACHINE_ID"],
      "hostname" => ENV["FLK_HOSTNAME"], "ip" => ENV["FLY_PRIVATE_IP"],
      "region" => ENV["FLY_REGION"], "release" => ENV["FLK_RELEASE"],
      "uid" => Process.uid, "uptime" => (Time.now - STARTED).round(1),
      "boots" => $world["boots"], "saves" => $world["saves"],
      "secret_digest" => secret && Digest::SHA256.hexdigest(secret)[0, 16],
      "egress" => $egress
    }
  }
end

# ---------- protocol ----------
def read_varint(io)
  n = shift = 0
  loop do
    b = io.readbyte
    n |= (b & 0x7f) << shift
    return n if b & 0x80 == 0
    shift += 7
    raise "varint too long" if shift > 35
  end
end

def varint(n)
  n &= 0xffffffff
  out = "".b
  loop do
    b = n & 0x7f
    n >>= 7
    out << (n.zero? ? b : b | 0x80).chr
    return out if n.zero?
  end
end

def read_string(io) = io.read(read_varint(io)).force_encoding("UTF-8")
def mc_string(s) = varint(s.bytesize) + s.b

def read_packet(sock)
  len = read_varint(sock)
  raise "bad packet length #{len}" unless len.between?(1, 32_767)
  io = StringIO.new(sock.read(len) || "")
  [read_varint(io), io]
end

def send_packet(sock, id, payload)
  body = varint(id) + payload
  sock.write(varint(body.bytesize) + body)
end

def handle(sock)
  id, io = read_packet(sock)
  return unless id.zero? # handshake
  _proto = read_varint(io)
  _addr = read_string(io)
  _port = io.read(2)
  next_state = read_varint(io)

  if next_state == 2 # login: refuse like a whitelisted server would
    send_packet(sock, 0x00, mc_string(JSON.generate({ "text" => "flk shadow server: logins are not supported" })))
    return
  end

  loop do
    id, io = read_packet(sock)
    case id
    when 0x00 then send_packet(sock, 0x00, mc_string(JSON.generate(status_json)))
    when 0x01 then send_packet(sock, 0x01, io.read(8)); return # pong echoes the payload
    else return
    end
  end
rescue EOFError, IOError, SystemCallError, RuntimeError
  nil # port probes (flk's listening check) connect and hang up; that's fine
ensure
  sock.close rescue nil
end

# ---------- main loop + graceful shutdown ----------
$stopping = false
%w[TERM INT].each { |sig| trap(sig) { $stopping = true } }

log "Starting minecraft server version 1.21.1 (flk shadow)"
log "Starting Minecraft server on *:#{PORT} (boot ##{$world['boots']})"
server = TCPServer.new("0.0.0.0", PORT)
log "Done (#{(Time.now - STARTED).round(3)}s)! For help, type \"help\""

until $stopping
  next unless IO.select([server], nil, nil, 0.5)
  begin
    Thread.new(server.accept_nonblock) { handle(_1) }
  rescue IO::WaitReadable, Errno::EINTR
    nil
  end
end

server.close
log "Stopping server"
log "Saving worlds (#{SAVE_SEC}s)"
sleep SAVE_SEC
$world["saves"] += 1
$world["last_save"] = Time.now.utc.to_s
save_world($world)
log "Saved the game"
exit 0
