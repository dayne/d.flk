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
