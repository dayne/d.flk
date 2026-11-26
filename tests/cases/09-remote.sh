# An app's host is another one: -H, FLK_HOST, [flk] host, what is sent
# before a deploy (docs/remote-design.md). The peer is this machine under
# a second FLK_HOME and host name, reached through tests/lib/fake-ssh. No VMs.
TIER=fast

R="$WORK/remote-$RUN_ID"            # everything of this file
export FLK_FAKE_PEERS="$R/peers" FLK_SSH="$TESTS/lib/fake-ssh"
HERE_HOME="$R/here-home"            # this host's state: nothing real is touched
SRC="$R/myapp"                      # the app's directory, on this host
PEER_APP="flkt-remote-$RUN_ID"

# (run.sh pins every test to this host with FLK_HOST=local: lifted here)
here() {
  (cd "${DIR:-$SRC}" && unset FLK_HOST && { [[ -z ${WITH_HOST:-} ]] || export FLK_HOST="$WITH_HOST"; } &&
     FLK_HOME="$HERE_HOME" FLK_HOST_CONFIG="$R/here-host.toml" "$FLK_BIN" "$@")
}
peer() { (unset FLK_HOST; . "$FLK_FAKE_PEERS/peer1.env" && cd "$PEER_HOME" && "$FLK_BIN" "$@"); }

setup_file() {
  mkdir -p "$FLK_FAKE_PEERS" "$HERE_HOME" "$SRC/bin" "$R/peer1-home" "$R/peer1-state" "$R/bin"
  ln -s "$FLK_BIN" "$R/bin/flk"
  echo 'name = "here"' >"$R/here-host.toml"
  echo 'name = "peer1"' >"$R/peer1-host.toml"
  cat >"$FLK_FAKE_PEERS/peer1.env" <<ENV
export FLK_HOME="$R/peer1-state" FLK_HOST_CONFIG="$R/peer1-host.toml" PEER_HOME="$R/peer1-home" PATH="$R/bin:$PATH"
ENV
  cat >"$SRC/flk.toml" <<TOML
app = "$PEER_APP"
[build]
  image = "docker.io/library/alpine:3.20"
[flk]
  host = "peer1"
[[vm]]
  memory_mb = 128
TOML
  echo 'echo hook' >"$SRC/bin/hook"
  echo "secret-setting" >"$SRC/site.env"
  mkdir -p "$SRC/logs" "$SRC/.git"; echo x >"$SRC/logs/a.log"; echo x >"$SRC/.git/HEAD"
  echo "logs/" >"$SRC/.flkignore"
}

teardown_file() { rm -rf "$R"; }

test_version_json_names_the_host() {
  assert_eq here "$(here version --json | json_get host)"
  assert_eq peer1 "$(here -H peer1 version --json | json_get host)" "-H asks the peer"
  assert_eq "$R/peer1-state" "$(here --on-host peer1 version --json | json_get root)" "--on-host"
  assert_eq here "$(here -H local version --json | json_get host)" "-H local is here"
  assert_eq peer1 "$(WITH_HOST=peer1 here version --json | json_get host)" "FLK_HOST"
  assert_eq here "$(WITH_HOST=peer1 here -H local version --json | json_get host)" "-H beats FLK_HOST"
  assert_eq here "$(WITH_HOST=local here version --json | json_get host)" "FLK_HOST=local"
}

test_arguments_arrive_as_they_were_typed() {
  local n out; n=$(wc -l <"$FLK_FAKE_PEERS/calls.log")
  out=$(here -H peer1 help 'a b' 2>&1) || true
  assert_contains "$out" "unknown command or topic 'a b'"
  assert_eq "$n" "$(wc -l <"$FLK_FAKE_PEERS/calls.log")" "help never leaves this host"
  # an app name is printed back in the peer's error: spaces, quotes, $ and * intact
  out=$(here -H peer1 -a "it's \$HOME * \"q\"" status 2>&1) && fail "expected an error from the peer"
  assert_contains "$out" "it's \$HOME * \"q\"" "the argument came back unchanged"
  assert_contains "$(tail -1 "$FLK_FAKE_PEERS/calls.log")" "sh -c 'eval" "one sh -c word reaches the peer's shell"
  [[ $(tail -1 "$FLK_FAKE_PEERS/calls.log") != *HOME* ]] || fail "an argument reached the peer's shell as text"
}

