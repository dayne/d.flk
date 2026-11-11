# flk build: the image and rootfs a deploy would make, and what flk will
# do with them, without a release or machines (PLAN M6). Needs the
# container engine, not VMs; the vm tier only for that.
TIER=vm

setup_file() {
  stage_app hello
  cat >>"$APP_DIR/Dockerfile" <<'DF'
RUN adduser -D -u 1100 app && mkdir -p /data && echo hi >/data/seed && chown -R app:app /data
USER app
WORKDIR /data
DF
  toml_append '[[mounts]]' '  source = "data"' '  destination = "/data"'
}

teardown_file() {
  "$FLK_BIN" apps destroy "$APP" --yes >/dev/null 2>&1 || true
  podman rmi "flk.local/$APP:build" >/dev/null 2>&1 || true
  rm -rf "$FLK_HOME/build/$APP"
}

built() { (cd "$APP_DIR" && flk build --json 2>/dev/null); }

test_build_without_an_app() {
  local j; j=$(built) || fail "flk build failed: $(cd "$APP_DIR" && flk build 2>&1 | tail -5)"
  assert_eq "$APP" "$(json_get app <<<"$j")"
  assert_eq true "$(json_get ok <<<"$j")"
  assert_eq shell "$(json_get init <<<"$j")"
  assert_eq image "$(json_get cmd_from <<<"$j")"
  assert_eq /data "$(json_get workdir <<<"$j")"
  assert_eq app "$(json_get user.name <<<"$j")"
  assert_eq 1100 "$(json_get user.uid <<<"$j")"
  # Alpine's busybox has no setpriv --reuid: flk-agent switches instead
  assert_eq agent "$(json_get user.switch <<<"$j")" "busybox image, flk-agent switches"
  assert_eq true "$(json_get mounts.0.in_image <<<"$j")"
  assert_eq 1100 "$(json_get mounts.0.uid <<<"$j")"
  assert_eq 1 "$(json_get mounts.0.entries <<<"$j")" "the file the volume hides"
  [[ -f $(json_get build_log <<<"$j") ]] || fail "no build log"
  [[ ! -e $FLK_HOME/build/$APP/rootfs.ext4 ]] || fail "the rootfs was left behind"
  podman image exists "flk.local/$APP:build" || fail "no flk.local/$APP:build"
  [[ ! -d $FLK_HOME/apps/$APP ]] || fail "flk build registered the app"
}

test_build_says_it_in_words() {
  local out; out=$(cd "$APP_DIR" && flk build 2>&1) || fail "flk build failed: $out"
  assert_contains "$out" "✔ Built $APP from Dockerfile"
  assert_contains "$out" "app (1100:1100), switched by flk-agent"
  assert_contains "$out" "1 entry the volume hides"
  assert_contains "$out" "Next: flk launch --no-deploy"
}

test_trial_builds_are_listed_and_pruned() {
  built >/dev/null || fail "flk build failed"
  local row; row=$(flk images --json | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read).find { _1["repo"] == "flk.local/" + ARGV[0] } || {})' "$APP")
  assert_eq true "$(json_get trial <<<"$row")"
  assert_eq false "$(json_get orphan <<<"$row")" "a flk build isn't a destroyed app's image"
  ruby -I"$FLK_SRC/lib" -rflk -e 'exit(Flk::Image.orphan_repos.include?(ARGV[0]) ? 1 : 0)' "$APP" ||
    fail "doctor would call it a destroyed app's image"
  assert_contains "$(flk images prune --dry-run)" "flk.local/$APP:build"
}

