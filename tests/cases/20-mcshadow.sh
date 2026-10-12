# mcshadow: a long-running "Minecraft" server. Exercises services, env,
# secrets, volumes, restarts, graceful stop, proxy and networking.
# Tests share one VM and run in order; later ones build on earlier state.
TIER=vm

setup_file() {
  stage_app mcshadow
  flk launch --no-deploy
  flk volumes create world --size 1
  flk secrets set MC_SECRET=hunter2 --stage
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; }

sha16() { printf '%s' "$1" | sha256sum | cut -c1-16; }
# Bring the server back if an earlier test left it stopped, so one failure
# doesn't cascade through the rest of the file.
ensure_up() { is_stopped && flk machine start "$(machine_id)" >/dev/null; wait_mc 60; }
egress_probed() { [[ -n $(mcq flk.egress.dns) ]]; } # probe runs async at boot

test_status_ping() {
  assert_contains "$(mcq version.name)" "flk shadow" "version.name"
  assert_eq 20 "$(mcq players.max)" "players.max"
}

test_json_and_context_see_the_running_machine() {
  assert_eq started "$(flk status --json | json_get machines.0.state)" "status --json state"
  assert_eq "$(machine_ip)" "$(flk machine list --json | json_get 0.ip)" "machine list --json ip"
  local c; c=$(flk context --json)
  assert_eq started "$(json_get app.machines.0.state <<<"$c")" "context machine state"
  [[ $(json_get next_steps <<<"$c") != *"flk deploy"* ]] || fail "context suggests deploying an app that's up: $(json_get next_steps <<<"$c")"
  assert_eq started "$(flk machine status "$(machine_id)" "$(machine_id)" | json_get 1.state)" "several IDs -> one JSON array"
}

test_deploy_reports_listening() {
  assert_contains "$(cat "$OUT/$CUR.setup.log")" "listening on $(machine_ip):25565" "deploy output"
}

test_motd_from_env() {
  assert_eq "flk shadow server" "$(mcq description.text)" "MOTD from [env]"
}

test_fly_env_vars() {
  assert_eq "$APP" "$(mcq flk.app)" FLY_APP_NAME
  assert_eq "$(machine_id)" "$(mcq flk.machine_id)" FLY_MACHINE_ID
  assert_eq "$(machine_ip)" "$(mcq flk.ip)" FLY_PRIVATE_IP
  assert_eq local "$(mcq flk.region)" FLY_REGION
  assert_eq v1 "$(mcq flk.release)" FLK_RELEASE
}

test_runs_as_image_user() {
  assert_eq 0 "$(mcq flk.uid)" "uid (image has no USER)"
}

test_secret_delivered() {
  assert_eq "$(sha16 hunter2)" "$(mcq flk.secret_digest)" "MC_SECRET digest"
}

test_secret_update_restarts_machine() {
  flk secrets set MC_SECRET=correct-horse
  wait_mc 60
  assert_eq "$(sha16 correct-horse)" "$(mcq flk.secret_digest)" "MC_SECRET digest after set"
  assert_contains "$(flk secrets list)" MC_SECRET "secrets list"
}

test_volume_survives_restart() {
  ensure_up
  local b; b=$(mcq flk.boots)
  flk machine restart "$(machine_id)"
  wait_mc 60
  assert_eq $((b + 1)) "$(mcq flk.boots)" "boots after restart"
}

test_graceful_stop_saves_world() {
  local s saved=0; s=$(mcq flk.saves)
  local before; before=$(log_count "Saved the game")
  flk machine stop "$(machine_id)"
  is_stopped || fail "machine still running after stop"
  log_count_gt "$before" "Saved the game" && saved=1
  ensure_up
  ((saved)) || fail "app never logged 'Saved the game' on stop (no SIGTERM?)"
  assert_eq $((s + 1)) "$(mcq flk.saves)" "saves after stop/start"
}

test_volume_survives_redeploy() {
  ensure_up
  local b id; b=$(mcq flk.boots); id=$(machine_id)
  flk deploy
  wait_mc 60
  assert_eq "$id" "$(machine_id)" "machine id after redeploy"
  assert_eq $((b + 1)) "$(mcq flk.boots)" "boots after redeploy"
  assert_eq v2 "$(mcq flk.release)" "release after redeploy"
}

test_volume_attached_to_machine() {
  ensure_up
  assert_contains "$(flk volumes list)" "$(machine_id)" "volumes list"
  local out
  out=$(flk volumes destroy world 2>&1) && fail "destroyed a volume that's attached"
  assert_contains "$out" "attached"
}

test_proxy_forwards_to_vm() {
  ensure_up
  local port=$((25600 + RANDOM % 300)) pid
  "$FLK_BIN" -a "$APP" proxy "$port:25565" >/dev/null 2>&1 &
  pid=$!
  wait_until 10 mc_up 127.0.0.1 "$port" || { kill "$pid"; fail "no status ping through flk proxy on :$port"; }
  assert_eq "$APP" "$(mcping 127.0.0.1 "$port" -q flk.app)" "app via proxy"
  kill "$pid"
}

test_guest_egress_nat_and_dns() {
  host_online || skip_test "host is offline"
  ensure_up
  wait_until 10 egress_probed || fail "egress probe never finished"
  assert_eq true "$(mcq flk.egress.tcp)" "guest TCP to 1.1.1.1:53 (NAT)"
  assert_eq true "$(mcq flk.egress.dns)" "guest DNS lookup"
}

