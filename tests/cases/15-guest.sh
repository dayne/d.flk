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

test_stdin_null_option() {
  toml_append '[flk]' '  stdin = "null"'
  flk deploy
  wait_log "probe: stdin closed" 30
  log_has "probe: fd0=/dev/null" || fail "[flk] stdin = \"null\" didn't apply"
}
