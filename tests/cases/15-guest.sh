# What images expect from the runtime: /dev/fd, /dev/stdout..., and stdin
# wired to the serial console (flk console) unless [flk] stdin = "null".
TIER=vm

setup_file() {
  stage_app probe
  flk launch --no-deploy
  flk deploy
  wait_log "probe: fd0=" 30
}

teardown_file() { destroy_app; }

type_line() { tmux -L "${FLK_TMUX_SOCKET:-flk}" send-keys -t "flk-$(machine_id)" "$1" Enter; }

test_dev_fd_links() {
  log_has "probe: devfd-ok" || fail "/dev/fd or /dev/stdin missing: $(console_log | grep probe:)"
  log_has "probe: stdout-path-ok" || fail "writing to /dev/stdout failed"
  log_has "probe: stderr-path-ok" || fail "writing to /dev/stderr failed"
}

test_stdin_is_the_console() {
  log_has "probe: fd0=/dev/console" || fail "app stdin isn't the console: $(console_log | grep 'probe: fd0')"
  type_line "hello-$RUN_ID"
  wait_log "probe: got: hello-$RUN_ID" 10
}

# G3: one line to the app's stdin without a terminal, and its answer
test_console_send_and_wait() {
  local out
  out=$(flk console --send "ping-$RUN_ID" </dev/null)
  assert_contains "$out" "Sent to $(machine_id)"
  wait_log "probe: got: ping-$RUN_ID" 10
  out=$(flk console "$(machine_id)" --send "pong-$RUN_ID" --wait-log "got: pong-$RUN_ID" </dev/null)
  assert_contains "$out" "probe: got: pong-$RUN_ID" "output up to the match"
  out=$(flk console --send "quiet-$RUN_ID" --wait-log "never-printed" --timeout 2 </dev/null 2>&1) &&
    fail "--wait-log matched something that never came"
  assert_contains "$out" "within 2s"
}

test_stdin_null_option() {
  toml_append '[flk]' '  stdin = "null"'
  flk deploy
  wait_log "probe: stdin closed" 30
  log_has "probe: fd0=/dev/null" || fail "[flk] stdin = \"null\" didn't apply"
  local out
  out=$(flk console --send "x" </dev/null 2>&1) && fail "--send to an app that doesn't read the console"
  assert_contains "$out" 'stdin = "null"'
}
