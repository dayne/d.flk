# Restart policy ([[restart]]): what happens when the app exits on its own.
# The tmux exit hook notices, `flk machine revive` backs off (1s, 2s, ...)
# and boots. flk's own stops never count as exits.
TIER=vm

setup_file() {
  stage_app hello
  flk launch --no-deploy
}

teardown_file() { destroy_app; }

boots() { log_count "--- flk: booting"; }
# set_cmd CMD POLICY [RETRIES]: replace [experimental] / [[restart]] and deploy
set_app() {
  sed -i '/^\[experimental\]/,$d' "$APP_DIR/flk.toml"
  toml_append '[experimental]' "  cmd = [\"sh\", \"-c\", \"$1\"]" '[[restart]]' "  policy = \"$2\"" "  retries = ${3:-10}"
  flk deploy >/dev/null
}

test_on_failure_restarts_then_gives_up() {
  local b0; b0=$(boots)
  set_app "echo crashing; exit 3" on-failure 2
  # first boot + 2 restarts (after 1s and 2s), then it gives up
  wait_until 30 log_has "gave up after 2 restarts in a row" || fail "never gave up; boots: $(( $(boots) - b0 ))"
  assert_eq 3 "$(( $(boots) - b0 ))" "boots: the first plus 2 restarts"
  log_has "restart policy on-failure: exit status 3, restart 1 of 2" || fail "no restart note in the log"
  is_stopped || fail "still running after giving up"
  assert_contains "$(flk context)" "restart policy gave up after 2 restarts" "context next step"
  local ev; ev=$(flk events --json --since 2m | ruby -rjson -e '$stdin.each_line { e = JSON.parse(_1); puts "#{e["type"]} #{e["detail"]}" }')
  assert_contains "$ev" "machine.exited the app exited with status 3"
  [[ $(grep -c "^machine.restarted" <<<"$ev") == 2 ]] || fail "expected 2 machine.restarted events: $ev"
  assert_contains "$ev" "machine.gave_up after 2 restarts in a row"
}

test_clean_exit_not_restarted_on_failure() {
  set_app "echo done; exit 0" on-failure
  wait_until 30 is_stopped
  local b; b=$(boots)
  sleep 4
  assert_eq "$b" "$(boots)" "boots after a clean exit"
}

test_always_restarts_a_clean_exit() {
  local b0; b0=$(boots)
  set_app "echo done; exit 0" always 1
  wait_until 30 log_has "gave up after 1 restarts in a row" || fail "always didn't restart"
  assert_eq 2 "$(( $(boots) - b0 ))" "boots: the first plus 1 restart"
}

test_crash_is_restarted() {
  set_app "echo up; exec sleep 600" on-failure
  wait_log "up" 30
  local b; b=$(boots)
  kill -KILL "$(cat "$FLK_HOME/apps/$APP/machines/$(machine_id)/pid")"
  wait_until 20 log_count_gt "$b" "--- flk: booting" || fail "not restarted after firecracker was killed"
  log_has "exit status none, restart 1" || fail "crash not noted as 'exit status none'"
  wait_until 10 machine_running || fail "not running after the restart"
}

machine_running() { [[ $(machine_state) == started ]]; }

test_flk_stops_are_not_exits() {
  set_app "echo up; exec sleep 600" always
  wait_until 30 machine_running
  local b; b=$(boots)
  flk machine stop "$(machine_id)"
  sleep 4
  is_stopped || fail "machine stop was undone by the restart policy"
  flk machine start "$(machine_id)"
  wait_until 30 machine_running
  b=$(boots)
  "$FLK_BIN" -a "$APP" stop-all
  sleep 4
  is_stopped || fail "stop-all was undone by the restart policy"
  assert_eq "$b" "$(boots)" "boots after stop-all"
}

test_restart_config_rules() {
  sed -i '/^\[experimental\]/,$d' "$APP_DIR/flk.toml"
  toml_append '[[restart]]' '  policy = "sometimes"'
  local out
  out=$(flk config show 2>&1) && fail "accepted policy = sometimes"
  assert_contains "$out" "policy must be always, on-failure or never"
}
