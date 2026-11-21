# Config parsing: flk.toml / fly.toml -> machine config. No VMs, no root.
TIER=fast

config() { flk config show; }

test_hello_config() {
  stage_app hello
  local cfg; cfg=$(config)
  assert_eq "$APP" "$(json_get parsed.app <<<"$cfg")" app
  assert_eq 1 "$(json_get machine_config.cpus <<<"$cfg")" cpus
  assert_eq 128 "$(json_get machine_config.memory_mb <<<"$cfg")" memory_mb
  assert_eq "hello world" "$(json_get machine_config.env.GREETING <<<"$cfg")" env
  assert_eq null "$(json_get machine_config.internal_port <<<"$cfg")" internal_port
}

test_mcshadow_services_and_mounts() {
  stage_app mcshadow
  local cfg; cfg=$(config)
  assert_eq 25565 "$(json_get machine_config.internal_port <<<"$cfg")" "internal_port from [[services]]"
  assert_eq "$HOST_PORT" "$(json_get parsed.services.0.ports.0.port <<<"$cfg")" "[[services.ports]] nests under [[services]]"
  assert_eq 512 "$(json_get machine_config.memory_mb <<<"$cfg")" "memory = \"512mb\""
  assert_eq world "$(json_get machine_config.mount_specs.0.source <<<"$cfg")" mount source
  assert_eq /data "$(json_get machine_config.mount_specs.0.destination <<<"$cfg")" mount destination
  assert_eq 30 "$(json_get machine_config.kill_timeout <<<"$cfg")" kill_timeout
  assert_eq tcp "$(json_get machine_config.ports.0.proto <<<"$cfg")" "port proto"
  assert_eq "$HOST_PORT" "$(json_get machine_config.ports.0.port <<<"$cfg")" "host port"
  assert_eq 25565 "$(json_get machine_config.ports.0.internal_port <<<"$cfg")" "port target"
  assert_eq tcp "$(json_get machine_config.internal_protocol <<<"$cfg")" "internal_protocol"
}

# valheim BUGS #6: boot can't wait on a udp internal_port, so it needs to know.
test_internal_protocol() {
  stage_app hello
  toml_append '[[services]]' '  internal_port = 2456' '  protocol = "udp"'
  assert_eq udp "$(config | json_get machine_config.internal_protocol)" "udp service"
  stage_app hello
  toml_append '[http_service]' '  internal_port = 8080' '[[services]]' '  internal_port = 2456' '  protocol = "udp"'
  assert_eq tcp "$(config | json_get machine_config.internal_protocol)" "[http_service] comes first, and is tcp"
}

test_examples_parse_without_warnings() { # and the test apps
  local d cfg
  for d in "$FLK_SRC"/examples/*/ "$TESTS"/apps/*/; do
    cfg=$(APP_DIR=$d flk config show) || fail "config show failed in $d"
    assert_eq "[]" "$(json_get warnings <<<"$cfg")" "warnings in ${d#"$FLK_SRC"/}flk.toml"
  done
}

test_internal_hosts_option() {
  stage_app hello
  assert_eq false "$(config | json_get machine_config.internal_hosts)" "off by default"
  toml_append '[flk]' '  internal_hosts = true'
  assert_eq true "$(config | json_get machine_config.internal_hosts)" "on"
  toml_set 'internal_hosts' 'internal_hosts = "yes"'
  local out
  out=$(config 2>&1) && fail "accepted internal_hosts = \"yes\""
  assert_contains "$out" "[flk] internal_hosts must be true or false"
}

test_vm_size_presets() {
  stage_app hello
  sed -i '/^\[\[vm\]\]/,$d' "$APP_DIR/flk.toml"
  toml_append '[[vm]]' '  size = "shared-cpu-2x"'
  local cfg; cfg=$(config)
  assert_eq 2 "$(json_get machine_config.cpus <<<"$cfg")" "shared-cpu-2x cpus"
  assert_eq 512 "$(json_get machine_config.memory_mb <<<"$cfg")" "shared-cpu-2x memory"

  sed -i 's/shared-cpu-2x/performance-cpu-2x/' "$APP_DIR/flk.toml"
  cfg=$(config)
  assert_eq 4096 "$(json_get machine_config.memory_mb <<<"$cfg")" "performance-cpu-2x memory"
}

