# Volume backups: the three [flk.backup] modes, hooks, listing, pruning,
# restore and extend, on one mcshadow machine. Tests run in order.
TIER=vm

setup_file() {
  stage_app mcshadow
  toml_append '' '[flk.backup]' '  mode = "live"' \
    '  pre = ["echo pre $FLK_MACHINE >> hooks.txt", { console = "save-all", wait = "Saved the game \\(save-all\\)", timeout = 20 }]' \
    '  post = ["echo post >> hooks.txt"]' '  settle = 3'
  flk launch --no-deploy
  flk volumes create world --size 1
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; }

# Backups go to a dir per test file; the host settings file is the test's own.
BK="$WORK/backups-$RUN_ID"
export FLK_HOST_CONFIG="$WORK/host-$RUN_ID.toml"
backups_json() { flk volumes backups --to "$BK" --json; }
backup_count() { backups_json | ruby -rjson -e 'puts JSON.parse($stdin.read).size'; }

test_backup_needs_a_destination() {
  local out
  out=$(flk volumes backup 2>&1) && fail "backed up with no destination"
  assert_contains "$out" "no backup destination"
  printf 'backup_dir = "%s"\n' "$BK/missing" >"$FLK_HOST_CONFIG"
  out=$(flk volumes backup 2>&1) && fail "backed up to a missing dir"
  assert_contains "$out" "doesn't exist"
  rm -f "$FLK_HOST_CONFIG"
}

test_live_backup_runs_hooks_and_keeps_running() {
  mkdir -p "$BK"
  local boots out; boots=$(mcq flk.boots)
  out=$(flk volumes backup --to "$BK") || fail "backup failed: $out"
  assert_contains "$out" "mode live"
  assert_contains "$out" "Saved the game (save-all)" "console hook waited for the save"
  [[ $out == *"fsck: clean"* ]] ||
    fail "a live copy of a healthy volume isn't clean: $out $(cat "$(backups_json | json_get 0.path | sed 's/\.ext4$/.fsck.log/')")"
  assert_eq "pre $(machine_id)"$'\n'"post" "$(cat "$APP_DIR/hooks.txt")" "hooks ran in order, in the app dir"
  assert_eq "$boots" "$(mcq flk.boots)" "machine kept running"
  assert_eq 1 "$(mcq flk.console_saves)" "save-all reached the app"
  assert_eq 1 "$(backup_count)" "backups"
}

test_backup_is_a_consistent_image() {
  local f; f=$(backups_json | json_get 0.path)
  /usr/sbin/e2fsck -fn "$f" >/dev/null 2>&1 || fail "e2fsck -fn found problems in $f"
  # the save-all write is in the copy
  /usr/sbin/debugfs -R "cat /world/level.json" "$f" 2>/dev/null | grep -q '"console_saves":1' ||
    fail "the copy lacks the flushed save"
}

test_pause_mode_keeps_the_machine() {
  local boots out; boots=$(mcq flk.boots)
  out=$(flk volumes backup --to "$BK" --mode pause) || fail "pause backup failed: $out"
  assert_contains "$out" "machine paused"
  wait_mc 10
  assert_eq "$boots" "$(mcq flk.boots)" "same boot after pause"
}

test_stop_mode_restarts_the_machine() {
  local boots out; boots=$(mcq flk.boots)
  out=$(flk volumes backup --to "$BK" --mode stop) || fail "stop backup failed: $out"
  assert_contains "$out" "machine down"
  wait_mc 60
  assert_eq $((boots + 1)) "$(mcq flk.boots)" "booted again"
  assert_eq "$boots" "$(backups_json | json_get 0.path | xargs -I{} /usr/sbin/debugfs -R 'cat /world/level.json' {} 2>/dev/null |
    ruby -rjson -e 'puts JSON.parse($stdin.read)["boots"]')" "the stop-mode copy holds the world as it stopped"
}

test_keep_prunes_oldest() {
  local newest; newest=$(backups_json | json_get 0.file)
  flk volumes backup --to "$BK" --keep 2 >/dev/null || fail "backup failed"
  assert_eq 2 "$(backup_count)" "backups after --keep 2"
  assert_eq "$newest" "$(backups_json | json_get 1.file)" "the previous newest is kept"
}

test_restore_needs_a_stopped_machine() {
  local out
  out=$(flk volumes restore world --to "$BK" 2>&1) && fail "restored under a running machine"
  assert_contains "$out" "stop it first"
}

test_restore_brings_back_the_backup() {
  local m b keep; m=$(machine_id)
  b=$(backups_json | json_get 0.path | xargs -I{} /usr/sbin/debugfs -R 'cat /world/level.json' {} 2>/dev/null |
    ruby -rjson -e 'puts JSON.parse($stdin.read)["boots"]')
  flk machine restart "$m" >/dev/null; wait_mc 60 # one more boot that the backup doesn't have
  flk machine stop "$m" >/dev/null
  flk volumes restore world --to "$BK" | grep -q "previous image is kept" || fail "no note about the kept image"
  ls "$(flk volumes list --json | json_get 0.path)".before-restore-* >/dev/null || fail "old image not kept"
  flk machine start "$m" >/dev/null; wait_mc 60
  assert_eq $((b + 1)) "$(mcq flk.boots)" "boots after restore (backup's count + this boot)"
}

# Real damage is reported, with e2fsck's output kept beside the backup.
test_damage_is_reported_as_repaired() {
  local m out f; m=$(machine_id)
  flk machine stop "$m" >/dev/null
  f=$(flk volumes list --json | json_get 0.path)
  /usr/sbin/debugfs -w -R "set_inode_field /world/level.json links_count 7" "$f" >/dev/null 2>&1
  out=$(flk volumes backup --to "$BK") || fail "backup failed: $out"
  assert_contains "$out" "fsck: repaired"
  [[ -s $(backups_json | json_get 0.path | sed 's/\.ext4$/.fsck.log/') ]] || fail "no .fsck.log kept"
  /usr/sbin/e2fsck -fy "$f" >/dev/null 2>&1 || true # mend the volume itself (exit 1: fixed)
  flk machine start "$m" >/dev/null; wait_mc 60
}

test_extend_grows_a_stopped_volume() {
  local m out; m=$(machine_id)
  out=$(flk volumes extend world --size 2 2>&1) && fail "extended under a running machine"
  flk machine stop "$m" >/dev/null
  out=$(flk volumes extend world --size 1 2>&1) && fail "shrank a volume"
  flk volumes extend world --size 2 >/dev/null || fail "extend failed"
  assert_eq 2 "$(flk volumes list --json | json_get 0.size_gb)" "size_gb"
  local f; f=$(flk volumes list --json | json_get 0.path)
  assert_eq $((2 * 1024 ** 3)) "$(stat -c %s "$f")" "image size"
  flk machine start "$m" >/dev/null; wait_mc 60
}