test_build_failure_says_why() {
  local d="$WORK/bad-$RUN_ID"; mkdir -p "$d"
  printf 'app = "%s-bad"\n' "$APP" >"$d/flk.toml"
  printf 'FROM docker.io/library/alpine:3.20\nRUN echo "ERROR: no such package" && false\n' >"$d/Dockerfile"
  local out; out=$(cd "$d" && "$FLK_BIN" build 2>&1) && fail "a failing build passed"
  assert_contains "$out" "ERROR: no such package"
  assert_contains "$out" "Build log: $FLK_HOME/build/$APP-bad/build.log"
  local j; j=$(cd "$d" && "$FLK_BIN" build --json 2>/dev/null) && fail "a failing build passed (--json)"
  assert_eq false "$(json_get ok <<<"$j")" "--json on a failure"
  assert_contains "$(json_get said <<<"$j")" "ERROR: no such package"
  assert_eq "$FLK_HOME/build/$APP-bad/build.log" "$(json_get build_log <<<"$j")"
  assert_contains "$(flk images prune --dry-run)" "$FLK_HOME/build/$APP-bad"
  rm -rf "$FLK_HOME/build/$APP-bad"
}

test_destroy_removes_the_trial_build() {
  built >/dev/null || fail "flk build failed"
  (cd "$APP_DIR" && flk launch --no-deploy >/dev/null) || fail "launch failed"
  flk apps destroy "$APP" --yes >/dev/null
  ! podman image exists "flk.local/$APP:build" || fail "apps destroy left flk.local/$APP:build"
  [[ ! -d $FLK_HOME/build/$APP ]] || fail "apps destroy left $FLK_HOME/build/$APP"
}

# ---------- warnings (PLAN M6: what flk can see before anything runs) ----------

# warn_codes DIR: the codes flk build --json gives for the app in DIR
warn_codes() { (cd "$1" && "$FLK_BIN" build --json 2>/dev/null) | ruby -rjson -e 'puts JSON.parse($stdin.read)["warnings"].map { _1["code"] }.join(" ")'; }

scratch_app() { # NAME DOCKERFILE_LINES...: a throwaway app dir, echoed
  local d="$WORK/$1-$RUN_ID"; mkdir -p "$d"; shift
  printf 'app = "%s"\n' "$(basename "$d")" >"$d/flk.toml"
  printf '%s\n' "$@" >"$d/Dockerfile"
  echo "$d"
}

test_warnings_from_the_image() {
  local d codes
  d=$(scratch_app "$APP-w1" 'FROM docker.io/library/alpine:3.20' 'CMD []')
  assert_eq no-cmd "$(warn_codes "$d")" "no CMD"
  d=$(scratch_app "$APP-w2" 'FROM docker.io/library/alpine:3.20' 'RUN adduser -D -u 1100 app && install -d -o 1200 /srv/x' \
    'USER ghost' 'CMD ["true"]')
  assert_eq user-unknown "$(warn_codes "$d")" "a USER the image doesn't have"
  d=$(scratch_app "$APP-w3" 'FROM docker.io/library/alpine:3.20' 'RUN adduser -D -u 1100 app && install -d -o 1200 /srv/x && touch /etc/motd' \
    'USER app' 'CMD ["true"]')
  printf '[[mounts]]\n  source = "x"\n  destination = "/srv/x"\n[[mounts]]\n  source = "motd"\n  destination = "/etc/motd"\n' >>"$d/flk.toml"
  codes=$(warn_codes "$d")
  assert_contains "$codes" mount-owner-differs
  assert_contains "$codes" mount-not-dir
  codes=$(warn_codes "$APP_DIR")
  assert_eq mount-hides-files "$codes" "the staged app: /data has a file"
  local out; out=$(flk build 2>&1)
  assert_contains "$out" "⚠ the volume at /data hides the 1 entry the image has there"
  assert_contains "$out" "fix: copy them in at first start"
  for d in w1 w2 w3; do rm -rf "$FLK_HOME/build/$APP-$d-$RUN_ID"; podman rmi "flk.local/$APP-$d-$RUN_ID:build" >/dev/null 2>&1 || true; done
}

test_a_mount_source_that_isnt_a_volume_name() {
  local d; d=$(scratch_app "$APP-w4" 'FROM docker.io/library/alpine:3.20')
  printf '[[mounts]]\n  source = "my-data"\n  destination = "/data"\n' >>"$d/flk.toml"
  assert_contains "$(cd "$d" && "$FLK_BIN" config show 2>&1)" "source \\\"my-data\\\" isn't a volume name"
}