test_memory_units() {
  stage_app hello
  toml_set 'memory_mb =' 'memory = "1gb"'
  assert_eq 1024 "$(config | json_get machine_config.memory_mb)" '"1gb"'
}

test_fly_toml_fallback() {
  stage_app hello
  mv "$APP_DIR/flk.toml" "$APP_DIR/fly.toml"
  local cfg; cfg=$(config)
  assert_contains "$(json_get file <<<"$cfg")" fly.toml "config file"
  assert_eq "$APP" "$(json_get parsed.app <<<"$cfg")" app
}

test_flk_section() {
  stage_app hello
  toml_append '[flk]' '  kernel_args = "quiet"' '  rootfs_extra_mb = 64'
  local cfg; cfg=$(config)
  assert_eq quiet "$(json_get machine_config.kernel_args <<<"$cfg")" kernel_args
  assert_eq 64 "$(json_get parsed.flk.rootfs_extra_mb <<<"$cfg")" rootfs_extra_mb
}

test_bad_toml_rejected() {
  stage_app hello
  echo 'this is not toml' >>"$APP_DIR/flk.toml"
  local out
  out=$(config 2>&1) && fail "flk config show accepted broken toml"
  assert_contains "$out" "can't parse"
}

test_bad_env_key_rejected() {
  stage_app hello
  toml_set 'GREETING' '"BAD-KEY" = "x"'
  local out
  out=$(config 2>&1) && fail "accepted an invalid env var name"
  assert_contains "$out" "isn't a valid variable name"
}

test_bad_app_name_rejected() {
  stage_app hello
  toml_set 'app =' 'app = "Bad_Name"'
  local out
  out=$(flk status 2>&1) && fail "accepted an invalid app name"
  assert_contains "$out" "invalid app name"
}

test_kill_timeout_formats() {
  stage_app hello
  assert_eq 10 "$(config | json_get machine_config.kill_timeout)" "default"
  sed -i 's/^app = .*/&\nkill_timeout = "2m"/' "$APP_DIR/flk.toml"
  assert_eq 120 "$(config | json_get machine_config.kill_timeout)" '"2m"'
  sed -i 's/^kill_timeout = .*/kill_timeout = "45s"/' "$APP_DIR/flk.toml"
  assert_eq 45 "$(config | json_get machine_config.kill_timeout)" '"45s"'
  sed -i 's/^kill_timeout = .*/kill_timeout = "soon"/' "$APP_DIR/flk.toml"
  local out
  out=$(config 2>&1) && fail "accepted kill_timeout = soon"
  assert_contains "$out" "can't parse kill_timeout"
}

test_kill_timeout_capped() {
  stage_app hello
  sed -i 's/^app = .*/&\nkill_timeout = "5m"/' "$APP_DIR/flk.toml"
  assert_eq 300 "$(config | json_get machine_config.kill_timeout)" '"5m" (the limit)'
  sed -i 's/^kill_timeout = .*/kill_timeout = 3000/' "$APP_DIR/flk.toml"
  local out
  out=$(config 2>&1) && fail "accepted kill_timeout = 3000"
  assert_contains "$out" "over the 300s"
}

test_udp_and_multiple_ports() {
  stage_app hello
  toml_append '[[services]]' '  internal_port = 19132' '  protocol = "udp"' \
              '  [[services.ports]]' '    port = 19132' '  [[services.ports]]' '    port = 19133'
  local cfg; cfg=$(config)
  assert_eq udp "$(json_get machine_config.ports.0.proto <<<"$cfg")" proto
  assert_eq 19133 "$(json_get machine_config.ports.1.port <<<"$cfg")" "second host port"
  assert_eq 19132 "$(json_get machine_config.ports.1.internal_port <<<"$cfg")" "second port target"
}