test_exit_code_and_unreachable() {
  local rc=0
  here -H peer1 nosuchcommand >/dev/null 2>&1 || rc=$?
  assert_eq 1 "$rc" "the peer's exit code"
  local out; out=$(here -H nowhere status 2>&1) && fail "an unknown peer worked"
  assert_contains "$out" "no ssh connection to nowhere"
  assert_contains "$out" "flk -H local status"
}

test_commands_that_cannot_be_sent() {
  local out
  out=$(here -H peer1 proxy 8080 2>&1) && fail "proxy was sent"
  assert_contains "$out" "can't be sent to peer1"
  out=$(here -H peer1 setup 2>&1) && fail "setup was sent"
  assert_contains "$out" "run it there"
  out=$(DIR=/ here -H "-oProxyCommand=x" status 2>&1) && fail "an option was taken as a host"
  assert_contains "$out" "isn't a host name"
}

test_launch_sends_the_directory_and_registers_there() {
  local out; out=$(here launch --no-deploy 2>&1) || fail "launch: $out"
  assert_contains "$out" "Sending $SRC to peer1:$R/peer1-state/src/$PEER_APP"
  local there="$R/peer1-state/src/$PEER_APP"
  [[ -f $there/flk.toml && -f $there/bin/hook ]] || fail "the directory wasn't sent"
  assert_eq "secret-setting" "$(cat "$there/site.env")" "a gitignored settings file is sent"
  [[ ! -e $there/.git ]] || fail ".git was sent"
  [[ ! -e $there/logs ]] || fail ".flkignore wasn't honoured"
  assert_contains "$(peer apps list --json)" "$PEER_APP"
  assert_eq "$there/flk.toml" "$(peer apps list --json | json_get 0.config_path)" "the peer's config is its copy"
  [[ ! -d $HERE_HOME/apps/$PEER_APP ]] || fail "the app was registered on this host too"
  assert_eq peer1 "$(json_get "$PEER_APP.host" <"$HERE_HOME/remote_apps.json")" "this host remembers where it went"
}

test_commands_about_the_app_follow_flk_toml() {
  assert_contains "$(here status --json)" "\"$PEER_APP\"" "status ran on the peer"
  # host-level commands stay here
  assert_eq here "$(here version --json | json_get host)" "version stays here"
  assert_eq "[]" "$(here apps list --json | tr -d ' \n')" "apps list stays here"
  assert_contains "$(here -H peer1 apps list --json)" "$PEER_APP" "-H sends it"
  # what is about a host stays on this one: --all, --host, host settings
  [[ $(here context --all --json) != *"$PEER_APP"* ]] || fail "context --all went to the peer"
  assert_contains "$(here -H peer1 context --all --json)" "\"$PEER_APP\"" "-H sends context --all"
  here -H peer1 events --all --json >/dev/null || fail "events --all with -H"
  assert_contains "$(here config show --host)" "$R/here-host.toml" "config show --host is this host's"
  here config set backup_keep=3 >/dev/null || fail "config set"
  grep -qx 'backup_keep = 3' "$R/here-host.toml" || fail "config set didn't write this host's settings"
  [[ ! -e $R/peer1-host.toml ]] || ! grep -q backup_keep "$R/peer1-host.toml" || fail "config set wrote the peer's settings"
  here config unset backup_keep >/dev/null
  local out; out=$(WITH_HOST=local here status 2>&1) && fail "FLK_HOST=local still found the app"
  assert_contains "$out" "not found" "FLK_HOST=local keeps a command here"
  # -a from another directory finds the host in the record
  assert_contains "$(DIR=/ here -a "$PEER_APP" machine list --json)" "[" "-a APP from anywhere"
  assert_contains "$(DIR=/ here -a "$PEER_APP" config show --json 2>&1 || true)" "$PEER_APP"
}

test_on_the_peer_the_key_changes_nothing() {
  local there="$R/peer1-state/src/$PEER_APP" n
  n=$(wc -l <"$FLK_FAKE_PEERS/calls.log")
  (unset FLK_HOST; . "$FLK_FAKE_PEERS/peer1.env" && cd "$there" && "$FLK_BIN" status >/dev/null) || fail "status in the peer's copy"
  assert_eq "$n" "$(wc -l <"$FLK_FAKE_PEERS/calls.log")" "the peer didn't call out again"
}

