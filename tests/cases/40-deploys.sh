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
