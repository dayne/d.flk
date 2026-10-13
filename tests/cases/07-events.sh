# The event log itself, in a state dir of its own (FLK_HOME): writing,
# reading, filters, rotation, and --follow across a rotation. No VMs.
TIER=fast

EH="$WORK/events-home-$RUN_ID"
ev() { FLK_HOME="$EH" "$FLK_BIN" "$@"; }
emit() { # emit TYPE APP [DETAIL]
  FLK_HOME="$EH" ruby -I"$FLK_SRC/lib" -rflk -e 'Flk::Events.emit(ARGV[0], app: ARGV[1], machine: "m1", release: 3, detail: ARGV[2])' "$@"
}

teardown_file() { rm -rf "$EH"; }

test_write_and_read() {
  mkdir -p "$EH"
  assert_eq "No events" "$(ev events --all)"
  emit machine.started app1 "booted"
  emit machine.stopped app2
  local out; out=$(ev events --all --json)
  assert_eq 2 "$(wc -l <<<"$out")" "one line per event"
  assert_eq machine.started "$(head -1 <<<"$out" | json_get type)"
  assert_eq 3 "$(head -1 <<<"$out" | json_get release)"
  assert_eq app1 "$(ev -a app1 events --json | json_get app)" "-a filters"
  assert_contains "$(ev events --all)" "app2  m1  machine.stopped  v3"
  local err; err=$(FLK_HOME="$EH" ruby -I"$FLK_SRC/lib" -rflk -e 'Flk::Events.emit("machine.flew", app: "x")' 2>&1) &&
    fail "an unknown type was accepted"
  assert_contains "$err" "unknown event type"
}

test_since_and_lines() {
  sleep 1.1
  local mark; mark=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  emit deploy.started app1
  assert_eq 1 "$(ev events --all --json --since "$mark" | wc -l)" "--since ISO"
  assert_eq 3 "$(ev events --all --json --since 1h | wc -l)" "--since duration"
  assert_eq 2 "$(ev events --all --json -n 2 | wc -l)" "-n"
  local out; out=$(ev events --since yesterdayish 2>&1) && fail "accepted a bad --since"
  assert_contains "$out" "--since takes"
}

test_rotation_keeps_reading_both_files() {
  FLK_HOME="$EH" ruby -I"$FLK_SRC/lib" -rflk -e '
    Flk::Events.send(:remove_const, :MAX_BYTES); Flk::Events.const_set(:MAX_BYTES, 2000)
    40.times { |i| Flk::Events.emit("machine.started", app: "rot", detail: "n#{i}") }'
  [[ -f $EH/events.jsonl.1 ]] || fail "no rotation"
  [[ $(stat -c %s "$EH/events.jsonl") -lt 2500 ]] || fail "current file wasn't cut"
  local out; out=$(ev -a rot events --json -n 1000)
  assert_contains "$(tail -1 <<<"$out")" '"n39"' "newest last"
}

test_follow_sees_new_events_and_rotations() {
  local out="$WORK/follow-$RUN_ID.txt" pid
  ( FLK_HOME="$EH" exec "$FLK_BIN" -a fol events --follow --json >"$out" ) &
  pid=$!
  sleep 1
  emit check.passed fol "first"
  mv "$EH/events.jsonl" "$EH/events.jsonl.1"   # what rotation does
  emit check.failed fol "after rotation"
  wait_until 5 grep -q "after rotation" "$out" || { kill $pid; fail "follow missed events: $(cat "$out")"; }
  kill $pid; wait $pid 2>/dev/null || true
  assert_contains "$(cat "$out")" '"first"'
}
