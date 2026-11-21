# waitapp.sh INIT_SH: runs init.sh's wait_app against apps that exit in awkward ways; prints one status per case
eval "$(sed -n '/^wait_app() {$/,/^}$/p' "$1")"
trap : USR1
run() { # LABEL: the app is already started as $child
  status=0
  wait_app
  printf '%s=%s ' "$1" "$status"
}
(sleep 0.2; exit 5) & child=$!; run plain
(exit 3) & child=$!; sleep 0.3; run gone_before_we_wait
(exit 127) & child=$!; run status_127
# the app is gone by the time we look (the lost status: the old loop looked first and never waited)
kill() { return 1; }
(exit 3) & child=$!; run not_there_when_asked
unset -f kill
# a signal cuts the wait short while the app runs on
(sleep 0.5; exit 7) & child=$!; (sleep 0.1; kill -USR1 $$) & run signal_then_later
# a signal cuts the wait short and the app exits before we look: its own status, not the signal's
kill() { [ "$1" = -0 ] && sleep 0.5; command kill "$@"; }
(sleep 0.3; exit 5) & child=$!; (sleep 0.1; command kill -USR1 $$) & run signal_then_gone
echo
