# App-level start/stop/restart, machine verbs without an ID, and a new
# volume's root taking the owner of its mount point in the image (G14).
# One long-running hello machine with a volume.
TIER=vm

setup_file() {
  stage_app hello
  echo 'RUN mkdir -p /data && chown 1234:2345 /data' >>"$APP_DIR/Dockerfile"
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo up; exec sleep 600"]' \
              '[[restart]]' '  policy = "never"' \
              '[[mounts]]' '  source = "data"' '  destination = "/data"'
  flk launch --no-deploy
  flk volumes create data --size 1
  flk deploy
  wait_log "up" 30
}

teardown_file() { destroy_app; }

vol_path() { flk volumes list --json | json_get 0.path; }

test_new_volume_takes_the_mount_points_owner() {
  assert_contains "$(debugfs -R "stat /" "$(vol_path)" 2>/dev/null)" "User:  1234   Group:  2345" "volume root owner"
  assert_eq null "$(flk volumes list --json | json_get 0.owner_from_image)" "done once"
  assert_contains "$(flk exec --user 1234 -- sh -c 'touch /data/f && echo ok')" "ok" "the image's user can write"
}

test_machine_verbs_need_an_id() {
  local out
  out=$(flk machine stop 2>&1) && fail "machine stop without an ID did something"
  assert_contains "$out" "which machine? $APP's machines: $(machine_id)"
  assert_contains "$out" "flk stop (all of $APP's machines)"
  assert_eq started "$(machine_state)" "still running"
}

test_app_stop_start_restart() {
  local before
  assert_contains "$(flk stop)" "stopped (stays stopped"
  assert_eq stopped "$(machine_state)" "after flk stop"
  assert_contains "$(flk stop)" "Nothing of $APP is running"
  before=$(log_count "up")
  assert_contains "$(flk start)" "started"
  wait_until 30 log_count_gt "$before" "up" || fail "no boot after flk start"
  assert_contains "$(flk start)" "already running"
  before=$(log_count "up")
  assert_contains "$(flk restart)" "restarted"
  wait_until 30 log_count_gt "$before" "up" || fail "no boot after flk restart"
  assert_eq started "$(machine_state)" "after flk restart"
}
