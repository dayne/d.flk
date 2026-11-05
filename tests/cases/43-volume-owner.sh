# A new volume's owner when the image has no mount point for it
# (valheim.flk BUGS.flk.md #4): the image's USER, once, and only while the
# volume is empty. Tests run in order on one machine.
TIER=vm

setup_file() {
  stage_app hello
  echo 'RUN adduser -D -u 1100 app' >>"$APP_DIR/Dockerfile" # no /data in the image
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo up; exec sleep 600"]' \
              '[[restart]]' '  policy = "never"' \
              '[[mounts]]' '  source = "data"' '  destination = "/data"'
  flk launch --no-deploy
  flk volumes create data --size 1
  flk volumes create fresh --size 1
}

teardown_file() { destroy_app; }

vol() { flk volumes list --json | ruby -rjson -e 'v = JSON.parse($stdin.read).find { _1["name"] == ARGV[0] }
  puts v[ARGV[1]].nil? ? "null" : v[ARGV[1]]' "$1" "$2"; }
owner() { debugfs -R "stat /" "$(vol "$1" path)" 2>/dev/null | sed -n 's/.*User: *\([0-9]*\) *Group: *\([0-9]*\).*/\1:\2/p'; }

test_root_image_leaves_an_empty_volume_for_later() {
  flk deploy >/dev/null 2>&1 || fail "deploy failed"
  wait_log "up" 30
  assert_eq 0:0 "$(owner data)" "owner with a root image"
  assert_eq true "$(vol data owner_from_image)" "still to decide (the volume is empty)"
}

test_a_volume_with_data_is_never_reowned() {
  flk exec -- touch /data/kept >/dev/null || fail "exec failed"
  echo 'USER app' >>"$APP_DIR/Dockerfile"
  local out; out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  [[ $out == *"volume data: root now owned"* ]] && fail "re-owned a volume with data: $out"
  assert_eq 0:0 "$(owner data)" "owner kept"
  assert_eq null "$(vol data owner_from_image)" "decided: it's in use"
}

test_new_volume_takes_the_image_users_owner() {
  sed -i 's/source = "data"/source = "fresh"/' "$APP_DIR/flk.toml"
  local out; out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  assert_contains "$out" "volume fresh: root now owned by 1100:1100 (the image's USER app; /data isn't in the image)"
  assert_eq 1100:1100 "$(owner fresh)" "owner"
  assert_eq null "$(vol fresh owner_from_image)" "done once"
  # Alpine's busybox setpriv has no --reuid: init used to call it anyway and
  # the app died at boot. Now it falls back (as root, with a warning; the
  # TODO's setpriv entry is the real fix).
  local before; before=$(log_count "can't switch to user")
  wait_until 30 log_count_gt "$before" "can't switch to user" || fail "init didn't fall back to root: $(console_log | tail -5)"
  wait_log "up" 10
  assert_eq started "$(machine_state)" "machine running"
  assert_contains "$(flk exec --user 1100 -- sh -c 'touch /data/f && echo ok')" "ok" "the image's user can write"
}
