# flk files: a volume's files without mounting it (debugfs). No VMs.
TIER=fast

BK="$WORK/backups-27-$RUN_ID"
export FLK_HOST_CONFIG="$WORK/host-27-$RUN_ID.toml"
SEED="$WORK/seed-27-$RUN_ID"

setup_file() {
  stage_app hello
  flk launch --no-deploy
  mkdir -p "$BK" "$SEED/conf" "$SEED/logs"
  printf 'backup_dir = "%s"\n' "$BK" >"$FLK_HOST_CONFIG"
  echo "motd=hello" >"$SEED/conf/server.properties"
  echo "line 1" >"$SEED/logs/latest log.txt"
  flk volumes create data --size 1 --from-dir "$SEED"
}

teardown_file() { destroy_app; rm -rf "$BK" "$SEED" "$FLK_HOST_CONFIG"; }

img() { flk volumes list --json | json_get 0.path; }
fsck_clean() { /usr/sbin/e2fsck -fn "$(img)" >/dev/null 2>&1 || fail "the volume isn't clean after: $1"; }
entry() { flk files ls "data:$1" --json | ruby -rjson -e 'e = JSON.parse($stdin.read).find { _1["name"] == ARGV[0] }
  puts e ? "#{e["type"]} #{e["uid"]}:#{e["gid"]} #{e["mode"]} #{e["size"]}" : "none"' "$2"; }

test_ls_and_cat() {
  local out; out=$(flk files ls data)
  assert_contains "$out" "conf/"
  assert_contains "$out" "logs/"
  out=$(flk files ls data:/conf --json)
  assert_eq server.properties "$(json_get 0.name <<<"$out")"
  assert_eq file "$(json_get 0.type <<<"$out")"
  assert_eq 11 "$(json_get 0.size <<<"$out")"
  [[ $(json_get 0.mtime <<<"$out") == 20* ]] || fail "no mtime: $out"
  assert_eq "motd=hello" "$(flk files cat data:/conf/server.properties)"
  assert_eq "line 1" "$(flk files cat "data:/logs/latest log.txt")" "a name with a space"
  out=$(flk files cat data:/nope 2>&1) && fail "cat of a missing file passed"
  assert_contains "$out" "no such file"
  out=$(flk files cat data:/conf 2>&1) && fail "cat of a directory passed"
  out=$(flk files ls nosuchvol:/ 2>&1) && fail "ls of a missing volume passed"
  assert_contains "$out" "isn't VOL:PATH"
}

test_cp_out() {
  local d="$WORK/out-27-$RUN_ID"; mkdir -p "$d"
  flk files cp data:/conf/server.properties "$d/" >/dev/null
  assert_eq "motd=hello" "$(cat "$d/server.properties")"
  flk files cp data:/logs "$d/logs-copy" >/dev/null
  assert_eq "line 1" "$(cat "$d/logs-copy/latest log.txt")" "a directory copied out"
  local out
  out=$(flk files cp data:/conf/server.properties "$d/missing/deep/" 2>&1) && fail "copied into a missing dir"
  assert_contains "$out" "no such directory"
  out=$(flk files cp data:/conf/server.properties "$d/missing/file" 2>&1) && fail "copied into a missing dir"
  assert_contains "$out" "no such directory"
  rm -rf "$d"
}

test_chown_mkdir_and_cp_in() {
  flk files chown 1000:1000 data:/ >/dev/null
  /usr/sbin/debugfs -R "stat /" "$(img)" 2>/dev/null | grep -Eq "User: +1000 +Group: +1000" || fail "chown of / didn't take"
  flk files mkdir -p data:/mods/extra >/dev/null
  assert_eq "dir 1000:1000 0755 4096" "$(entry /mods extra)" "mkdir -p takes the parent's owner"
  local f="$WORK/mod-$RUN_ID.zip"; echo zipdata >"$f"; chmod 640 "$f"
  flk files cp "$f" data:/mods/ >/dev/null
  assert_eq "file 1000:1000 0640 8" "$(entry /mods "mod-$RUN_ID.zip")" "copied in: parent's owner, local mode"
  echo newer >"$f"
  flk files cp "$f" "data:/mods/mod-$RUN_ID.zip" --owner 2000:3000 >/dev/null
  assert_eq "newer" "$(flk files cat "data:/mods/mod-$RUN_ID.zip")" "replaced"
  assert_eq "file 2000:3000 0640 6" "$(entry /mods "mod-$RUN_ID.zip")" "--owner"
  # a tree with a symlink
  local t="$WORK/tree-$RUN_ID"; mkdir -p "$t/a/b"; echo deep >"$t/a/b/c.txt"; ln -s b/c.txt "$t/a/link"
  flk files cp "$t" data:/ >/dev/null
  assert_eq deep "$(flk files cat "data:/tree-$RUN_ID/a/b/c.txt")"
  assert_contains "$(entry "/tree-$RUN_ID/a" link)" "symlink 1000:1000"
  rm -rf "$t" "$f"
  fsck_clean "cp in"
}

test_rm() {
  local out
  out=$(flk files rm data:/mods 2>&1) && fail "rm of a non-empty dir without -r passed"
  assert_contains "$out" "use -r"
  flk files rm -r data:/mods >/dev/null
  assert_eq none "$(entry / mods)"
  flk files rm "data:/logs/latest log.txt" >/dev/null
  assert_eq "(empty)" "$(flk files ls data:/logs)"
  out=$(flk files rm data:/ 2>&1) && fail "rm of / passed"
  fsck_clean "rm"
}

test_chown_recursive() {
  flk files chown -r 1234:1234 "data:/tree-$RUN_ID" >/dev/null
  assert_contains "$(entry "/tree-$RUN_ID/a/b" c.txt)" "1234:1234"
}

test_read_a_backup() {
  flk volumes backup data >/dev/null || fail "backup failed"
  flk files rm -r "data:/tree-$RUN_ID" >/dev/null
  assert_eq none "$(entry / "tree-$RUN_ID")" "gone from the volume"
  assert_contains "$(flk files ls data --backup latest)" "tree-$RUN_ID/" "still in the backup"
  local d="$WORK/restore-27-$RUN_ID"; mkdir -p "$d"
  flk files cp "data:/tree-$RUN_ID" "$d/" --backup latest >/dev/null
  assert_eq deep "$(cat "$d/tree-$RUN_ID/a/b/c.txt")" "one directory back out of a backup"
  rm -rf "$d"
}