test_bad_service_protocol_rejected() {
  stage_app hello
  toml_append '[[services]]' '  internal_port = 80' '  protocol = "sctp"' '  [[services.ports]]' '    port = 80'
  local out
  out=$(config 2>&1) && fail "accepted protocol sctp"
  assert_contains "$out" "not supported"
}

# Host ports below 1024 belong to host services (ssh, http...); DNAT would
# steal their traffic, so flk refuses them unless setup-host.sh allows it.
test_privileged_host_port_rejected() {
  stage_app hello
  toml_append '[[services]]' '  internal_port = 22' '  [[services.ports]]' '    port = 22'
  local out
  out=$(config 2>&1) && fail "accepted host port 22"
  assert_contains "$out" "below 1024"
  assert_contains "$out" "FLK_MIN_PORT=22"
}

test_out_of_range_host_port_rejected() {
  stage_app hello
  toml_append '[[services]]' '  internal_port = 8080' '  [[services.ports]]' '    port = 70000'
  local out
  out=$(config 2>&1) && fail "accepted host port 70000"
  assert_contains "$out" "isn't a valid port"
}

# flk-sanity.sh reads doctor through --json; keep the shape stable.
test_doctor_json() {
  local out; out=$("$FLK_BIN" doctor --json)
  ruby -rjson -e 'd = JSON.parse(ARGV[0])
    abort "ok missing" unless [true, false].include?(d["ok"])
    abort "no checks" if d["checks"].empty?
    d["checks"].each { |c| abort "bad check #{c}" unless c["label"].is_a?(String) && %w[pass fail warn].include?(c["status"]) }
    abort "ok disagrees with checks" unless d["ok"] == d["checks"].none? { _1["status"] == "fail" }' "$out"
}

# [http_service] is only forwarded when [flk] http_port picks the host port
test_http_port_forwards_http_service() {
  stage_app hello
  toml_append '[http_service]' '  internal_port = 8080' '[flk]' '  http_port = 18080'
  local cfg; cfg=$(config)
  assert_eq tcp "$(json_get machine_config.ports.0.proto <<<"$cfg")" proto
  assert_eq 18080 "$(json_get machine_config.ports.0.port <<<"$cfg")" "host port"
  assert_eq 8080 "$(json_get machine_config.ports.0.internal_port <<<"$cfg")" "forwarded to internal_port"
}

test_http_service_alone_not_forwarded() {
  stage_app hello
  toml_append '[http_service]' '  internal_port = 8080'
  assert_eq "[]" "$(config | json_get machine_config.ports)" "no host ports without [flk] http_port"
}

test_http_port_rules() {
  stage_app hello
  toml_append '[flk]' '  http_port = 18080'
  local out
  out=$(config 2>&1) && fail "accepted http_port without [http_service]"
  assert_contains "$out" "needs [http_service] internal_port"
  toml_append '[http_service]' '  internal_port = 8080'
  toml_set '  http_port' '  http_port = 80'
  out=$(config 2>&1) && fail "accepted http_port = 80"
  assert_contains "$out" "[flk] http_port 80 is below 1024"
  toml_set '  http_port' '  http_port = 18080'
  toml_append '[[services]]' '  internal_port = 9000' '  [[services.ports]]' '    port = 18080'
  out=$(config 2>&1) && fail "accepted the same host port twice"
  assert_contains "$out" "tcp/18080 is listed twice"
}

test_stdin_option() {
  stage_app hello
  assert_eq console "$(config | json_get machine_config.stdin)" "default"
  toml_append '[flk]' '  stdin = "tty"'
  local out
  out=$(config 2>&1) && fail "accepted stdin = tty"
  assert_contains "$out" '[flk] stdin must be "console" or "null"'
}

