# flk exec and flk ssh console: commands in a running machine through the
# flk agent over vsock. One mcshadow machine.
TIER=vm

setup_file() {
  stage_app mcshadow
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

test_exec_needs_a_running_machine() {
  local m; m=$(machine_id)
  flk machine stop "$m" >/dev/null
  local out; out=$(flk exec -i "$m" -- true 2>&1) && fail "exec on a stopped machine"
  assert_contains "$out" "isn't running"
  flk machine start "$m" >/dev/null; wait_mc 60
}
