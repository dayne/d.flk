# flk exec and flk ssh console: commands in a running machine through the
# flk agent over vsock. One mcshadow machine.
TIER=vm

setup_file() {
  stage_app mcshadow
  toml_append '' '[flk]' '  log_max_mb = 1' # for the last test
  flk launch --no-deploy
  flk volumes create world --size 1
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; }

test_exec_output_status_and_env() {
  local out err rc=0
  out=$(flk exec -- sh -c 'echo out; echo err >&2; echo "motd=$MOTD"; exit 7' 2>"$WORK/exec-err-$RUN_ID") || rc=$?
  assert_eq 7 "$rc" "exit status"
  assert_eq $'out\nmotd=flk shadow server' "$out" "stdout, with the app's env"
  assert_eq err "$(cat "$WORK/exec-err-$RUN_ID")" "stderr kept apart"
  assert_contains "$(flk exec -- ls /data)" "world" "sees the volume"
}

test_exec_stdin_user_cwd() {
  assert_eq "piped in" "$(echo "piped in" | flk exec --stdin -- cat)"
  assert_eq "" "$(flk exec -- cat)" "no --stdin: empty stdin, no hang"
  assert_eq 65534 "$(flk exec --user nobody -- id -u)"
  assert_eq /data "$(flk exec --cwd /data -- pwd)"
  local out; out=$(flk exec -- nosuchcmd 2>&1) && fail "ran a missing command"
  assert_contains "$out" "nosuchcmd: not found in the machine"
}

test_exec_timeout() {
  local rc=0 t0=$SECONDS
  flk exec --timeout 1 -- sleep 30 || rc=$?
  assert_eq 124 "$rc" "timeout status"
  (( SECONDS - t0 < 10 )) || fail "the timeout didn't stop it"
}

test_ssh_console() {
  assert_eq "$APP" "$(flk ssh console -C 'echo $FLY_APP_NAME')"
  local out; out=$(flk ssh console 2>&1 </dev/null) && fail "a shell without a terminal"
  assert_contains "$out" "needs a terminal"
  command -v script >/dev/null || skip_test "no script(1) for a pty"
  out=$(cd "$APP_DIR" && printf 'tty; echo "cols=$(stty size)"; exit 3\n' |
    script -qec "$FLK_BIN ssh console" /dev/null 2>&1) || true
  assert_contains "$out" "/dev/pts/" "a real terminal in the machine"
}

# flk machine extend: / in the machine is bigger after, and what was
# written there since the deploy is still there.
test_machine_extend_grows_root_in_place() {
  local m out before; m=$(machine_id)
  flk exec -- sh -c 'echo installed >/root-marker'
  before=$(flk exec -- df -m / | awk 'NR==2 {print $2}')
  out=$(flk machine extend "$m" --size 2 2>&1) && fail "extended under a running machine"
  assert_contains "$out" "--restart"
  out=$(flk machine extend "$m" --size 2 --restart 2>&1) || fail "extend --restart failed: $out"
  assert_contains "$out" "-> 2GB"
  wait_mc 60
  assert_eq installed "$(flk exec -- cat /root-marker)" "files on / kept"
  local after; after=$(flk exec -- df -m / | awk 'NR==2 {print $2}')
  (( after > 1800 && after > before )) || fail "/ is ${after}MB (was ${before}MB), expected about 2048"
  assert_eq started "$(flk machine status "$m" | json_get desired_state)" "desired_state"
}

test_exec_needs_a_running_machine() {
  local m; m=$(machine_id)
  flk machine stop "$m" >/dev/null
  local out; out=$(flk exec -i "$m" -- true 2>&1) && fail "exec on a stopped machine"
  assert_contains "$out" "isn't running"
  flk machine start "$m" >/dev/null; wait_mc 60
}

test_args_after_double_dash_are_the_commands() {
  assert_eq "-a -l" "$(flk exec -- sh -c 'echo "$*"' x -a -l)" "-a after -- belongs to the command"
  assert_contains "$(flk exec -- uname -a)" "x86_64" "uname -a (not plain uname)"
}

test_exec_waits_for_a_freshly_booted_agent() {
  local m; m=$(machine_id)
  flk machine restart "$m" >/dev/null
  assert_eq ok "$(flk exec -- echo ok)" "exec right after a boot"
}

# [flk] log_max_mb = 1 (enshrouded BUGS #3): this app's console.log rotates
# at 1MB, not the host's 10, and flk logs --boot still finds the boot's start.
test_console_log_rotates_at_the_apps_limit() {
  local md; md="$FLK_HOME/apps/$APP/machines/$(machine_id)"
  [[ ! -e $md/console.log.1 ]] || fail "console.log rotated before the test wrote anything"
  flk exec --user root -- sh -c 'yes "$(printf %099d 0)" | head -n 12000 >/dev/console' # 1.2MB
  wait_until 60 test -s "$md/console.log.1" || fail "no console.log.1 after 1.2MB (console.log: $(stat -c %s "$md/console.log") bytes)"
  local size; size=$(stat -c %s "$md/console.log.1")
  ((size > 1048576 && size < 1100000)) || fail "console.log.1 is $size bytes, expected just over 1MB"
  local out; out=$(flk logs --boot 2>&1 | grep -c -e "--- flk: booting" -e "rotated out") || true
  assert_eq 1 "$out" "logs --boot starts at the boot marker in console.log.1"
}