test_bind_option() {
  stage_app hello
  assert_eq null "$(config | json_get machine_config.bind)" "default: host setting / all"
  toml_append '[flk]' '  bind = "10.47.11.3"'
  assert_eq '["10.47.11.3"]' "$(config | json_get machine_config.bind)" "one address"
  toml_set 'bind' 'bind = ["10.47.11.3", "192.168.1.5"]'
  assert_eq '["10.47.11.3","192.168.1.5"]' "$(config | json_get machine_config.bind)" "a list"
  toml_set 'bind' 'bind = "all"'
  assert_eq '["all"]' "$(config | json_get machine_config.bind)" "all"
  local bad out
  for bad in '"127.0.0.1"' '"172.30.0.12"' '"10.47.11.300"' '"lan"' '["10.0.0.1", "10.0.0.1"]'; do
    toml_set 'bind' "bind = $bad"
    out=$(config 2>&1) && fail "accepted bind = $bad"
    assert_contains "$out" "[flk] bind" "error names the setting ($bad)"
  done
}

test_host_settings_address_and_bind() {
  stage_app hello
  local h="$WORK/host-bind-$RUN_ID.toml" out
  printf 'address = "10.99.0.7"\nbind = "10.99.0.7"\n' >"$h"
  assert_eq 10.99.0.7 "$(FLK_HOST_CONFIG="$h" flk context --json --no-host | json_get host.address)" "address shown"
  out=$(FLK_HOST_CONFIG="$h" flk doctor 2>&1)
  assert_contains "$out" "10.99.0.7 (address in $h) isn't on this host"
  printf 'address = "nope"\n' >"$h"
  out=$(FLK_HOST_CONFIG="$h" flk doctor 2>&1)
  assert_contains "$out" "address 'nope' isn't an IPv4 address"
  printf 'adress = "10.99.0.7"\n' >"$h"
  out=$(FLK_HOST_CONFIG="$h" flk doctor 2>&1)
  assert_contains "$out" "unknown setting(s) adress"
}

test_huge_pages_option() {
  stage_app hello
  assert_eq null "$(config | json_get machine_config.huge_pages)" "default"
  sed -i 's/^\(\s*\)memory_mb = 128$/&\n\1huge_pages = "2M"/' "$APP_DIR/flk.toml"
  assert_eq 2M "$(config | json_get machine_config.huge_pages)" "2M"
  local out v
  for v in 1G transparent; do
    toml_set 'huge_pages' "huge_pages = \"$v\""
    out=$(config 2>&1) && fail "accepted $v"
    assert_contains "$out" 'huge_pages must be "2M"'
  done
  toml_set 'huge_pages' 'huge_pages = "2M"'
  toml_set 'memory_mb' 'memory_mb = 127'
  out=$(config 2>&1) && fail "accepted 127MB with huge pages"
  assert_contains "$out" "whole 2MB steps"
}

# flk config set / unset (lazyflk's host settings form): lists for bind,
# removing a key, and nothing written when the result doesn't check out.
test_config_set_and_unset() {
  local h="$WORK/hostset-$RUN_ID.toml" out
  rm -f "$h"
  FLK_HOST_CONFIG="$h" flk config set backup_keep=4 bind=10.99.0.7,10.99.0.8 >/dev/null || fail "config set failed"
  assert_eq '["10.99.0.7","10.99.0.8"]' "$(FLK_HOST_CONFIG="$h" flk config show --host | json_get settings.bind)" "bind=A,B is a list"
  FLK_HOST_CONFIG="$h" flk config set bind=10.99.0.7 >/dev/null || fail "config set one bind failed"
  grep -qx 'bind = "10.99.0.7"' "$h" || fail "one address stays a string: $(cat "$h")"
  printf 'bind = [\n  "10.99.0.7",\n  "10.99.0.8",\n]\nbackup_keep = 4\n' >"$h"
  FLK_HOST_CONFIG="$h" flk config set bind=all >/dev/null || fail "replacing a multi-line list failed"
  assert_eq 'bind = "all"|backup_keep = 4' "$(paste -sd'|' "$h")" "the whole list replaced"
  out=$(FLK_HOST_CONFIG="$h" flk config unset bind backup_dir) || fail "config unset failed"
  assert_contains "$out" "bind removed"
  assert_contains "$out" "backup_dir wasn't set"
  assert_eq "backup_keep = 4" "$(cat "$h")" "bind gone, the rest kept"
  out=$(FLK_HOST_CONFIG="$h" flk config set bind=127.0.0.1,10.99.0.7 2>&1) && fail "loopback bind accepted"
  assert_eq "backup_keep = 4" "$(cat "$h")" "a rejected set leaves the file as it was"
  out=$(FLK_HOST_CONFIG="$h" flk config unset nope 2>&1) && fail "unset of an unknown key passed"
  assert_contains "$out" "unknown config key 'nope'"
}

