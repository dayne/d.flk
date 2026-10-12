# hello: build, boot, print, exit, power off. The smallest end-to-end loop.
TIER=vm

setup_file() {
  stage_app hello
  flk launch --no-deploy
  flk deploy
}

teardown_file() { destroy_app; }

test_prints_hello_world() {
  wait_log "hello world" 30
}

test_fly_env_in_guest() {
  wait_log "app=$APP region=local release=v1" 30
}

test_app_exit_powers_off_vm() {
  wait_until 30 is_stopped || fail "machine still running after app exited"
  wait_log "app exited with status 0; powering off" 5
}

test_machine_start_boots_again() {
  wait_until 30 is_stopped
  local before; before=$(log_count "hello world")
  flk machine start "$(machine_id)"
  wait_until 30 log_count_gt "$before" "hello world" || fail "no second 'hello world' after machine start"
}

test_redeploy_keeps_machine() {
  wait_until 30 is_stopped
  local id; id=$(machine_id)
  flk deploy
  assert_eq "$id" "$(machine_id)" "machine id after redeploy"
  assert_eq 1 "$(machine_count)" "machine count"
  wait_log "release=v2" 30
}

test_experimental_cmd_and_exit_status() {
  wait_until 30 is_stopped
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo custom cmd; exit 3"]' \
              '[[restart]]' '  policy = "never"' # restarts are 12-restart's business
  flk deploy
  wait_log "custom cmd" 30
  wait_log "app exited with status 3" 10
}

test_old_releases_pruned() {
  wait_until 30 is_stopped
  flk deploy
  local n; n=$(ls "$FLK_HOME/apps/$APP/images"/v*.ext4 | wc -l)
  ((n <= 2)) || fail "expected at most 2 release images, found $n"
  local rels; rels=$(flk releases)
  assert_contains "$rels" "v1" "releases list keeps history"
}

test_stop_when_already_stopped() {
  wait_until 30 is_stopped
  assert_ok flk machine stop "$(machine_id)"
}
