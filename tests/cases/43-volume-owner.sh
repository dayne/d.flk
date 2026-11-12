# A new volume's owner when the image has no mount point for it
# (valheim.flk BUGS.flk.md #4): the image's USER, once, and only while the
# volume is empty. Tests run in order on one machine.
TIER=vm

setup_file() {
  stage_app hello
  echo 'RUN adduser -D -u 1100 app' >>"$APP_DIR/Dockerfile" # no /data in the image
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo up as $(id -u); exec sleep 600"]' \
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
  # ... and says the app can't write to it, with the fix (PLAN M6 warnings)
  assert_contains "$out" "volume data ("
  assert_contains "$out" "the app, as app (1100), can't write to it"
  assert_contains "$out" "flk files chown 1100:1100 data:/"
  # (the next deploy's own check sees it too, now it's decided)
  out=$(flk build --json 2>/dev/null)
  assert_contains "$out" '"code": "volume-not-writable"'
}

test_new_volume_takes_the_image_users_owner() {
  sed -i 's/source = "data"/source = "fresh"/' "$APP_DIR/flk.toml"
  local out; out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  assert_contains "$out" "volume fresh: root now owned by 1100:1100 (the image's USER app; /data isn't in the image)"
  assert_eq 1100:1100 "$(owner fresh)" "owner"
  assert_eq null "$(vol fresh owner_from_image)" "done once"
  # Alpine's busybox setpriv has no --reuid: init used to call it anyway and
  # the app died at boot, then ran it as root. flk-agent switches now.
  wait_log "up as 1100" 30
  [[ $(console_log) != *"can't switch to user"* ]] || fail "init fell back to root: $(console_log | tail -5)"
  assert_eq started "$(machine_state)" "machine running"
  assert_contains "$(flk exec --user 1100 -- sh -c 'touch /data/f && echo ok')" "ok" "the image's user can write"
}

# [[mounts]] seed = true (PLAN M6): an empty volume starts with what the
# image has at its mount point, owners included; one with data is left alone.
test_seed_fills_an_empty_volume_from_the_image() {
  cat >>"$APP_DIR/Dockerfile" <<'DOCKER'
USER root
RUN mkdir -p /home/app/.cfg && echo shipped >/home/app/.cfg/settings && ln -s .cfg/settings /home/app/link \
 && chown -R app:app /home/app && chmod 750 /home/app
USER app
DOCKER
  toml_append '[[mounts]]' '  source = "home"' '  destination = "/home/app"' '  seed = true'
  flk volumes create home --size 1 >/dev/null
  local out; out=$(flk build 2>&1) || fail "build failed: $out"
  [[ $out != *"hides the"*"/home/app"* && $out != *"/home/app hides"* ]] || fail "seed still warns about hidden files: $out"
  out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  assert_contains "$out" "volume home: seeded from /home/app in v"
  wait_log "up as 1100" 30
  assert_eq 1100:1100 "$(owner home)" "the volume's root, like /home/app in the image"
  assert_eq shipped "$(flk exec -- cat /home/app/link)" "files and symlinks copied"
  assert_eq "1100:1100 750" "$(flk exec -- stat -c '%u:%g %a' /home/app)" "mount point owner and mode"
  assert_contains "$(flk events --json -n 50)" '"type":"volume.seeded"' "event"
  assert_eq true "$(flk machine list --json | json_get 0.volumes.1.seed)" "seed in the machine's mounts"
  # the app's own changes survive the next deploy: seeding is for empty volumes
  flk exec -- sh -c 'echo mine >/home/app/.cfg/settings' || fail "the app's user can't write its seeded file"
  out=$(flk deploy 2>&1) || fail "second deploy failed: $out"
  [[ $out != *"seeded from"* ]] || fail "seeded a volume that has data: $out"
  wait_until 30 flk exec -- true
  assert_eq mine "$(flk exec -- cat /home/app/.cfg/settings)" "data kept"
}
