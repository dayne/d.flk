# scale: several machines per app, each with its own IP and volume.
TIER=vm

setup_file() {
  stage_app mcshadow
  flk launch --no-deploy
  flk volumes create world --size 1
  flk volumes create world --size 1
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; }

test_scale_up_to_two() {
  flk scale count 2
  assert_eq 2 "$(machine_count)" "machines"
  wait_mc 60 "$(machine_ip 2)"
}

test_machines_have_distinct_ips_and_ids() {
  assert_ne "$(machine_ip 1)" "$(machine_ip 2)" "machine IPs"
  assert_eq "$(machine_ip 2)" "$(mcq flk.ip "$(machine_ip 2)")" "machine 2 sees its own IP"
  assert_ne "$(mcq flk.machine_id "$(machine_ip 1)")" "$(mcq flk.machine_id "$(machine_ip 2)")" "machine ids"
}

# The host port belongs to the first running machine; when it stops, the
# next one takes over, and it comes back when the first restarts.
test_host_port_follows_running_machine() {
  port_helper_ready || skip_test "port helper not installed; run: sudo ./setup-host.sh"
  local ip m1 m2; ip=$(host_lan_ip); m1=$(machine_id 1); m2=$(machine_id 2)
  assert_eq "$m1" "$(mcping "$ip" "$HOST_PORT" -q flk.machine_id)" "owner with both running"
  flk machine stop "$m1"
  assert_eq "$m2" "$(mcping "$ip" "$HOST_PORT" -q flk.machine_id)" "owner after machine 1 stops"
  flk machine start "$m1"
  wait_mc 60 "$(machine_ip 1)"
  assert_eq "$m1" "$(mcping "$ip" "$HOST_PORT" -q flk.machine_id)" "owner after machine 1 restarts"
}

# G4: a running machine has a pid, and stats report its CPU and memory.
test_machine_pid_and_stats() {
  local pid; pid=$(flk machine list --json | json_get 0.pid)
  [[ $pid =~ ^[0-9]+$ ]] && [[ -d /proc/$pid ]] || fail "machine list --json pid: $pid"
  local s; s=$(flk machine stats --json "$(machine_id 1)" | json_get 0)
  assert_eq "$pid" "$(json_get pid <<<"$s")" "stats pid"
  [[ $(json_get rss_mb <<<"$s") -gt 0 ]] || fail "rss_mb: $s"
  [[ $(json_get uptime_s <<<"$s") =~ ^[0-9]+$ ]] || fail "uptime_s: $s"
  ruby -e 'exit Float(ARGV[0]) >= 0 ? 0 : 1' "$(json_get cpu_percent <<<"$s")" || fail "cpu_percent: $s"
}

test_each_machine_has_its_own_volume() {
  local vols; vols=$(flk volumes list)
  assert_contains "$vols" "$(machine_id 1)" "volume for machine 1"
  assert_contains "$vols" "$(machine_id 2)" "volume for machine 2"
}

test_scale_beyond_volumes_fails_cleanly() {
  local out
  out=$(flk scale count 3 2>&1) && fail "scaled past the number of volumes"
  assert_contains "$out" "not enough free volumes"
  assert_eq 2 "$(machine_count)" "machines after failed scale"
  assert_eq 2 "$(flk context --json | json_get app.scale)" "recorded scale after failed scale"
}

test_scale_down_frees_volume() {
  flk scale count 1
  assert_eq 1 "$(machine_count)" "machines"
  mc_up "$(machine_ip 1)" || fail "remaining machine stopped answering"
  local free; free=$(flk volumes list | grep -c ' - ' || true)
  assert_eq 1 "$free" "unattached volumes"
}

# A volume whose file is gone (its disk isn't mounted) stops the start,
# instead of booting without it.
test_missing_volume_file_blocks_start() {
  local m out path; m=$(machine_id 1)
  path=$(flk volumes list --json | ruby -rjson -e 'm = ARGV[0]; v = JSON.parse($stdin.read).find { _1["attached_machine"] == m }; puts v["path"]' "$m")
  [[ -f $path ]] || fail "no volume path for $m"
  flk machine stop "$m"
  mv "$path" "$path.away"
  out=$(flk machine start "$m" 2>&1) && { mv "$path.away" "$path"; fail "started without its volume"; }
  mv "$path.away" "$path"
  assert_contains "$out" "is missing"
  flk machine start "$m"
  wait_mc 60 "$(machine_ip 1)"
}
