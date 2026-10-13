# [flk.backup] before_deploy: deploys back up the volumes while the machine
# is stopped for the update; a failed health check puts them back with the
# old release; releases rollback --with-volumes restores them later. One
# mcshadow machine (it counts its boots on the volume); tests run in order.
TIER=vm

BK="$WORK/backups-42-$RUN_ID"
export FLK_HOST_CONFIG="$WORK/host-42-$RUN_ID.toml"

setup_file() {
  stage_app mcshadow
  mkdir -p "$BK"
  printf 'backup_dir = "%s"\n' "$BK" >"$FLK_HOST_CONFIG"
  toml_append '' '[flk.backup]' '  before_deploy = true'
  flk launch --no-deploy
  flk volumes create world --size 1
  flk deploy
  wait_mc 60
}

teardown_file() { destroy_app; rm -rf "$BK" "$FLK_HOST_CONFIG"; }

release_json() { flk releases --json | ruby -rjson -e 'r = JSON.parse($stdin.read).find { _1["version"] == ARGV[0].to_i }
  puts JSON.generate(r)' "$1"; }
before_deploy_backups() { flk volumes backups --json | ruby -rjson -e '
  puts JSON.parse($stdin.read).select { _1["reason"] == "before_deploy" }.map { "#{_1["release"]}->#{_1["for_release"]}" }.join(" ")'; }

test_deploy_backs_up_the_volume_first() {
  local out
  out=$(flk deploy 2>&1) || fail "deploy failed: $out"
  assert_contains "$out" "no machine running"
  assert_eq "1->2" "$(before_deploy_backups)" "a backup of v1's data, taken for v2"
  assert_eq world "$(release_json 2 | json_get backups.0.volume)" "release v2 records it"
  wait_mc 60
}

test_failed_deploy_restores_the_volume() {
  local boots out; boots=$(mcq flk.boots)
  sed -i '/^\[flk.backup\]/i [checks.never]\n  type = "tcp"\n  port = 9\n  grace_period = "4s"\n' "$APP_DIR/flk.toml"
  out=$(flk deploy 2>&1) && fail "deploy passed a check nothing answers"
  assert_contains "$out" "is back on v2 with its volumes as they were"
  wait_mc 60
  # v3 booted once (boots+1 on the volume), then the volume went back to
  # the backup (boots) and v2 booted on it: boots+1, not boots+2
  assert_eq $((boots + 1)) "$(mcq flk.boots)" "boots after the restored rollback"
  sed -i '/^\[checks.never\]/,/^$/d' "$APP_DIR/flk.toml"
}

test_rollback_with_volumes() {
  local out
  out=$(flk releases rollback v1 --with-volumes 2>&1) || fail "rollback failed: $out"
  assert_contains "$out" "rollback to v1 with volumes"
  assert_contains "$out" "volume world <- world-"
  wait_mc 60
  # v1's data had 1 boot; this is the next
  assert_eq 2 "$(mcq flk.boots)" "the volume is v1's again"
  [[ $(before_deploy_backups) == *"2->4"* ]] || fail "the current data wasn't backed up first: $(before_deploy_backups)"
}

test_rollback_with_volumes_needs_backups() {
  rm -f "$BK"/*/world/*
  local out
  out=$(flk releases rollback v2 --with-volumes 2>&1) && fail "rolled back volumes with no backups"
  assert_contains "$out" "no before-deploy backup from v2"
}
