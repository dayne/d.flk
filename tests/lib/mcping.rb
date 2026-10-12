#!/usr/bin/env ruby
# mcping HOST [PORT] [-t SECONDS] [-q KEY.PATH]
#
# Minecraft Java server-list-ping client. Prints the server's status JSON
# (plus "ping_ms"), or with -q just one value, e.g. -q flk.boots or
# -q version.name. Works against real servers and tests/apps/mcshadow.
# Exit 1 if the server can't be reached or answers garbage.
require "socket"
require "json"
require "stringio"
require "timeout"

host = nil
port = 25_565
timeout = 5.0
query = nil
args = ARGV.dup
until args.empty?
  case (a = args.shift)
  when "-t" then timeout = Float(args.shift)
  when "-q" then query = args.shift
  when /\A\d+\z/ then port = Integer(a)
  else host = a
  end
end
abort "usage: mcping HOST [PORT] [-t SECONDS] [-q KEY.PATH]" unless host

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

def packet(id, payload = "".b)
  body = varint(id) + payload
  varint(body.bytesize) + body
end

def read_packet(sock)
  len = read_varint(sock)
  data = sock.read(len)
  raise "short packet" unless data && data.bytesize == len
  io = StringIO.new(data)
  [read_varint(io), io]
end

begin
  status, ping_ms = Timeout.timeout(timeout) do
    Socket.tcp(host, port, connect_timeout: timeout) do |s|
      s.write(packet(0x00, varint(767) + varint(host.bytesize) + host.b + [port].pack("n") + varint(1)))
      s.write(packet(0x00))
      id, io = read_packet(s)
      raise "expected status response, got packet #{id}" unless id.zero?
      json = JSON.parse(io.read(read_varint(io)).force_encoding("UTF-8"))

      token = [rand(2**62)].pack("q>")
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      s.write(packet(0x01, token))
      id, io = read_packet(s)
      raise "bad pong" unless id == 1 && io.read(8) == token
      [json, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)]
    end
  end
rescue StandardError, Timeout::Error => e
  warn "mcping #{host}:#{port}: #{e.class}: #{e.message}"
  exit 1
end

status["ping_ms"] = ping_ms
if query
  v = query.split(".").reduce(status) { |h, k| h.is_a?(Hash) ? h[k] : nil }
  puts v.is_a?(Hash) || v.is_a?(Array) ? JSON.generate(v) : v.to_s
else
  puts JSON.pretty_generate(status)
end
