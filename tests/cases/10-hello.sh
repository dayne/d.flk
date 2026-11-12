# hello: build, boot, print, exit, power off. The smallest end-to-end loop.
TIER=vm

setup_file() {
  stage_app hello
  flk launch --no-deploy
  flk deploy
}

teardown_file() { destroy_app; }

test_prints_hello_world() {
  wait_log "hello world" 30
}

test_fly_env_in_guest() {
  wait_log "app=$APP region=local release=v1" 30
}

test_app_exit_powers_off_vm() {
  wait_until 30 is_stopped || fail "machine still running after app exited"
  wait_log "app exited with status 0; powering off" 5
}

test_machine_start_boots_again() {
  wait_until 30 is_stopped
  local before; before=$(log_count "hello world")
  flk machine start "$(machine_id)"
  wait_until 30 log_count_gt "$before" "hello world" || fail "no second 'hello world' after machine start"
}

test_redeploy_keeps_machine() {
  wait_until 30 is_stopped
  local id; id=$(machine_id)
  flk deploy
  assert_eq "$id" "$(machine_id)" "machine id after redeploy"
  assert_eq 1 "$(machine_count)" "machine count"
  wait_log "release=v2" 30
}

test_experimental_cmd_and_exit_status() {
  wait_until 30 is_stopped
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo custom cmd; exit 3"]' \
              '[[restart]]' '  policy = "never"' # restarts are 12-restart's business
  flk deploy
  wait_log "custom cmd" 30
  wait_log "app exited with status 3" 10
}

test_old_releases_pruned() {
  wait_until 30 is_stopped
  flk deploy
  local n; n=$(ls "$FLK_HOME/apps/$APP/images"/v*.ext4 | wc -l)
  ((n <= 2)) || fail "expected at most 2 release images, found $n"
  local rels; rels=$(flk releases)
  assert_contains "$rels" "v1" "releases list keeps history"
}

test_stop_when_already_stopped() {
  wait_until 30 is_stopped
  assert_ok flk machine stop "$(machine_id)"
}

# G10, G8: the app's release image is listed, and counted by flk disk.
test_images_and_disk_see_the_release() {
  # The redeploys above leave more than one release image; check the current one.
  local img; img=$(flk images --json | ruby -rjson -e 'i = JSON.parse($stdin.read).find { _1["app"] == ARGV[0] && _1["current"] }
    puts JSON.generate(i)' "$APP")
  [[ $img != null ]] || fail "flk images lists no current image for $APP: $(flk images --json)"
  assert_eq false "$(json_get orphan <<<"$img")" "orphan"
  [[ $(json_get size_bytes <<<"$img") -gt 0 ]] || fail "no size: $img"
  local d; d=$(flk disk --json | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read)["apps"].find { _1["app"] == ARGV[0] })' "$APP")
  [[ $(json_get images.bytes <<<"$d") -gt 0 ]] || fail "release image not counted: $d"
  [[ $(json_get rootfs.apparent <<<"$d") -gt 0 ]] || fail "machine rootfs not counted: $d"
  # Every kept release has its build's output (valheim BUGS #2).
  local log; log=$(flk releases --json | ruby -rjson -e 'puts JSON.parse($stdin.read).find { _1["current"] }["build_log"]')
  [[ $log == */builds/v*.log && -s $log ]] || fail "current release has no build log: $log"
  grep -q '^==> \|STEP\|rootfs:' "$log" || fail "build log has no build output: $(head -3 "$log")"
  cmp -s "$log" <(flk releases log) || fail "flk releases log isn't the current release's build log"
  # labelled, so podman image prune -a --filter label!=flk.app spares it (mud BUGS #5)
  if [[ ${FLK_ENGINE:-podman} == podman ]]; then
    local tag; tag=$(json_get repo <<<"$img"):$(json_get tag <<<"$img")
    assert_eq "$APP $(json_get release <<<"$img")" \
      "$(podman image inspect --format '{{index .Labels "flk.app"}} {{index .Labels "flk.release"}}' "$tag")" "image labels"
  fi
}

# mud BUGS #4: host backups skip machines' root disks (copies of the
# release image); after a restore, start makes the missing one again.
test_start_recreates_a_missing_root_disk() {
  wait_until 30 is_stopped
  local id; id=$(machine_id)
  rm "$FLK_HOME/apps/$APP/machines/$id/rootfs.ext4"
  local before out; before=$(log_count "custom cmd") # test_experimental_cmd's CMD is still on
  out=$(flk machine start "$id" 2>&1) || fail "start failed: $out"
  assert_contains "$out" "root disk was missing; made again from v"
  wait_until 30 log_count_gt "$before" "custom cmd" || fail "didn't boot on the new root disk"
}

# flkforge BUGS.flk.md #1: any http check crashed deploy (NameError: Net
# inside Flk is Flk::Net). The app becomes a tiny web server (busybox nc;
# alpine has no httpd) answering with a status: 200 passes the check, 500
# fails it and the machine goes back.
test_http_checks_gate_the_deploy() {
  wait_until 30 is_stopped
  web_toml() {
    cat >"$APP_DIR/flk.toml" <<TOML
app = "$APP"
[build]
  dockerfile = "Dockerfile"
[experimental]
  cmd = ["sh", "-c", "while :; do { printf 'HTTP/1.0 $1 X\\r\\nContent-Length: 2\\r\\n\\r\\nok'; sleep 1; } | nc -l -p 8080 >/dev/null; done"]
[[vm]]
  cpus = 1
  memory_mb = 128
[checks.web]
  type = "http"
  port = 8080
  path = "/"
  grace_period = "$2"
TOML
  }
  local out
  web_toml 200 30s
  out=$(flk deploy 2>&1) || fail "deploy with a passing http check failed: $out"
  assert_contains "$out" "check web (http"
  web_toml 500 5s
  out=$(flk deploy 2>&1) && fail "a 500 passed the http check: $out"
  assert_contains "$out" "failed its health checks"
  [[ $out == *NameError* ]] && fail "crashed: $out"
  true
}
