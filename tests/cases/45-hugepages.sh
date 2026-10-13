# [[vm]] huge_pages = "2M" needs a reserved pool: without one, deploy
# refuses before building and prints the commands; with one, it boots.
TIER=vm

# Each test stages its own app inside the test's subshell, where
# teardown_file can't see it: so each removes it on the way out.
pool_available() { awk '/^HugePages_Free/ {f=$2} /^HugePages_Rsvd/ {r=$2} END {print f-r}' /proc/meminfo; }

test_2m_without_a_pool_is_refused_before_building() {
  [[ $(pool_available) -lt 64 ]] || skip_test "this host has a huge page pool; the refusal can't be shown"
  stage_app hello pool
  trap destroy_app EXIT
  sed -i 's/^\(\s*\)memory_mb = 128$/&\n\1huge_pages = "2M"/' "$APP_DIR/flk.toml"
  flk launch --no-deploy >/dev/null
  local out
  out=$(flk deploy 2>&1) && fail "deployed 2M huge pages without a pool"
  assert_contains "$out" "needs 64 free 2M huge pages"
  assert_contains "$out" "sudo sysctl -w vm.nr_hugepages="
  [[ $out != *"Building"* ]] || fail "it built before refusing"
  assert_eq "[]" "$(flk releases --json | tr -d ' \n')" "no release recorded"
}

test_2m_with_a_pool_boots() {
  [[ $(pool_available) -ge 64 ]] || skip_test "no huge page pool (sudo sysctl -w vm.nr_hugepages=64 to run this)"
  stage_app hello pool2
  trap destroy_app EXIT
  sed -i 's/^\(\s*\)memory_mb = 128$/&\n\1huge_pages = "2M"/' "$APP_DIR/flk.toml"
  flk launch --no-deploy >/dev/null
  flk deploy >/dev/null 2>&1 || fail "deploy with a pool failed"
  wait_log "hello world" 30
  assert_eq 2M "$(flk machine config "$(machine_id)" | json_get machine-config.huge_pages)" "firecracker config"
}
