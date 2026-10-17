# A host reboot as flk sees it: pid files left behind, flk resume and the
# boot-time reap (flk ports sync) both wanting to start the same machines,
# and pids from before the boot. From the 2026-10-16 mud reboot, where a
# losing start killed the machine that won (../mud/BUGS.flk.md #1-#3).
TIER=vm

setup_file() {
  stage_app hello
  flk launch --no-deploy
  sed -i '/^\[experimental\]/,$d' "$APP_DIR/flk.toml"
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo up; exec sleep 600"]' '[[restart]]' '  policy = "always"'
  flk deploy >/dev/null
}

teardown_file() { destroy_app; }

boots() { log_count "--- flk: booting" "${1:-}"; }
machine_running() { [[ $(machine_state "$@") == started ]]; }
pid_file() { echo "$FLK_HOME/apps/$APP/machines/${1:-$(machine_id)}/pid"; }
# firecracker processes of machine ID (each has its own API socket; not
# the tmux server, whose title can hold the command that started it)
fc_count() { pgrep -fc "^\S*firecracker .*/machines/${1:-$(machine_id)}/fc.sock" || true; }
fc_gone() { [[ $(fc_count "$@") == 0 ]]; }

# Power loss, as flk sees it: the tmux server and firecracker die without
# flk stopping anything (no exit hook runs) and the pid files stay. With
# backdate they predate the boot; that's done first, as any flk read
# command (lazyflk polls) may reap the moment firecracker is gone.
crash_host() {
  [[ ${1:-} == backdate ]] && touch -d "@$(($(awk '/^btime/ {print $2}' /proc/stat) - 60))" "$(pid_file)"
  kill -KILL "$(tmux -L "$FLK_TMUX_SOCKET" display-message -p '#{pid}')"
  wait_until 10 fc_gone || fail "firecracker outlived its tmux server"
}

event_details() { flk events --json --since 2m | ruby -rjson -e '$stdin.each_line { puts JSON.parse(_1)["detail"] }'; }

test_second_start_leaves_running_machine_alone() {
  wait_until 30 machine_running || fail "not running"
  local pid; pid=$(cat "$(pid_file)")
  local out; out=$(flk machine start "$(machine_id)" 2>&1) && fail "second start succeeded"
  assert_contains "$out" "already running"
  [[ -f $(pid_file) ]] || fail "the failed start removed the pid file"
  assert_eq "$pid" "$(cat "$(pid_file)")" "pid"
  kill -0 "$pid" 2>/dev/null || fail "the failed start killed the machine"
  machine_running || fail "not running after the failed start"
}

test_concurrent_starts_boot_once() {
  flk machine stop "$(machine_id)" >/dev/null
  local b; b=$(boots)
  local out; out=$(mktemp)
  flk machine start "$(machine_id)" >"$out.1" 2>&1 & local p1=$!
  flk machine start "$(machine_id)" >"$out.2" 2>&1 & local p2=$!
  local ok=0; wait $p1 && ok=$((ok + 1)); wait $p2 && ok=$((ok + 1))
  local both; both=$(cat "$out.1" "$out.2"); rm -f "$out" "$out.1" "$out.2"
  assert_eq 1 "$ok" "starts that succeeded ($both)"
  assert_contains "$both" "already running"
  machine_running || fail "not running"
  assert_eq 1 "$(fc_count)" "firecracker processes"
  assert_eq $((b + 1)) "$(boots)" "boots"
}

# The boot-time reap must not treat a reboot as a crash: no revive, flk
# resume brings it back.
test_reboot_is_not_a_crash() {
  wait_until 30 machine_running || fail "not running"
  crash_host backdate
  local b; b=$(boots)
  flk ports reap
  sleep 4 # a revive would boot after 1s
  assert_eq "$b" "$(boots)" "boots after the reap (a restart policy revive?)"
  [[ -f $(pid_file) ]] && fail "reap left the stale pid file"
  assert_contains "$(event_details)" "the host went down with it running"
  "$FLK_BIN" -a "$APP" resume || fail "resume failed"
  machine_running || fail "not running after resume"
}

# A real crash (pid from this boot) still gets its revive; flk resume at the
# same moment must not fail or kill it, and the machine boots once.
test_resume_and_revive_race() {
  wait_until 30 machine_running || fail "not running"
  crash_host
  local b; b=$(boots)
  flk ports reap & local reap=$!
  local out; out=$(mktemp)
  "$FLK_BIN" -a "$APP" resume >"$out" 2>&1 & local res=$!
  wait $reap
  wait $res || fail "resume failed: $(cat "$out")"
  rm -f "$out"
  sleep 4 # the revive's backoff
  machine_running || fail "not running"
  assert_eq 1 "$(fc_count)" "firecracker processes"
  assert_eq $((b + 1)) "$(boots)" "boots"
}

# A pid file naming another machine's firecracker (pids reused after a
# reboot) mustn't make it look running, nor let stop kill the other one.
test_pid_of_another_machine() {
  flk scale count 2 >/dev/null
  local a b; a=$(machine_id 1) b=$(machine_id 2)
  wait_until 30 machine_running "$a" || fail "$a not running"
  flk machine stop "$b" >/dev/null
  local pa; pa=$(cat "$(pid_file "$a")")
  echo "$pa" >"$(pid_file "$b")"
  machine_running "$b" && fail "$b counts as running on $a's pid"
  flk machine stop "$b" >/dev/null 2>&1
  kill -0 "$pa" 2>/dev/null || fail "stopping $b killed $a"
  machine_running "$a" || fail "$a not running"
  tmux -L "$FLK_TMUX_SOCKET" display-message -p '#{pid}' >"$(pid_file "$b")"
  machine_running "$b" && fail "$b counts as running on the tmux server's pid"
  flk scale count 1 >/dev/null
}