# flk's exec and udp checks, and [deploy] preflight (M6 checks).
test_exec_and_udp_checks() {
  stage_app hello
  toml_append '' '[deploy]' '  preflight = "test -f flk.toml"' \
    '' '[checks.ready]' '  type = "exec"' '  command = "test -d /data"' \
    '' '[checks.tool]' '  type = "exec"' '  command = ["app", "--health"]' '  user = "root"' '  timeout = "3s"' \
    '' '[checks.query]' '  type = "udp"' '  port = 2457' '  send_hex = "FF FF FF FF 54"' '  expect = "^\\\\xFF"' \
    '' '[checks.text]' '  type = "udp"' '  port = 5000' '  send = "ping"'
  local cfg; cfg=$(config 2>&1) || fail "config show failed: $cfg"
  assert_eq '["sh","-c","test -d /data"]' "$(json_get machine_config.checks.0.command <<<"$cfg")" "a command string runs with sh -c"
  assert_eq "test -f flk.toml" "$(json_get preflight <<<"$cfg")" "[deploy] preflight"
  assert_eq 10 "$(json_get machine_config.checks.0.timeout <<<"$cfg")" "exec timeout default"
  assert_eq '["app","--health"]' "$(json_get machine_config.checks.1.command <<<"$cfg")" "a command list as is"
  assert_eq root "$(json_get machine_config.checks.1.user <<<"$cfg")" "exec user"
  assert_eq 3 "$(json_get machine_config.checks.1.timeout <<<"$cfg")" "exec timeout"
  assert_eq ffffffff54 "$(json_get machine_config.checks.2.send_hex <<<"$cfg")" "send_hex, spaces dropped"
  assert_eq 2 "$(json_get machine_config.checks.2.timeout <<<"$cfg")" "udp timeout default"
  assert_eq 70696e67 "$(json_get machine_config.checks.3.send_hex <<<"$cfg")" "send as text"
  [[ $cfg != *"unknown key"* ]] || fail "the new keys warn as unknown: $cfg"
}

# Health while running: a check's interval (seconds in machine_config).
test_check_interval() {
  stage_app hello
  toml_append '' '[checks.up]' '  port = 80' '  interval = "5m"' \
    '' '[checks.ready]' '  type = "log"' '  match = "ready"' '  interval = 90' \
    '' '[checks.once]' '  port = 81'
  local cfg; cfg=$(config 2>&1) || fail "config show failed: $cfg"
  assert_eq 300 "$(json_get machine_config.checks.0.interval <<<"$cfg")" "5m"
  assert_eq 90 "$(json_get machine_config.checks.1.interval <<<"$cfg")" "a number is seconds"
  assert_eq null "$(json_get machine_config.checks.2.interval <<<"$cfg")" "no interval: deploys only"
  [[ $cfg != *"unknown key"* && $cfg != *"interval"*"ignores"* ]] || fail "interval warns: $cfg"
  local bad out
  for bad in '"0s"' '"soon"' '"1h30m"'; do
    stage_app hello
    toml_append '' '[checks.c]' '  port = 80' "  interval = $bad"
    out=$(config 2>&1) && fail "config show accepted interval = $bad"
    assert_contains "$out" "check c" "the error names the check (interval = $bad)"
  done
}

