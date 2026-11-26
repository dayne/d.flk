# A deploy sent to another host boots there: the release says where it
# came from, and the app's commands follow [flk] host (09-remote.sh has
# the rules without VMs). The "peer" is this machine under another host
# name and the real FLK_HOME (machines need its taps), through
# tests/lib/fake-ssh; "here" has a state dir of its own.
TIER=vm

R="$WORK/remote-vm-$RUN_ID"
export FLK_FAKE_PEERS="$R/peers" FLK_SSH="$TESTS/lib/fake-ssh"

# (run.sh pins every test to this host with FLK_HOST=local: lifted here)
here() { (cd "$APP_DIR" && unset FLK_HOST && FLK_HOME="$R/here-home" FLK_HOST_CONFIG="$R/here-host.toml" "$FLK_BIN" "$@"); }

setup_file() {
  mkdir -p "$FLK_FAKE_PEERS" "$R/here-home" "$R/peer-home" "$R/bin"
  ln -s "$FLK_BIN" "$R/bin/flk"
  echo 'name = "here"' >"$R/here-host.toml"
  echo 'name = "peer1"' >"$R/peer-host.toml"
  cat >"$FLK_FAKE_PEERS/peer1.env" <<ENV
export FLK_HOME="$FLK_HOME" FLK_HOST_CONFIG="$R/peer-host.toml" PEER_HOME="$R/peer-home" PATH="$R/bin:$PATH"
ENV
  stage_app hello
  toml_append '[flk]' '  host = "peer1"'
  git -C "$APP_DIR" init -q && git -C "$APP_DIR" -c user.name=t -c user.email=t@t add -A &&
    git -C "$APP_DIR" -c user.name=t -c user.email=t@t commit -qm one
  here launch
}

teardown_file() { destroy_app; rm -rf "$R"; }

test_it_booted_on_the_peer() {
  wait_log "hello world" 30                       # the real FLK_HOME is the peer's
  [[ ! -d $R/here-home/apps/$APP ]] || fail "the app exists on the sending host"
  assert_contains "$(here logs --no-tail)" "hello world" "logs come from the peer"
}

test_the_release_says_where_it_came_from() {
  local rel; rel=$(here releases --json)
  assert_eq here "$(json_get 0.origin.host <<<"$rel")"
  assert_eq "$APP_DIR" "$(json_get 0.origin.path <<<"$rel")"
  assert_eq "$(git -C "$APP_DIR" rev-parse --short=12 HEAD)" "$(json_get 0.origin.commit <<<"$rel")"
  assert_eq false "$(json_get 0.origin.dirty <<<"$rel")"
  assert_contains "$(here releases)" "FROM"
  assert_contains "$(cat "$FLK_HOME/src/$APP/.flk-origin")" "from here:$APP_DIR"
}

test_a_changed_tree_deploys_as_dirty_and_keeps_the_marker() {
  wait_until 30 is_stopped
  echo "# changed" >>"$APP_DIR/Dockerfile"
  here deploy >/dev/null 2>&1 || fail "second deploy"
  assert_eq true "$(here releases --json | json_get 1.origin.dirty)"
  assert_contains "$(here releases)" "here@$(git -C "$APP_DIR" rev-parse --short=12 HEAD)+"
  [[ -f $FLK_HOME/src/$APP/.flk-origin ]] || fail "the marker was removed by the second send"
  assert_contains "$(cat "$FLK_HOME/src/$APP/Dockerfile")" "# changed"
}

test_destroy_removes_the_sent_directory() {
  here -H peer1 apps destroy "$APP" --yes >/dev/null 2>&1 || fail "destroy"
  [[ ! -e $FLK_HOME/src/$APP ]] || fail "the sent directory outlived the app"
}
