# Backups of a volume no machine uses: verify (e2fsck -n, the verify hook)
# and restore --as (into a new volume, nothing stopped). No VMs.
TIER=fast

BK="$WORK/backups-26-$RUN_ID"
export FLK_HOST_CONFIG="$WORK/host-26-$RUN_ID.toml"

setup_file() {
  stage_app hello
  flk launch --no-deploy
  mkdir -p "$BK" "$WORK/seed-$RUN_ID"
  printf 'backup_dir = "%s"\n' "$BK" >"$FLK_HOST_CONFIG"
  echo v1 >"$WORK/seed-$RUN_ID/data.txt"
  flk volumes create data --size 1 --from-dir "$WORK/seed-$RUN_ID"
  flk volumes backup data
}

teardown_file() { destroy_app; rm -rf "$BK" "$WORK/seed-$RUN_ID" "$FLK_HOST_CONFIG"; }

backups_json() { flk volumes backups --json; }
vol_path() { flk volumes list --json | ruby -rjson -e 'puts JSON.parse($stdin.read).find { _1["name"] == ARGV[0] }["path"]' "$1"; }
set_verify() { sed -i '/^\[flk.backup\]/,$d' "$APP_DIR/flk.toml"; [[ -z $1 ]] || toml_append '[flk.backup]' "  verify = '$1'"; }

test_verify_without_a_hook() {
  local out; out=$(flk volumes verify) || fail "verify failed: $out"
  assert_contains "$out" "clean: e2fsck -n: clean"
  assert_contains "$out" "no [flk.backup] verify hook"
  assert_eq clean "$(backups_json | json_get 0.verify)" "recorded result"
  [[ -n $(backups_json | json_get 0.verified_at) ]] || fail "no verified_at"
}

test_verify_hook_reads_the_backup() {
  set_verify 'debugfs -R "cat /data.txt" "$FLK_BACKUP" 2>/dev/null | grep -qx v1 && test "$FLK_VOLUME" = data'
  local out; out=$(flk volumes verify data --json) || fail "verify failed: $out"
  assert_eq clean "$(json_get 0.verify <<<"$out")"
  assert_contains "$(json_get 0.verify_detail <<<"$out")" "verify hook: passed"
  set_verify 'echo world is missing; exit 3'
  out=$(flk volumes verify 2>&1) && fail "verify passed a failing hook"
  assert_contains "$out" "world is missing"
  assert_eq hook_failed "$(backups_json | json_get 0.verify)"
  # a backup runs the hook too, and fails with it
  out=$(flk volumes backup 2>&1) && fail "backup passed a failing verify hook"
  assert_contains "$out" "the verify hook failed"
  set_verify ''
}

test_restore_as_a_new_volume() {
  local src before out p
  src=$(vol_path data)
  before=$(stat -c %Y "$src")
  out=$(flk volumes restore data --as copy) || fail "restore --as failed: $out"
  assert_contains "$out" "data wasn't touched"
  p=$(vol_path copy)
  assert_eq v1 "$(/usr/sbin/debugfs -R 'cat /data.txt' "$p" 2>/dev/null)" "the new volume has the data"
  assert_contains "$(flk volumes list --json)" '"restored_from": "data-'
  assert_eq "$before" "$(stat -c %Y "$src")" "the original volume is untouched"
  touch "$WORK/taken-$RUN_ID.ext4"
  out=$(flk volumes restore data --as copy2 --path "$WORK/taken-$RUN_ID.ext4" 2>&1) && fail "restored over an existing file"
  assert_contains "$out" "already exists"
  rm -f "$WORK/taken-$RUN_ID.ext4"
  out=$(flk volumes restore data --path "$WORK/x.ext4" 2>&1) && fail "accepted --path without --as"
  assert_contains "$out" "--path goes with --as"
  flk volumes destroy copy >/dev/null
}

test_restore_as_from_a_destroyed_volume() {
  flk volumes create gone --size 1 >/dev/null
  flk volumes backup gone >/dev/null || fail "backup of gone failed"
  flk volumes destroy gone >/dev/null
  local out; out=$(flk volumes restore gone --as back) || fail "restore of a destroyed volume's backup failed: $out"
  flk volumes list --json | grep -q '"name": "back"' || fail "no volume 'back'"
  flk volumes destroy back >/dev/null
}

test_verify_finds_damage() {
  local f out; f=$(backups_json | json_get 0.path)
  /usr/sbin/debugfs -w -R "set_inode_field /data.txt links_count 7" "$f" >/dev/null 2>&1
  out=$(flk volumes verify data 2>&1) && fail "verify passed a damaged backup"
  assert_contains "$out" "errors"
  assert_eq errors "$(backups_json | json_get 0.verify)"
  [[ -s ${f%.ext4}.verify.log ]] || fail "no .verify.log kept"
}