test_a_peer_under_another_name_is_told_apart() {
  # reached as "alias1", the host calls itself peer1: flk.toml's name must be the peer's own
  cp "$FLK_FAKE_PEERS/peer1.env" "$FLK_FAKE_PEERS/alias1.env"
  mkdir -p "$R/other"; sed 's/host = "peer1"/host = "alias1"/; s/^app = .*/app = "flkt-alias-'"$RUN_ID"'"/' "$SRC/flk.toml" >"$R/other/flk.toml"
  local out; out=$(DIR="$R/other" here launch --no-deploy 2>&1) && fail "launched under a name the peer doesn't answer to"
  assert_contains "$out" "calls itself 'peer1'"
  # ...and [peers] maps a name to a destination
  printf 'name = "here"\n[peers]\n  peer1 = "alias1"\n' >"$R/here-host.toml"
  assert_eq peer1 "$(here -H peer1 version --json | json_get host)"
  assert_contains "$(tail -1 "$FLK_FAKE_PEERS/calls.log")" "alias1: " "the mapped destination was used"
  echo 'name = "here"' >"$R/here-host.toml"
}

test_stdin_reaches_secrets_and_nothing_else() {
  echo "s3cret value" | here secrets set TOKEN=- --stage >/dev/null || fail "secrets set from stdin"
  assert_contains "$(peer -a "$PEER_APP" secrets list)" "TOKEN"
  [[ $(tail -3 "$FLK_FAKE_PEERS/calls.log") != *s3cret* ]] || fail "the secret was on a command line"
  local left; left=$(printf 'one\ntwo\n' | { here status >/dev/null; cat; })
  assert_eq $'one\ntwo' "$left" "status left the caller's stdin alone"
}

test_a_second_send_removes_what_is_gone_and_keeps_what_is_ignored() {
  local there="$R/peer1-state/src/$PEER_APP"
  mkdir -p "$there/logs"; echo kept >"$there/logs/hook.log"
  rm "$SRC/bin/hook"; echo new >"$SRC/bin/hook2"
  here launch --no-deploy >/dev/null 2>&1 || fail "second launch"
  [[ ! -e $there/bin/hook && -f $there/bin/hook2 ]] || fail "the copy doesn't match the source"
  assert_eq kept "$(cat "$there/logs/hook.log")" "an ignored path on the peer survives"
}

test_host_peers() {
  local out; out=$(here peers --json)
  assert_eq peer1 "$(json_get 0.name <<<"$out")"
  assert_eq true "$(json_get 0.reachable <<<"$out")"
  assert_eq peer1 "$(json_get 0.host <<<"$out")"
  assert_eq "[\"$PEER_APP\"]" "$(json_get 0.apps <<<"$out" | tr -d ' ')"
  assert_eq true "$(json_get 0.same_version <<<"$out")"
  printf 'name = "here"\n[peers]\n  gone = "nowhere"\n' >"$R/here-host.toml"
  out=$(here peers --json) && fail "an unreachable peer exits 0"
  assert_eq false "$(ruby -rjson -e 'puts JSON.parse($stdin.read).find { _1["name"] == "gone" }["reachable"]' <<<"$out")"
  echo 'name = "here"' >"$R/here-host.toml"
}

test_a_bad_host_key_fails_before_anything_is_sent() {
  mkdir -p "$R/bad"; printf 'app = "flkt-bad-%s"\n[flk]\n  host = "-oX"\n' "$RUN_ID" >"$R/bad/flk.toml"
  local n out; n=$(wc -l <"$FLK_FAKE_PEERS/calls.log")
  out=$(DIR="$R/bad" here deploy 2>&1) && fail "deployed with a bad [flk] host"
  assert_contains "$out" "[flk] host is the name of a flk host"
  assert_eq "$n" "$(wc -l <"$FLK_FAKE_PEERS/calls.log")" "nothing was sent"
}

test_destroy_there_forgets_the_app_here() {
  here -H peer1 apps destroy "$PEER_APP" --yes >/dev/null 2>&1 || fail "destroy on the peer"
  assert_eq "{}" "$(tr -d ' \n' <"$HERE_HOME/remote_apps.json")"
  [[ $(peer apps list --json | tr -d ' \n') == "[]" ]] || fail "the app is still on the peer"
}
