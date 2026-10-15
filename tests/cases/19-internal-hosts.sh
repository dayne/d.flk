# [flk] internal_hosts: APP.internal and ID.vm.APP.internal in the guest's
# /etc/hosts, at boot and kept current while machines come and go.
# Long-running hello machines.
TIER=vm

setup_file() {
  stage_app hello
  toml_append '[experimental]' '  cmd = ["sh", "-c", "echo up; exec sleep 600"]' \
              '[[restart]]' '  policy = "never"' \
              '[flk]' '  internal_hosts = true'
  flk launch --no-deploy
  flk deploy
  wait_log "up" 30
}

teardown_file() { destroy_app; }

hosts_of() { flk exec -i "$1" -- cat /etc/hosts; }
# the line for IP in machine ID's /etc/hosts
line_for() { hosts_of "$1" | grep -E "^$2 .*\.internal" || true; }

test_block_at_boot() {
  local id ip; id=$(machine_id); ip=$(machine_ip)
  assert_eq "$ip $APP.internal $id.vm.$APP.internal $(machines name | head -n 1).vm.$APP.internal" \
    "$(line_for "$id" "$ip")" "own line"
  assert_eq 1 "$(hosts_of "$id" | grep -c '^# flk internal hosts')" "one block"
  assert_contains "$(flk exec -- getent hosts "$APP.internal")" "$ip" "resolves"
  assert_eq "[\"$APP.internal\",\"$id.vm.$APP.internal\",\"$(machines name | head -n 1).vm.$APP.internal\"]" \
    "$(flk status --json | json_get machines.0.internal_names)" "internal_names in status JSON"
}

test_kept_current_as_machines_change() {
  local id1 id2 ip2
  id1=$(machine_id 1)
  flk scale count 2 >/dev/null
  id2=$(machine_id 2); ip2=$(machine_ip 2)
  wait_until 30 eval '[[ $(line_for "$id1" "$ip2") == "$ip2 $APP.internal "* ]]' ||
    fail "machine 1 doesn't list machine 2 under $APP.internal: $(hosts_of "$id1")"
  flk machine stop "$id2" >/dev/null
  wait_until 30 eval '[[ $(line_for "$id1" "$ip2") == "$ip2 $id2.vm.$APP.internal "* ]]' ||
    fail "a stopped machine is still under $APP.internal: $(hosts_of "$id1")"
  assert_eq 1 "$(hosts_of "$id1" | grep -c '^# flk internal hosts')" "still one block"
  flk context --json | ruby -rjson -e 'm = JSON.parse($stdin.read)["app"]["machines"].find { _1["id"] == ARGV[0] }
    exit(m["internal_names"].none? { _1 == "#{ARGV[1]}.internal" } ? 0 : 1)' "$id2" "$APP" ||
    fail "a stopped machine's internal_names still has $APP.internal"
  assert_contains "$(hosts_of "$id1")" "127.0.0.1" "the rest of /etc/hosts kept"
}
