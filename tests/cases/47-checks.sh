# Health while running (enshrouded BUGS #3): flk check runs a machine's
# [checks] again, keeps the last result per machine for flk status, and
# sends an event only when a result changes. One mcshadow machine; tests
# run in order and build on each other. The exec check fails while
# /tmp/sick exists in the machine.
TIER=vm

setup_file() {
  stage_app mcshadow
  toml_append '' '[checks.ready]' '  type = "log"' '  match = '"'"'Done \('"'"'' '  interval = "1m"' \
    '' '[checks.port]' '  type = "tcp"' '  port = 25565' '  interval = "1m"' \
    '' '[checks.well]' '  type = "exec"' '  command = "test ! -e /tmp/sick"' '  interval = "5m"' \
    '' '[checks.once]' '  type = "tcp"' '  port = 25565' \
    '' '[checks.room]' '  type = "disk"' '  path = "/data"' '  max_percent = 50' '  interval = "5m"'
  flk launch --no-deploy
  flk volumes create world --size 1
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; }

check_field() { flk status --json | json_get "machines.0.checks.$1"; } # NAME.FIELD
event_count() { flk events --json -n 500 | grep -c "\"type\":\"$1\".*$2" || true; } # TYPE DETAIL_PART
check_rc() { local rc=0; flk check "$@" >"$WORK/check.out" 2>&1 || rc=$?; echo "$rc"; }

test_deploy_keeps_what_its_checks_found() {
  local name
  for name in ready port well once room; do
    assert_eq true "$(check_field "$name.ok")" "$name after the deploy"
  done
  assert_eq 60 "$(check_field port.interval)" "interval in status"
  assert_eq null "$(check_field once.interval)" "no interval"
  assert_eq log "$(check_field ready.type)" "type in status"
  [[ $(check_field port.since) == 20* ]] || fail "no since: $(check_field port)"
  local out; out=$(flk status)
  assert_contains "$out" "Checks"
  assert_contains "$out" "tcp :25565"
  assert_contains "$out" "deploys only" "a check without an interval"
  assert_contains "$out" "found since this boot" "the log check"
}

test_check_runs_them_now() {
  local before; before=$(check_field port.at)
  sleep 1
  assert_eq 0 "$(check_rc)" "flk check with everything passing: $(cat "$WORK/check.out")"
  assert_contains "$(cat "$WORK/check.out")" "well"
  assert_ne "$before" "$(check_field port.at)" "port.at after flk check"
  local j; j=$(flk check --json)
  assert_eq 5 "$(ruby -rjson -e 'puts JSON.parse($stdin.read).size' <<<"$j")" "rows"
  assert_eq "$APP" "$(json_get 0.app <<<"$j")" "app in --json"
  assert_eq true "$(json_get 2.ok <<<"$j")" "well in --json"
  assert_eq "$(machine_id)" "$(json_get 2.machine <<<"$j")" "machine in --json"
  assert_eq 0 "$(event_count check.failed "")" "check.failed events so far"
}

test_due_runs_nothing_before_its_time() {
  assert_eq "[]" "$(flk check --due --json | tr -d ' \n')" "--due right after a run"
  assert_contains "$(flk check --due)" "No checks were due"
}

test_a_failing_check_is_reported_once() {
  flk exec -- touch /tmp/sick
  assert_eq 2 "$(check_rc)" "flk check with a failing check: $(cat "$WORK/check.out")"
  assert_contains "$(cat "$WORK/check.out")" "failing"
  assert_eq false "$(check_field well.ok)" "well in status"
  assert_contains "$(check_field well.detail)" "exit 1" "why"
  assert_eq true "$(check_field ready.ok)" "the log check stays passed"
  assert_eq true "$(check_field port.ok)" "the tcp check still passes"
  local since; since=$(check_field well.since)
  sleep 1
  assert_eq 2 "$(check_rc)" "still failing"
  assert_eq "$since" "$(check_field well.since)" "since doesn't move while it keeps failing"
  assert_eq 1 "$(event_count check.failed well)" "check.failed events for one failure"
  assert_contains "$(flk status)" "failing for"
  local ctx; ctx=$(flk context --no-host)
  assert_contains "$ctx" "check well has been failing"
  [[ $ctx != *"all good"* ]] || fail "context says all good with a failing check"
  # a failing check is due at every run, whatever its interval
  local j; j=$(flk check --due --json || true)
  assert_eq '["well"]' "$(ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read).map { _1["name"] })' <<<"$j")" "--due with a failing check"
}