# Needs flk to honour kill_timeout: the world save takes 15s, longer than
# the default 10s before flk kills the VM.
test_kill_timeout_allows_slow_save() {
  grep -q kill_timeout "$FLK_SRC"/lib/flk/*.rb || pending "flk ignores kill_timeout (stop kills after 10s)"
  ensure_up
  toml_set 'SAVE_SECONDS' 'SAVE_SECONDS = "15"'
  flk deploy
  wait_mc 60
  local s; s=$(mcq flk.saves)
  flk machine stop "$(machine_id)"
  flk machine start "$(machine_id)"
  wait_mc 60
  assert_eq $((s + 1)) "$(mcq flk.saves)" "saves after a 15s save"
}

# [[services.ports]] -> nft DNAT on every host address.
test_reachable_on_host_lan_ip() {
  port_helper_ready || skip_test "port helper not installed; run: sudo ./setup-host.sh"
  ensure_up
  assert_contains "$(flk ports)" "tcp/$HOST_PORT" "flk ports"
  local ip; ip=$(host_lan_ip)
  mc_up "$ip" "$HOST_PORT" || fail "no status ping on $ip:$HOST_PORT"
  assert_eq "$APP" "$(mcping "$ip" "$HOST_PORT" -q flk.app)" "app answering on the LAN port"
}

# A host process listening on the port wins: flk drops the forward rather
# than steal its inbound traffic, and restores it once the port is free.
test_host_listener_blocks_forward() {
  port_helper_ready || skip_test "port helper not installed; run: sudo ./setup-host.sh"
  ensure_up
  ruby -rsocket -e 'TCPServer.new("0.0.0.0", ARGV[0].to_i); sleep' "$HOST_PORT" &
  local pid=$!
  wait_until 5 host_listening "$HOST_PORT" || { kill "$pid"; fail "test listener never bound"; }
  flk ports sync
  local ports; ports=$(flk ports)
  kill "$pid"; wait "$pid" 2>/dev/null || true
  assert_contains "$ports" "blocked: a host process is listening" "flk ports"
  [[ $(port_map) != *"$HOST_PORT :"* ]] || fail "port $HOST_PORT still forwarded while a host process listens"
  flk ports sync
  assert_contains "$(port_map)" "$HOST_PORT :" "forward restored after the listener exits"
}

# The helper is the root-side safety boundary: even called directly it
# refuses privileged and in-use host ports. Needs the helper from this tree.
test_port_helper_refuses_host_ports() {
  port_helper_ready || skip_test "port helper not installed; run: sudo ./setup-host.sh"
  grep -q '^min_port=' /usr/local/libexec/flk-ports || skip_test "installed helper predates the port guard; re-run: sudo ./setup-host.sh"
  local helper=/usr/local/libexec/flk-ports ip out
  ip=$(machine_ip)
  out=$(echo "tcp 1023 $ip 25565" | sudo -n "$helper" replace 2>&1) && { flk ports sync; fail "helper forwarded port 1023"; }
  assert_contains "$out" "below"
  ruby -rsocket -e 'TCPServer.new("0.0.0.0", ARGV[0].to_i); sleep' "$((HOST_PORT + 1))" &
  local pid=$!
  wait_until 5 host_listening "$((HOST_PORT + 1))" || { kill "$pid"; fail "test listener never bound"; }
  local rc=0
  out=$(echo "tcp $((HOST_PORT + 1)) $ip 25565" | sudo -n "$helper" replace 2>&1) || rc=$?
  kill "$pid"; wait "$pid" 2>/dev/null || true
  ((rc != 0)) || { flk ports sync; fail "helper forwarded a port a host process listens on"; }
  assert_contains "$out" "listening"
  flk ports sync # put the real map back
}

# The app exits / the VM dies without flk: flk's tmux hook (session-closed
# -> flk ports reap) drops (or hands over) its host port within moments,
# with no flk command run in between.
port_released() { [[ $(port_map) != *"$HOST_PORT :"* ]]; }
pid_gone() { [[ ! -e $FLK_HOME/apps/$APP/machines/$1/pid ]]; }

test_exited_machine_releases_host_port() {
  port_helper_ready || skip_test "port helper not installed; run: sudo ./setup-host.sh"
  ensure_up
  local id; id=$(machine_id)
  assert_contains "$(port_map)" "$HOST_PORT :" "forward before the crash"
  kill -KILL "$(cat "$FLK_HOME/apps/$APP/machines/$id/pid")"
  wait_until 10 port_released || fail "port $HOST_PORT still forwarded to the dead machine (tmux hook didn't run?)"
  wait_until 5 pid_gone "$id" || fail "stale pid file left behind"
  ensure_up
  assert_contains "$(port_map)" "$HOST_PORT :" "forward after restart"
}

# Host lifecycle: stop-all stops gracefully but remembers; resume brings back
# what should run and leaves explicitly stopped machines alone. -a keeps the
# tests off the host's real apps.
desired() { flk machine status "$(machine_id)" | json_get desired_state; }

test_stop_all_then_resume() {
  ensure_up
  local s; s=$(mcq flk.saves)
  "$FLK_BIN" -a "$APP" stop-all
  is_stopped || fail "still running after stop-all"
  assert_eq started "$(desired)" "desired state after stop-all"
  "$FLK_BIN" -a "$APP" resume
  wait_mc 60
  assert_eq $((s + 1)) "$(mcq flk.saves)" "stop-all let the world save"
}

test_resume_skips_machines_stopped_on_purpose() {
  ensure_up
  flk machine stop "$(machine_id)"
  assert_eq stopped "$(desired)" "desired state after machine stop"
  assert_contains "$("$FLK_BIN" -a "$APP" resume)" "Nothing to resume"
  is_stopped || fail "resume started a machine stopped with machine stop"
  flk machine start "$(machine_id)"
  assert_eq started "$(desired)" "desired state after machine start"
}
