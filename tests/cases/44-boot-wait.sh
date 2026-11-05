# What boot waits for (valheim.flk BUGS.flk.md #6): never a udp
# internal_port (30s and a false warning on every boot), and not during a
# deploy whose health checks come right after; plain starts still wait.
# One machine that listens on nothing; tests run in order.
TIER=vm

setup_file() {
  stage_app hello
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo up; exec sleep 600"]' \
              '[[restart]]' '  policy = "never"' \
              '[[services]]' '  internal_port = 2456' '  protocol = "udp"'
  flk launch --no-deploy
}

teardown_file() { destroy_app; }

test_udp_internal_port_isnt_waited_for() {
  local out t0=$SECONDS
  out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  (( SECONDS - t0 < 25 )) || fail "deploy took $((SECONDS - t0))s: it waited on udp"
  [[ $out == *"nothing listening"* ]] && fail "false warning: $out"
  assert_contains "$out" "udp/2456: flk can't tell when it's ready"
}

test_deploy_with_checks_leaves_readiness_to_them() {
  sed -i 's/protocol = "udp"/protocol = "tcp"/' "$APP_DIR/flk.toml"
  toml_append '[checks.up]' '  type = "log"' '  match = "^up$"'
  local out t0=$SECONDS
  out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  (( SECONDS - t0 < 25 )) || fail "deploy took $((SECONDS - t0))s: it waited before its checks"
  [[ $out == *"nothing listening"* ]] && fail "waited on tcp/2456 before the checks: $out"
  assert_contains "$out" "check up (log"
}

test_plain_restart_still_waits_on_tcp() {
  local out; out=$(flk machine restart "$(machine_id)" 2>&1) || fail "restart failed: $out"
  assert_contains "$out" "nothing listening on" "a start without checks to follow still reports the port"
}