test_recovery_is_an_event() {
  flk exec -- rm /tmp/sick
  assert_eq 0 "$(check_rc)" "flk check after the fix: $(cat "$WORK/check.out")"
  assert_eq true "$(check_field well.ok)" "well in status"
  assert_eq null "$(check_field well.detail)" "no detail once it passes"
  assert_eq 1 "$(event_count check.recovered well)" "check.recovered events"
  assert_eq 1 "$(event_count check.failed well)" "check.failed events"
  [[ $(flk context --no-host) != *"has been failing"* ]] || fail "context still lists the check as failing"
}

# type = "disk": the volume at /data (1GB) fills past max_percent = 50, the
# check says how full it is, and passes again once there is room.
test_a_full_disk_is_a_failing_check() {
  assert_contains "$(flk status)" "disk /data under 50%"
  flk exec --user root -- fallocate -l 600M /data/fill
  assert_eq 2 "$(check_rc)" "flk check with /data 60% full: $(cat "$WORK/check.out")"
  assert_eq false "$(check_field room.ok)" "room in status"
  assert_contains "$(check_field room.detail)" "/data is 6" "how full"
  assert_contains "$(check_field room.detail)" "% full (limit 50%)"
  assert_eq true "$(check_field well.ok)" "the other checks still pass"
  flk exec --user root -- rm /data/fill
  assert_eq 0 "$(check_rc)" "flk check after freeing it: $(cat "$WORK/check.out")"
  assert_eq true "$(check_field room.ok)" "room in status"
  assert_eq "1 1" "$(event_count check.failed room) $(event_count check.recovered room)" "one event each way"
}

# Results belong to a boot. Right after one, a check that doesn't pass yet
# is "starting", not failed; --due leaves it alone for its grace period.
test_a_new_boot_starts_clean() {
  flk machine restart "$(machine_id)" >/dev/null
  assert_eq "[]" "$(flk check --due --json | tr -d ' \n')" "--due inside the grace period"
  flk check >"$WORK/check.out" 2>&1 || fail "flk check during the boot failed: $(cat "$WORK/check.out")"
  assert_eq 2 "$(event_count check.failed "")" "no new check.failed while it boots"
  wait_mc 60
  wait_log "Done ("
  assert_eq 0 "$(check_rc)" "flk check after the boot: $(cat "$WORK/check.out")"
  assert_eq true "$(check_field ready.ok)" "the log check, found again this boot"
  (($(event_count check.passed "ready (log") >= 2)) || fail "no check.passed for the first pass since the boot"
}

# The timer's run: every app, only what's due, and a note of when it ran
# (flk doctor warns when checks have an interval and nothing runs them).
test_the_runner_marks_its_run() {
  local rc=0
  "$FLK_BIN" check --all --due --json >/dev/null || rc=$?
  ((rc == 0 || rc == 2)) || fail "flk check --all --due exited $rc"
  local at; at=$(json_get at <"$FLK_HOME/check-run.json")
  (($(date +%s) - $(date -d "$at" +%s) < 60)) || fail "check-run.json wasn't written now: $at"
  local label; label=$(flk doctor --json | ruby -rjson -e 'puts JSON.parse($stdin.read)["checks"].map { _1["label"] }.grep(/flk-check.timer/).first.to_s')
  [[ -n $label ]] || fail "doctor says nothing about the timer while $APP has checks with an interval"
}

test_a_stopped_machine_is_skipped() {
  flk machine stop "$(machine_id)" >/dev/null
  assert_eq 0 "$(check_rc)" "flk check with the machine stopped: $(cat "$WORK/check.out")"
  assert_contains "$(cat "$WORK/check.out")" "the machine is stopped"
  assert_eq "[]" "$(flk check --due --json | tr -d ' \n')" "--due with the machine stopped"
  assert_eq null "$(check_field port.ok)" "status doesn't keep a stopped machine's results"
}