# [flk] log_max_mb (enshrouded BUGS #3): an app's own limit for its
# machines' console.log, kept in each machine's config. Without it the
# host's FLK_LOG_MAX_MB applies (default 10).
test_log_max_mb() {
  stage_app hello
  local cfg; cfg=$(config 2>&1) || fail "config show failed: $cfg"
  assert_eq null "$(json_get machine_config.log_max_mb <<<"$cfg")" "unset: the host's limit"
  toml_append '[flk]' '  log_max_mb = 200'
  cfg=$(config 2>&1) || fail "config show failed: $cfg"
  assert_eq 200 "$(json_get machine_config.log_max_mb <<<"$cfg")" "the app's limit"
  [[ $cfg != *"unknown key"* ]] || fail "log_max_mb warns: $cfg"
  local bad out
  for bad in 0 -5 1.5 '"20"' true; do
    stage_app hello
    toml_append '[flk]' "  log_max_mb = $bad"
    out=$(config 2>&1) && fail "config show accepted log_max_mb = $bad"
    assert_contains "$out" "log_max_mb must be a whole number of MB" "log_max_mb = $bad"
  done
  local bytes='m = Struct.new(:config); puts [{ "log_max_mb" => 3 }, {}].map { Flk::VM.log_max_bytes(m.new(_1)) }.join(" ")'
  assert_eq "3145728 10485760" "$(env -u FLK_LOG_MAX_MB ruby -I"$FLK_SRC/lib" -rflk -e "$bytes")" "bytes at boot"
  assert_eq "3145728 2097152" "$(FLK_LOG_MAX_MB=2 ruby -I"$FLK_SRC/lib" -rflk -e "$bytes")" "the host's own limit"
}

test_bad_checks_rejected() {
  local bad out
  for bad in 'type = "exec"' 'type = "udp"|port = 1|send_hex = "zz"' 'type = "udp"|port = 1|send = "a"|send_hex = "61"' \
             'type = "udp"|port = 1|expect = "("' 'type = "nope"'; do
    stage_app hello
    toml_append '' '[checks.c]' "${bad//|/$'\n'}"
    out=$(config 2>&1) && fail "config show accepted check: $bad"
    assert_contains "$out" "check c" "the error names the check ($bad)"
  done
  stage_app hello
  toml_append '' '[deploy]' '  preflight = 3'
  out=$(config 2>&1) && fail "config show accepted preflight = 3"
  assert_contains "$out" "preflight must be a command string"
}

# [[mounts]] seed (PLAN M6): only in the mount when it's on; true or false.
test_mount_seed_option() {
  stage_app hello
  toml_append '[[mounts]]' '  source = "home"' '  destination = "/home/app"' '  seed = true' \
              '[[mounts]]' '  source = "data"' '  destination = "/data"'
  local cfg; cfg=$(config 2>&1) || fail "config show failed: $cfg"
  assert_eq '{"source":"home","destination":"/home/app","seed":true}' "$(json_get machine_config.mount_specs.0 <<<"$cfg")" "seeded mount"
  assert_eq '{"source":"data","destination":"/data"}' "$(json_get machine_config.mount_specs.1 <<<"$cfg")" "a mount without seed is as before"
  [[ $cfg != *"unknown key"* ]] || fail "seed warns as unknown: $cfg"
  toml_set 'seed = true' 'seed = "yes"'
  cfg=$(config 2>&1) && fail "seed = \"yes\" passed"
  assert_contains "$cfg" "[[mounts]] seed must be true or false"
}

