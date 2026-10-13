# An image without /bin/sh (FROM scratch) boots with flk's static init:
# env, volumes, exec, a graceful stop and the app's exit status.
TIER=vm

setup_file() {
  stage_app static
  flk launch --no-deploy
  flk volumes create data --size 1
  flk deploy
}

teardown_file() { destroy_app; }

exited_137() { flk events --json | grep -q '"machine.exited".*status 137'; }
booted() { log_has "hello from scratch, it's \$static"; }

test_boots_with_env_and_volume() {
  wait_until 30 booted || fail "the app never said hello"
  log_has "mounted volume /dev/vdc at /data" || fail "no volume"
  assert_eq /data "$(flk exec -- /busybox sh -c '/busybox touch /data/x && echo /data')" "exec, and the volume is writable"
  assert_contains "$(flk exec -- /busybox env)" "FLK_APP_NAME=$APP"
}

test_graceful_stop() {
  flk machine stop "$(machine_id)" >/dev/null
  log_has "got TERM" || fail "the app wasn't sent SIGTERM"
  log_has "app exited with status 0; powering off" || fail "no clean exit line"
  flk machine start "$(machine_id)" >/dev/null
  wait_until 30 booted || fail "no second boot"
}

test_exit_status_reaches_flk() {
  # the app is PID 1's child "sh"; KILL it: init reports 137, flk sees an exit
  flk exec -- /busybox sh -c 'kill -9 $(/busybox pgrep -P 1 -f "while true")' >/dev/null 2>&1 || true
  wait_until 30 log_has "app exited with status 137; powering off" || fail "no exit line with status 137"
  wait_until 30 exited_137 || fail "no machine.exited event with 137: $(flk events)"
}
