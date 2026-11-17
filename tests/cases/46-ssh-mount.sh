# flk ssh mount: a directory of a running machine mounted on the host with
# sshfs, through flk-agent (no sshd in the guest). One machine of the sftp
# app (it has sftp-server and a user "dev", uid 1100). Skipped on a host
# without sshfs. Tests run in order and build on each other.
TIER=vm
SETUP_VARS=MNT

can_mount() { command -v sshfs >/dev/null && command -v fusermount3 >/dev/null && [[ -e /dev/fuse ]]; }
need_mount() { can_mount || skip_test "no sshfs here (sudo apt install sshfs)"; }

setup_file() {
  can_mount || return 0
  stage_app sftp
  flk launch
  MNT=$(mktemp -d "$WORK/mnt.XXXX")
}

teardown_file() {
  local d
  [[ -z ${MNT:-} ]] || for d in "$MNT"/*/; do fusermount3 -uz "$d" 2>/dev/null || true; done
  destroy_app
}

mount_row() { flk ssh mounts --json | ruby -rjson -e 'r = JSON.parse($stdin.read).find { _1["dir"] == ARGV[0] }
  puts r ? r[ARGV[1]].to_s : "none"' "$1" "$2"; }
# read_soon FILE: its content once the mount answers (it reconnects by itself)
read_soon() { local i; for i in {1..20}; do timeout 10 cat "$1" 2>/dev/null && return 0; sleep 1; done; return 1; }

test_mount_reads_and_writes_as_the_user() {
  need_mount
  local out
  out=$(flk ssh mount /home/dev "$MNT/home" --user dev 2>&1) || fail "mount failed: $out"
  assert_contains "$out" "$APP:/home/dev is mounted at $MNT/home (as dev"
  assert_contains "$out" "Next: flk ssh unmount $MNT/home"
  assert_eq "hello from the guest" "$(cat "$MNT/home/note.txt")" "reads the guest's file"
  assert_eq "$(id -u)" "$(stat -c %u "$MNT/home/note.txt")" "the guest user's files show as ours (uid 1100 there)"
  echo "from the host" >"$MNT/home/new.txt"
  mkdir "$MNT/home/sub" && mv "$MNT/home/new.txt" "$MNT/home/sub/moved.txt"
  assert_eq "from the host" "$(flk exec -- cat /home/dev/sub/moved.txt)" "the guest sees what the host wrote"
  assert_eq 1100 "$(flk exec -- stat -c %u /home/dev/sub/moved.txt)" "written as dev in the guest"
  assert_eq ok "$(mount_row "$MNT/home" state)" "listed"
  assert_eq dev "$(mount_row "$MNT/home" user)" "its user"
  assert_eq "$APP" "$(mount_row "$MNT/home" app)" "its app"
  assert_contains "$(flk ssh mounts)" "/home/dev"
  assert_contains "$(flk status)" "$MNT/home (dev)" "flk status shows it"
  assert_eq /home/dev "$(flk status --json | json_get ssh_mounts.0.path)" "status --json ssh_mounts"
}

test_mount_follows_a_restart() {
  need_mount
  flk restart >/dev/null
  assert_eq "hello from the guest" "$(read_soon "$MNT/home/note.txt")" "the mount came back by itself"
}

test_stopped_machine_gives_errors_until_it_starts() {
  need_mount
  flk stop >/dev/null
  assert_eq "machine stopped" "$(mount_row "$MNT/home" state)" "the list says why"
  assert_contains "$(flk status)" "machine stopped"
  sleep 6 # past the directory cache
  if timeout 20 ls "$MNT/home/sub" >/dev/null 2>&1; then fail "a stopped machine's files were listed"; fi
  flk start >/dev/null
  assert_eq "from the host" "$(read_soon "$MNT/home/sub/moved.txt")" "back after the start"
}

test_read_only_mount() {
  need_mount
  local out
  out=$(flk ssh mount / "$MNT/ro" --read-only 2>&1) || fail "read-only mount failed: $out"
  assert_contains "$out" "(as root, read-only"
  assert_eq true "$(mount_row "$MNT/ro" read_only)" "listed as read-only"
  assert_eq "hello from the guest" "$(cat "$MNT/ro/home/dev/note.txt")" "root reads everything"
  if (echo x >"$MNT/ro/tmp/x") 2>/dev/null; then fail "wrote through a read-only mount"; fi
  assert_ok flk ssh unmount "$MNT/ro"
  assert_eq none "$(mount_row "$MNT/ro" state)" "gone from the list"
}

test_mount_refusals() {
  need_mount
  local out
  out=$(flk ssh mount /home/dev "$MNT/home" 2>&1) && fail "mounted twice on one directory"
  assert_contains "$out" "already has $APP:/home/dev mounted"
  mkdir -p "$MNT/full" && touch "$MNT/full/file"
  out=$(flk ssh mount /home/dev "$MNT/full" 2>&1) && fail "mounted over files"
  assert_contains "$out" "isn't empty"
  out=$(flk ssh mount home/dev "$MNT/x" 2>&1) && fail "took a relative path"
  assert_contains "$out" "must be absolute"
  out=$(flk ssh mount /nowhere "$MNT/x" 2>&1) && fail "mounted a missing directory"
  assert_contains "$out" "/nowhere isn't a directory in machine"
  out=$(flk ssh mount /srv/private "$MNT/x" --user dev 2>&1) && fail "mounted a directory the user can't read"
  assert_contains "$out" "dev can't read /srv/private"
  out=$(flk ssh mount /home/dev "$MNT/x" --user nobody2 2>&1) && fail "mounted as an unknown user"
  assert_contains "$out" "no user \"nobody2\""
  [[ ! -e $MNT/x ]] || fail "a refused mount left its directory behind"
  out=$(flk ssh unmount "$MNT/full" 2>&1) && fail "unmounted a plain directory"
  assert_contains "$out" "isn't a flk ssh mount"
  out=$(flk ssh sftp-stdio 2>&1) && fail "sftp-stdio ran by hand"
  assert_contains "$out" "run by sshfs"
}

test_image_without_an_sftp_server_says_how_to_add_one() {
  need_mount
  local out
  flk exec -- mv /usr/lib/ssh/sftp-server /tmp/sftp-server.away
  out=$(flk ssh mount /home/dev "$MNT/x" 2>&1) && fail "mounted without an sftp-server"
  flk exec -- mv /tmp/sftp-server.away /usr/lib/ssh/sftp-server
  assert_contains "$out" "has no SFTP server"
  assert_contains "$out" "apk add openssh-sftp-server"
}

test_unmount_busy_force_and_all() {
  need_mount
  local out
  (cd "$MNT/home" && exec sleep 30) &
  local holder=$!
  sleep 1
  out=$(flk ssh unmount "$MNT/home" 2>&1) && fail "unmounted a directory in use"
  assert_contains "$out" "something has a file open there"
  assert_contains "$out" "--force"
  assert_ok flk ssh unmount "$MNT/home" --force
  kill "$holder" 2>/dev/null || true
  assert_eq none "$(mount_row "$MNT/home" state)" "detached"
  flk ssh mount /home/dev "$MNT/a" --user dev >/dev/null
  flk ssh mount /tmp "$MNT/b" >/dev/null
  out=$(flk ssh unmount --all 2>&1) || fail "unmount --all failed: $out"
  assert_contains "$out" "Unmounted $MNT/a"
  assert_contains "$out" "Unmounted $MNT/b"
  assert_contains "$(flk ssh unmount --all)" "No flk ssh mounts of $APP"
}

test_destroying_the_app_takes_its_mounts_away() {
  need_mount
  local out
  flk ssh mount /home/dev "$MNT/last" --user dev >/dev/null
  out=$("$FLK_BIN" apps destroy "$APP" --yes 2>&1) || fail "destroy failed: $out"
  assert_contains "$out" "unmounted $MNT/last"
  assert_eq none "$(mount_row "$MNT/last" state)" "no mount left"
  [[ -z $(ls -A "$MNT/last") ]] || fail "the directory isn't empty after the unmount"
}
