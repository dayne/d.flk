# Safer deploys: config typos warn, health checks gate the roll (a failing
# machine goes back to its previous release), releases rollback. One
# mcshadow machine; tests run in order and build on each other.
TIER=vm

setup_file() {
  stage_app mcshadow
  flk launch --no-deploy
  flk volumes create world --size 1
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; }

release_of_machine() { flk machine list --json | json_get 0.release; }
release_field() { flk releases --json | ruby -rjson -e 'r = JSON.parse($stdin.read).find { _1["version"] == ARGV[0].to_i }
  v = r && r[ARGV[1]]; puts v.is_a?(String) ? v : JSON.generate(v)' "$1" "$2"; }
current_release() { flk releases --json | ruby -rjson -e 'puts JSON.parse($stdin.read).find { _1["current"] }["version"]'; }
set_checks() { sed -i '/^\[checks/,$d' "$APP_DIR/flk.toml"; toml_append "$@"; } # replace the [checks] tables (they're last)

test_typo_in_config_warns() {
  sed -i '1i kill_timout = 60' "$APP_DIR/flk.toml"
  local out; out=$(flk config show)
  assert_contains "$(json_get warnings <<<"$out")" "kill_timout (did you mean kill_timeout?)"
  sed -i '1d' "$APP_DIR/flk.toml"
  assert_eq "[]" "$(flk config show | json_get warnings)" "no warnings once fixed"
}

test_failing_check_rolls_the_machine_back() {
  set_checks '' '[checks.never]' '  type = "tcp"' '  port = 9' '  grace_period = "4s"'
  local out
  out=$(flk deploy 2>&1) && fail "deploy passed a check nothing answers"
  assert_contains "$out" "v2 failed its health checks"
  assert_contains "$out" "is back on v1"
  assert_contains "$(tail -n 1 <<<"$out")" "Next: flk logs -i $(machine_id) --no-tail" "next step after a failed check"
  assert_eq 1 "$(release_of_machine)" "machine release after the failed deploy"
  assert_eq failed "$(release_field 2 status)" "v2 status"
  assert_eq 1 "$(current_release)" "current release"
  wait_mc 60
  assert_contains "$(flk releases)" "failed: check never"
}

test_events_of_a_failed_deploy() {
  local ev; ev=$(flk events --json | ruby -rjson -e '$stdin.each_line { e = JSON.parse(_1); puts "#{e["type"]} v#{e["release"]} #{e["detail"]}" }')
  local t
  for t in "deploy.started v2" "check.failed v2 never" "machine.rolled_back v1" "deploy.failed v2" "deploy.succeeded v1" "machine.created v1"; do
    assert_contains "$ev" "$t" "events"
  done
}

test_no_rollback_leaves_the_machine_for_debugging() {
  local out
  out=$(flk deploy --no-rollback 2>&1) && fail "deploy passed a failing check"
  assert_contains "$out" "was left on v3"
  assert_eq 3 "$(release_of_machine)" "machine stays on the failed release"
  assert_eq 1 "$(current_release)" "current release is still v1"
  out=$(flk context --json --no-host | json_get next_steps)
  assert_contains "$out" "is on v3, which failed its health checks (left by --no-rollback)"
  assert_contains "$out" "flk releases rollback v1"
  [[ $out == *"older release"* ]] && fail "context calls the failed release older: $out"
  true
}

test_passing_checks_deploy() {
  set_checks '' '[checks.done]' '  type = "log"' '  match = "Done \\("' \
    '' '[checks.port]' '  type = "tcp"' '  port = 25565' '  grace_period = "30s"'
  local out
  out=$(flk deploy 2>&1) || fail "deploy with passing checks failed: $out"
  assert_contains "$out" "check done (log"
  assert_contains "$out" "check port (tcp :25565"
  assert_eq 4 "$(release_of_machine)" "machine release"
  assert_eq 4 "$(current_release)" "current release"
  wait_mc 60
}

test_rollback_brings_back_image_and_config() {
  toml_set 'MOTD' 'MOTD = "rolled forward"'
  flk deploy >/dev/null 2>&1 || fail "deploy v5 failed"
  wait_mc 60
  assert_eq "rolled forward" "$(mcq description.text)" "v5 config"
  local out
  out=$(flk releases rollback 2>&1) || fail "rollback failed: $out"
  assert_contains "$out" "rollback to v4"
  assert_eq 6 "$(release_of_machine)" "rollback makes a new release"
  assert_eq 4 "$(release_field 6 rollback_of)" "rollback_of"
  wait_mc 60
  assert_eq "flk shadow server" "$(mcq description.text)" "v4's config is back"
}

test_rollback_refuses_pruned_and_failed_releases() {
  local out
  out=$(flk releases rollback v1 2>&1) && fail "rolled back to a pruned image"
  assert_contains "$out" "image was pruned"
  out=$(flk releases rollback v2 2>&1) && fail "rolled back to a failed release"
  assert_contains "$out" "failed its health checks"
  out=$(flk releases rollback v6 2>&1) && fail "rolled back to the current release"
  assert_contains "$out" "already the current release"
}

# after deploy --no-rollback, plain rollback goes back to the last good
# release (the current one), not the one before it
test_rollback_after_no_rollback_returns_to_current() {
  set_checks '' '[checks.never]' '  type = "tcp"' '  port = 9' '  grace_period = "4s"'
  flk deploy --no-rollback >/dev/null 2>&1 && fail "deploy passed a check nothing answers"
  assert_eq 7 "$(release_of_machine)" "left on the failed release"
  local out
  out=$(flk releases rollback 2>&1) || fail "rollback failed: $out"
  assert_contains "$out" "rollback to v6"
  assert_eq 8 "$(release_of_machine)" "rollback release"
  assert_eq 6 "$(release_field 8 rollback_of)" "rollback_of the last good release"
  wait_mc 60
}

# flk's exec and udp checks (M6): a command in the guest, a datagram that
# gets a reply. mcshadow answers A2S_INFO on its port over udp.
A2S='FFFFFFFF54536F7572636520456E67696E6520517565727900'

test_exec_and_udp_checks_pass() {
  set_checks '' '[checks.world]' '  type = "exec"' '  command = "test -f /data/world/level.json"' \
    '' '[checks.query]' '  type = "udp"' '  port = 25565' "  send_hex = \"$A2S\"" '  expect = '"'"'\A\xFF\xFF\xFF\xFFI'"'"''
  local out
  out=$(flk deploy 2>&1) || fail "deploy with passing exec and udp checks failed: $out"
  assert_contains "$out" "check world (exec sh -c"
  assert_contains "$out" "check query (udp :25565"
  assert_contains "$(flk events --json -n 20)" "query (udp :25565) in"
}

test_failing_exec_check_says_why() {
  set_checks '' '[checks.world]' '  type = "exec"' '  command = "echo no world here; exit 3"' '  grace_period = "3s"'
  local out before; before=$(release_of_machine)
  out=$(flk deploy 2>&1) && fail "deploy passed an exec check that exits 3"
  assert_contains "$out" "check world (exec sh -c"
  assert_contains "$out" "last try: exit 3: no world here"
  assert_eq "$before" "$(release_of_machine)" "the machine went back"
}

test_udp_check_without_a_reply_fails() {
  set_checks '' '[checks.query]' '  type = "udp"' '  port = 25565' '  send = "hello"' '  timeout = 1' '  grace_period = "3s"'
  local out
  out=$(flk deploy 2>&1) && fail "deploy passed a udp check nothing replies to"
  assert_contains "$out" "last try: no reply within 1s"
  set_checks '' '[checks.closed]' '  type = "udp"' '  port = 9' '  send = "x"' '  grace_period = "3s"'
  out=$(flk deploy 2>&1) && fail "deploy passed a udp check on a closed port"
  assert_contains "$out" "port 9/udp is closed"
  wait_mc 60
}

test_preflight_stops_the_deploy_before_the_build() {
  set_checks '' '[deploy]' '  preflight = "echo checking $FLK_APP v$FLK_RELEASE in $(basename $PWD); echo stale pin >&2; exit 4"'
  local out n; n=$(flk releases --json | ruby -rjson -e 'puts JSON.parse($stdin.read).size')
  out=$(flk deploy 2>&1) && fail "deploy went on after a failing preflight"
  assert_contains "$out" "checking $APP v$((n + 1)) in $(basename "$APP_DIR")" "preflight env and directory"
  assert_contains "$out" "preflight failed (exit 4): stale pin"
  assert_contains "$out" "preflight failed; machines unchanged"
  assert_contains "$out" "flk deploy --no-preflight"
  [[ $out != *"Building"* ]] || fail "the deploy built after a failing preflight: $out"
  assert_eq "$n" "$(flk releases --json | ruby -rjson -e 'puts JSON.parse($stdin.read).size')" "no release recorded"
  assert_contains "$(flk events --json -n 5)" "preflight failed; machines unchanged"
  out=$(flk deploy --no-preflight 2>&1) || fail "deploy --no-preflight failed: $out"
  assert_contains "$out" "Skipping [deploy] preflight (--no-preflight)"
  wait_mc 60
}