# flk.toml keys as JSON (PLAN M6): help --all --json lists every key the
# parser knows, from the table its unknown-key warnings use, and the
# guide's Config section names every key flk reads.
test_config_keys_json() {
  stage_app hello
  local out
  out=$("$FLK_BIN" help --all --json | ruby -rjson -I"$FLK_SRC/lib" -rflk -e '
    keys = JSON.parse($stdin.read)["config_keys"]
    k = keys.to_h { [_1["key"], _1] }
    abort "a key is listed twice" unless k.size == keys.size
    bad = keys.reject { (_1.keys - %w[key table name type default flk_only read doc]).empty? && _1["doc"].to_s.size > 10 }
    abort "badly formed: #{bad.map { _1["key"] }}" if bad.any?
    untyped = keys.select { _1["read"] && !%w[string integer boolean table list duration command regex].include?(_1["type"]) }
    abort "no type: #{untyped.map { _1["key"] }}" if untyped.any?
    e = k["flk.rootfs_extra_mb"]
    puts [e["table"], e["type"], e["default"], e["flk_only"], e["read"]].join(" ")
    e = k["checks.NAME.command"]
    puts [e["table"], e["type"], e["flk_only"]].join(" ")
    e = k["primary_region"]
    puts [e["read"], e["flk_only"]].join(" ")
    puts k.key?("mounts.seed") && k.key?("deploy.preflight") && k.key?("env.NAME") && k.key?("app")
    # the parser warns about exactly the keys that are not in the list
    Flk::AppConfig.known_keys.each do |sect, names|
      names.each do |n|
        key = Flk::ConfigKeys.key(sect, n)
        abort "the parser knows #{key}, config_keys does not" unless k[key]
      end
    end
    # the defaults listed are the ones a config without the key gets
    toml = File.join(ARGV[1], "flk.toml")
    cfg = Flk::AppConfig.new(toml)
    cfg.data.delete("vm") # the hello app sets its memory
    mc = cfg.machine_config
    got = { "kill_timeout" => mc["kill_timeout"], "vm.cpus" => mc["cpus"], "vm.memory_mb" => mc["memory_mb"],
            "restart.policy" => mc["restart"]["policy"], "restart.retries" => mc["restart"]["retries"],
            "flk.stdin" => mc["stdin"], "flk.internal_hosts" => mc["internal_hosts"],
            "flk.rootfs_extra_mb" => cfg.rootfs_extra_mb, "flk.keep_releases" => cfg.keep_releases,
            "build.dockerfile" => Flk::AppConfig.new(toml).tap { _1.data.delete("build") }.dockerfile,
            "flk.backup.mode" => cfg.backup["mode"], "flk.backup.settle" => cfg.backup["settle"],
            "flk.backup.before_deploy" => cfg.backup["before_deploy"] }
    got.each { |key, v| abort "#{key}: listed default #{k[key]["default"].inspect}, the parser gives #{v.inspect}" unless k[key]["default"] == v }
    # the guide
    g = File.read(File.join(ARGV[0], "share/guide.md"))[/^## Config.*?^## Events/m] or abort "no Config section in the guide"
    missing = keys.select { _1["read"] && _1["name"] != "NAME" }.reject { |x| g.match?(/(?<![a-z_])#{Regexp.escape(x["name"])}(?![a-z_])/) }
    abort "the guide never names: #{missing.map { _1["key"] }.join(", ")}" if missing.any?
    puts "ok"' "$FLK_SRC" "$APP_DIR" 2>&1) || fail "$out"
  assert_eq $'[flk] integer 512 true true\n[checks.NAME] command true\nfalse false\ntrue\nok' "$out"
  # an unknown key still warns; a listed one doesn't
  toml_append '[flk]' '  rootfs_extra_mb = 64' '  rootfs_extra = 1'
  out=$(config 2>&1)
  assert_contains "$out" "unknown key flk.rootfs_extra"
  [[ $out != *"unknown key flk.rootfs_extra_mb"* ]] || fail "a listed key warns: $out"
}
