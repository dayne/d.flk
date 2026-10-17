# CLI surface: help generated from the command table, strict arguments,
# --json output, no hangs without a terminal. No VMs, no root.
TIER=fast

setup_file() {
  stage_app hello
  flk launch --no-deploy
}

teardown_file() { destroy_app; }

# every command / subcommand in the table has a handler and working help
test_command_table_complete() {
  ruby -I"$FLK_SRC/lib" -rflk -e '
    cli = Flk::CLI.new
    Flk::Commands.all.each do |c|
      (c[:subs] || [nil]).each do |s|
        h = Flk::Commands.handler(c, s)
        abort "no handler #{h} for flk #{c[:name]} #{s&.dig(:name)}" unless cli.respond_to?(h, true)
        Array((s || c)[:opts]).each { Flk::Commands.key(_1) }
      end
      abort "#{c[:name]}: default_sub not a subcommand" if c[:default_sub] && !Flk::Commands.find(c[:default_sub], c[:subs])
    end'
  local name
  for name in $(ruby -I"$FLK_SRC/lib" -rflk -e 'puts Flk::Commands.all.map { _1[:name] }'); do
    assert_contains "$("$FLK_BIN" help "$name")" "Usage: flk $name" "flk help $name"
    assert_contains "$("$FLK_BIN" "$name" --help)" "Usage: flk $name" "flk $name --help"
  done
}

test_short_help_lists_commands() {
  local out; out=$("$FLK_BIN" help)
  assert_contains "$out" "context"
  assert_contains "$out" "flk help --all"
  assert_eq "$out" "$("$FLK_BIN")" "bare flk = flk help"
}

test_help_all_is_complete() {
  local out; out=$("$FLK_BIN" help --all)
  [[ $out != *"{{"* ]] || fail "unfilled placeholder in help --all"
  local name
  for name in $(ruby -I"$FLK_SRC/lib" -rflk -e 'puts Flk::Commands.all.map { _1[:name] }'); do
    assert_contains "$out" "#### flk $name" "help --all section for $name"
  done
  "$FLK_BIN" help --all --json | json_get commands.0.name >/dev/null || fail "help --all --json isn't JSON"
}

test_unknown_arguments_rejected() {
  local out
  out=$(flk status --jsno 2>&1) && fail "accepted --jsno"
  assert_contains "$out" "did you mean --json"
  out=$(flk stauts 2>&1) && fail "accepted 'stauts'"
  assert_contains "$out" "did you mean 'status'"
  out=$(flk machine strat 2>&1) && fail "accepted 'machine strat'"
  assert_contains "$out" "did you mean 'start'"
  out=$(flk status extra 2>&1) && fail "accepted an extra argument"
  assert_contains "$out" "unexpected argument 'extra'"
  out=$(flk volumes create 2>&1) && fail "accepted volumes create without a name"
  assert_contains "$out" "missing arguments"
}

# OptionParser hands a literal --no-x switch false; flk must treat it as given
test_no_flags_are_true() {
  local out; out=$(flk launch --no-deploy 2>&1)
  assert_contains "$out" "Next: "
  assert_eq "[]" "$(flk releases --json | tr -d ' \n')" "no release from launch --no-deploy"
}

test_json_outputs_for_a_fresh_app() {
  assert_eq "$APP" "$(flk status --json | json_get app.name)" "status --json"
  assert_eq "[]" "$(flk machine list --json | tr -d ' \n')" "machine list --json"
  assert_eq "[]" "$(flk volumes list --json | tr -d ' \n')" "volumes list --json"
  assert_eq "[]" "$(flk secrets list --json | tr -d ' \n')" "secrets list --json"
  flk ports list --json | json_get active >/dev/null
  "$FLK_BIN" apps list --json | ruby -rjson -e 'exit JSON.parse($stdin.read).any? { _1["name"] == ARGV[0] }' "$APP" ||
    fail "apps list --json lacks $APP"
}

test_context_for_a_fresh_app() {
  local c; c=$(flk context --json)
  assert_eq "$APP" "$(json_get app.name <<<"$c")" app
  assert_eq true "$(json_get app.registered <<<"$c")" registered
  assert_contains "$(json_get next_steps <<<"$c")" "flk deploy" "next steps"
  assert_contains "$(flk context)" "## Next steps" "text context"
}

test_context_without_an_app() {
  local out; out=$(cd "$WORK" && "$FLK_BIN" context)
  assert_contains "$out" "config: none"
  assert_contains "$out" "flk launch"
}

test_no_hangs_without_a_terminal() {
  local out
  out=$(timeout 5 "$FLK_BIN" apps destroy "$APP" </dev/null 2>&1) && fail "destroyed without --yes"
  [[ $? != 124 ]] || fail "apps destroy waited for input"
  assert_contains "$out" "pass --yes"
  out=$(timeout 5 "$FLK_BIN" -a "$APP" console </dev/null 2>&1) && fail "console ran without a terminal"
  assert_contains "$out" "interactive terminal"
  assert_contains "$out" "--send TEXT" "points agents at --send"
  out=$("$FLK_BIN" -a "$APP" console --wait-log x 2>&1) && fail "--wait-log without --send"
  assert_contains "$out" "go with --send"
  mkdir -p "$FLK_HOME/apps/$APP/machines/fake"
  printf '{"id":"fake","name":"fake","tap_index":99,"created_at":"2000-01-01T00:00:00Z","config":{"mounts":[]}}' \
    >"$FLK_HOME/apps/$APP/machines/fake/machine.json"
  echo "boot line" >"$FLK_HOME/apps/$APP/machines/fake/console.log"
  out=$(timeout 5 "$FLK_BIN" -a "$APP" logs 2>&1); local rc=$?
  rm -rf "$FLK_HOME/apps/$APP/machines/fake"
  ((rc != 124)) || fail "flk logs kept following without a terminal"
  assert_contains "$out" "boot line" "logs output"
}

# A deploy that can't place its machines fails before the (slow) build and
# records no release, so the next deploy doesn't inherit an empty vN.
test_deploy_checks_volumes_before_building() {
  stage_app hello own
  trap destroy_app EXIT
  toml_append '[[mounts]]' '  source = "data"' '  destination = "/data"'
  flk launch --no-deploy >/dev/null
  local out
  out=$(cd "$WORK" && "$FLK_BIN" -a "$APP" deploy 2>&1) && fail "deployed without the volume [[mounts]] needs"
  assert_contains "$out" "not enough free volumes for [[mounts]] source 'data'"
  assert_contains "$out" "flk volumes create data --size 1"
  [[ $out != *"==> Building"* && $out != *"==> Release"* ]] || fail "started building before checking volumes"
  assert_eq "[]" "$(flk releases --json | tr -d ' \n')" "releases after the failed deploy"
  [[ -z $(ls "$FLK_HOME/apps/$APP/images" 2>/dev/null) ]] || fail "left an image behind"
}

# Ubuntu/Debian podman has no search registries: FROM ruby:3.3 fails to
# resolve. doctor warns, and deploy turns podman's error into the fix.
no_registries() { CONTAINERS_REGISTRIES_CONF=/dev/null "$@"; }

test_short_image_names_explained() {
  command -v podman >/dev/null && [[ ${FLK_ENGINE:-podman} == podman ]] || skip_test "podman only"
  no_registries podman info --format '{{json .Registries}}' | grep -q '"search"' &&
    skip_test "can't hide this host's search registries (drop-in dir?)"
  assert_contains "$(no_registries "$FLK_BIN" doctor --json)" "can't resolve short image names" "doctor warning"

  stage_app hello own
  trap destroy_app EXIT
  echo 'FROM ruby:3.3' >"$APP_DIR/Dockerfile"
  flk launch --no-deploy >/dev/null
  local out
  out=$(cd "$APP_DIR" && no_registries "$FLK_BIN" deploy 2>&1) && fail "deploy resolved ruby:3.3 without registries"
  assert_contains "$out" 'short image name "ruby:3.3"'
  assert_contains "$out" "registries.conf.d/50-flk-docker-io.conf"
  assert_contains "$out" "FROM docker.io/library/ruby:3.3"
  assert_eq "[]" "$(flk releases --json | tr -d ' \n')" "no release from the failed build"
}

test_logpipe_rotates() {
  local d; d=$(mktemp -d "$WORK/logpipe.XXXX")
  seq 1 5000 | "$FLK_SRC/libexec/flk-logpipe" "$d/console.log" 10000
  (($(stat -c %s "$d/console.log") <= 10010)) || fail "console.log grew past the limit"
  [[ -s $d/console.log.1 ]] || fail "no console.log.1"
  assert_eq 5000 "$(tail -n 1 "$d/console.log")" "last line kept"
  printf 'partial' | "$FLK_SRC/libexec/flk-logpipe" "$d/p.log" 100
  assert_eq partial "$(cat "$d/p.log")" "unterminated last line"
}

# Volumes outside flk's state dir: created with --path, filled --from-dir,
# or imported. flk never deletes their files unless told to.
test_external_volumes() {
  local d; d=$(mktemp -d "$WORK/vols.XXXX")
  flk volumes create ext --size 1 --path "$d/ext.ext4" >/dev/null
  [[ -f $d/ext.ext4 ]] || fail "--path didn't create the file"
  assert_contains "$(flk volumes list)" "$d/ext.ext4" "volumes list shows the external file"
  assert_eq true "$(flk volumes list --json | json_get 0.external)" "external flag"

  local out
  touch "$d/other.ext4"
  out=$(flk volumes create ext2 --path "$d/other.ext4" 2>&1) && fail "overwrote an existing file"
  assert_contains "$out" "already exists"
  out=$(flk volumes import again --path "$d/ext.ext4" 2>&1) && fail "registered one file twice"
  assert_contains "$out" "is already volume"
  out=$(flk volumes create inroot --path "$FLK_HOME/x.ext4" 2>&1) && fail "accepted a --path inside FLK_HOME"
  assert_contains "$out" "inside flk's state dir"

  out=$(flk volumes destroy ext)
  assert_contains "$out" "file kept at $d/ext.ext4"
  [[ -f $d/ext.ext4 ]] || fail "destroy deleted an external file"

  flk volumes import ext --path "$d/ext.ext4" >/dev/null
  assert_eq 1 "$(flk volumes list --json | json_get 0.size_gb)" "imported size"
  flk volumes destroy ext --delete-data >/dev/null
  [[ ! -e $d/ext.ext4 ]] || fail "--delete-data kept the file"

  head -c 1M /dev/zero >"$d/junk.img"
  out=$(flk volumes import junk --path "$d/junk.img" 2>&1) && fail "imported a non-ext4 file"
  assert_contains "$out" "isn't an ext4 image"
}

test_volume_from_dir() {
  local d; d=$(mktemp -d "$WORK/fromdir.XXXX")
  mkdir -p "$d/src/world" && echo level >"$d/src/world/level.dat"
  flk volumes create seeded --size 1 --path "$d/seeded.ext4" --from-dir "$d/src" >/dev/null
  debugfs -R "cat /world/level.dat" "$d/seeded.ext4" 2>/dev/null | grep -q level || fail "level.dat not in the volume"
  flk volumes destroy seeded --delete-data >/dev/null
  truncate -s 2G "$d/src/big" # sparse: 2GB to du -b, nothing on disk
  local out
  out=$(flk volumes create toobig --size 1 --from-dir "$d/src" 2>&1) && fail "filled a 1GB volume from 2GB"
  assert_contains "$out" "too much for a 1GB volume"
}

test_help_topics() {
  local t out
  for t in cheatsheet install first-app operate troubleshoot uninstall; do
    out=$("$FLK_BIN" help "$t")
    [[ -n $out && $out != *"{{"* ]] || fail "flk help $t empty or has a placeholder"
  done
  assert_contains "$("$FLK_BIN" help --all)" "## Guide: Troubleshooting" "help --all includes the guides"
  assert_contains "$("$FLK_BIN" help)" "cheatsheet" "short help lists topics"
  out=$("$FLK_BIN" help troubleshot 2>&1) && fail "accepted a misspelled topic"
  assert_contains "$out" "did you mean 'troubleshoot'"
  # hints point at the real setup-host.sh, usable from any directory
  assert_contains "$("$FLK_BIN" help install)" "sudo $FLK_SRC/setup-host.sh"
}

test_completion_bash() {
  local f="$WORK/flk.bash"
  "$FLK_BIN" completion bash >"$f"
  bash -n "$f" || fail "completion script has a syntax error"
  local got
  got=$(PATH="$FLK_SRC/bin:$PATH" bash -c '. "$1"; COMP_WORDS=(flk machine st); COMP_CWORD=2; _flk; echo "${COMPREPLY[*]}"' _ "$f")
  assert_eq "start stop stats status" "$got" "flk machine st<TAB>"
  local out
  out=$("$FLK_BIN" completion fish 2>&1) && fail "accepted fish"
  assert_contains "$out" "only bash is supported"
}

# G11: lazyflk polls context, so it carries the config warnings
test_context_has_config_warnings() {
  assert_eq "[]" "$(flk context --json --no-host | json_get app.config_warnings)" "clean config"
  sed -i '1i kill_timout = 60' "$APP_DIR/flk.toml"
  assert_contains "$(flk context --json --no-host | json_get app.config_warnings)" "kill_timout (did you mean kill_timeout?)"
  assert_contains "$("$FLK_BIN" context --all --json --no-host | ruby -rjson -e \
    'puts JSON.parse($stdin.read)["apps"].find { _1["name"] == ARGV[0] }["config_warnings"]' "$APP")" "kill_timout" "context --all"
  assert_contains "$(flk context --json --no-host | json_get next_steps)" \
    "optional: flk.toml: unknown key kill_timout (did you mean kill_timeout?); flk ignores it" "next step"
  assert_contains "$("$FLK_BIN" context --all --json --no-host | json_get next_steps)" "$APP: optional: flk.toml: unknown key" "--all step"
  assert_contains "$(flk context --no-host)" "⚠ flk.toml: unknown key kill_timout" "text context"
  assert_contains "$("$FLK_BIN" context --all --no-host)" "⚠ flk.toml: unknown key kill_timout" "text overview"
  sed -i '1d' "$APP_DIR/flk.toml"
}

test_context_all() {
  local c; c=$("$FLK_BIN" context --all --json)
  ruby -rjson -e 'd = JSON.parse(ARGV[0]); exit d["apps"].any? { _1["name"] == ARGV[1] }' "$c" "$APP" ||
    fail "context --all lacks $APP"
  assert_contains "$("$FLK_BIN" context --all)" "## $APP" "text overview"
}

# A volume whose file lives outside flk's state dir is external even
# without the flag (hand-edited volumes.json): destroy must not delete it.
test_hand_edited_volume_path_is_external() {
  local d; d=$(mktemp -d "$WORK/hand.XXXX")
  flk volumes create hand --size 1 >/dev/null
  local vj="$FLK_HOME/apps/$APP/volumes.json"
  local old; old=$(json_get 0.path <"$vj")
  mv "$old" "$d/hand.ext4"
  ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0])); v[0]["path"] = ARGV[1]; File.write(ARGV[0], JSON.generate(v))' "$vj" "$d/hand.ext4"
  assert_contains "$(flk volumes destroy hand)" "file kept at $d/hand.ext4"
  [[ -f $d/hand.ext4 ]] || fail "deleted a hand-placed volume file"
}

# G1: while another flk holds the lock (a deploy mid-roll), read commands
# return at once instead of waiting to tidy an exited machine; the tidy-up
# happens on the next look.
test_reads_dont_block_on_the_lock() {
  local mdir="$FLK_HOME/apps/$APP/machines/fakedead" marker="$WORK/locked.$$"
  mkdir -p "$mdir"
  printf '{"id":"fakedead","name":"fakedead","tap_index":98,"ip":"172.30.0.108","created_at":"2000-01-01T00:00:00Z","config":{"mounts":[],"ports":[{"proto":"tcp","port":45999,"internal_port":80}]}}' >"$mdir/machine.json"
  echo 1 >"$mdir/pid" # pid 1 isn't firecracker: the machine "exited on its own"
  ruby -e 'File.open(ARGV[0], File::RDWR | File::CREAT) { |f| f.flock(File::LOCK_EX); File.write(ARGV[1], "x"); sleep 20 }' \
    "$FLK_HOME/.lock" "$marker" &
  local holder=$!
  wait_until 5 test -e "$marker" || { kill "$holder"; fail "lock holder never started"; }
  local t0=$SECONDS rc=0
  timeout 8 "$FLK_BIN" apps list --json >/dev/null || rc=$?
  timeout 8 "$FLK_BIN" -a "$APP" status --json >/dev/null || rc=$?
  local took=$((SECONDS - t0))
  [[ -e $mdir/pid ]] || { kill "$holder"; fail "reaped without the lock"; }
  kill "$holder"; wait "$holder" 2>/dev/null || true
  ((rc == 0 && took < 4)) || fail "read commands waited on the lock (${took}s, rc=$rc)"
  "$FLK_BIN" -a "$APP" status >/dev/null
  [[ ! -e $mdir/pid ]] || fail "not reaped once the lock was free"
  rm -rf "$mdir"
}

# G2: flk remembers where an app's config lives, so -a APP works from any
# directory for commands that need it (deploy, config show, scale).
test_config_path_recorded_and_used() {
  assert_eq "$APP_DIR/flk.toml" "$(flk status --json | json_get app.config_path)" "status --json config_path"
  local elsewhere; elsewhere=$(mktemp -d "$WORK/elsewhere.XXXX")
  local out
  out=$(cd "$elsewhere" && "$FLK_BIN" -a "$APP" config show) || fail "config show -a from another dir: $out"
  assert_eq "$APP" "$(json_get parsed.app <<<"$out")" "config from the recorded path"
  assert_contains "$(cd "$elsewhere" && "$FLK_BIN" -a "$APP" context)" "config:" "context -a from elsewhere"
  # a moved app dir: a clear error that says what to do
  mv "$APP_DIR/flk.toml" "$APP_DIR/flk.toml.moved"
  out=$(cd "$elsewhere" && "$FLK_BIN" -a "$APP" config show 2>&1) && { mv "$APP_DIR/flk.toml.moved" "$APP_DIR/flk.toml"; fail "used a config that's gone"; }
  mv "$APP_DIR/flk.toml.moved" "$APP_DIR/flk.toml"
  assert_contains "$out" "which is gone; run flk deploy in its new directory"
}

# G6: the JSON documents lazyflk and agents parse carry a schema number.
test_json_schema_version() {
  assert_eq 1 "$(flk context --json | json_get schema)" "context"
  assert_eq 1 "$(flk context --all --json | json_get schema)" "context --all"
  assert_eq 1 "$(flk doctor --json | json_get schema)" "doctor"
  assert_eq 1 "$(flk help --all --json | json_get schema)" "help --all"
  assert_contains "$(flk help --all)" '"schema": 1' "the rule is documented"
}

# G5: --no-host is the same app data, without running the host checks
# (no sudo, no systemctl).
test_context_no_host_is_cheap() {
  local bin="$WORK/fakebin-$RUN_ID" b
  mkdir -p "$bin"
  for b in sudo systemctl podman docker; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\nexit 1\n' "$b" "$bin" >"$bin/$b"; chmod +x "$bin/$b"
  done
  local fast full
  fast=$(PATH="$bin:$PATH" flk context --all --json --no-host)
  [[ ! -s $bin/calls ]] || fail "--no-host ran: $(cat "$bin/calls")"
  assert_eq '["address","lan_ip"]' "$(json_get host <<<"$fast" | ruby -rjson -e 'print JSON.generate(JSON.parse($stdin.read).keys.sort)')" \
    "host is just lan_ip and address"
  full=$(flk context --all --json)
  assert_eq "$(json_get apps <<<"$full")" "$(json_get apps <<<"$fast")" "same apps"
  assert_contains "$(PATH="$bin:$PATH" flk context --no-host)" "$APP" "one app, text"
}

# G9: doctor --json reports flk's systemd units, installed or not.
test_doctor_json_services() {
  local d; d=$(flk doctor --json)
  assert_eq flk-net.service "$(json_get services.0.unit <<<"$d")" "first unit"
  assert_eq flk-machines.service "$(json_get services.1.unit <<<"$d")" "second unit"
  [[ $(json_get services.0.installed <<<"$d") =~ ^(true|false)$ ]] || fail "installed isn't a boolean"
}

# G4, G8, G10: the read-only host views parse and have their keys.
test_stats_disk_images_json() {
  flk machine stats --all --json | ruby -rjson -e 'a = JSON.parse($stdin.read); abort "not an array" unless a.is_a?(Array)
    a.each { |s| %w[app id state cpu_percent rss_mb memory_mb uptime_s pid].each { |k| abort "no #{k}" unless s.key?(k) } }' ||
    fail "machine stats --all --json"
  local out; out=$(flk machine stats --all 1 2>&1) && fail "--all took an ID"
  flk disk --json | ruby -rjson -e 'd = JSON.parse($stdin.read)
    abort "no state_dir bytes" unless d["state_dir"]["bytes"].is_a?(Integer)
    %w[images rootfs volumes logs external_volumes].each { |k| abort "no totals.#{k}" unless d["totals"][k]["apparent"] }
    abort "no app #{ARGV[0]}" unless d["apps"].any? { _1["app"] == ARGV[0] }' "$APP" || fail "disk --json"
  flk images --json | ruby -rjson -e 'abort "not an array" unless JSON.parse($stdin.read).is_a?(Array)' || fail "images --json"
}

# G13: a build that fails says, last, that no machine changed, and logs it.
test_failed_build_says_machines_unchanged() {
  stage_app hello build
  trap destroy_app EXIT
  printf 'FROM scratch\nRUN false\n' >"$APP_DIR/Dockerfile" # no shell: fails at once, no pull
  flk launch --no-deploy >/dev/null
  local out
  out=$(flk deploy 2>&1) && fail "a broken Dockerfile deployed"
  assert_contains "$(tail -n 2 <<<"$out" | head -n 1)" "Error: build failed; machines unchanged (no machines yet)" "error is the last thing said"
  assert_contains "$(tail -n 1 <<<"$out")" "Next: flk deploy (after fixing the build)" "then the next step"
  assert_contains "$out" "command failed:" "the cause is still shown"
  local ev; ev=$(flk events --json | grep -F '"deploy.failed"' | tail -n 1)
  assert_contains "$(json_get detail <<<"$ev")" "build failed; machines unchanged (no machines yet): " "deploy.failed event"
  [[ $(json_get detail <<<"$ev") == *": "*" build failed" ]] || fail "detail isn't short: $ev"
  assert_eq "[]" "$(flk releases --json | tr -d ' \n')" "no release from the failed build"
}

test_build_hint_for_taken_ids() {
  local h; h=$(ruby -I"$FLK_SRC/lib" -rflk -e 'puts Flk::Image.build_hint(ARGV[0])' "groupadd: GID '1000' already exists")
  assert_contains "$h" "ubuntu:23.04 and later ship user \`ubuntu\` as 1000:1000"
  assert_eq "" "$(ruby -I"$FLK_SRC/lib" -rflk -e 'print Flk::Image.build_hint("all good")')" "no hint otherwise"
}

# G14: volumes create --owner sets the root's owner; without it the root
# waits for the image's mount point (owner_from_image).
test_volume_create_owner() {
  local d; d=$(mktemp -d "$WORK/owner.XXXX")
  flk volumes create owned --size 1 --path "$d/owned.ext4" --owner 1234:2345 >/dev/null
  assert_contains "$(debugfs -R "stat /" "$d/owned.ext4" 2>/dev/null)" "User:  1234   Group:  2345" "root owner"
  local v; v=$(flk volumes list --json | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read).find { _1["name"] == "owned" })')
  assert_eq null "$(json_get owner_from_image <<<"$v")" "--owner: nothing left to do"
  flk volumes destroy owned --delete-data >/dev/null
  flk volumes create plain --size 1 --path "$d/plain.ext4" --owner 77 >/dev/null
  assert_contains "$(debugfs -R "stat /" "$d/plain.ext4" 2>/dev/null)" "User:    77   Group:    77" "GID defaults to UID"
  flk volumes destroy plain --delete-data >/dev/null
  flk volumes create fresh --size 1 --path "$d/fresh.ext4" >/dev/null
  v=$(flk volumes list --json | ruby -rjson -e 'puts JSON.generate(JSON.parse($stdin.read).find { _1["name"] == "fresh" })')
  assert_eq true "$(json_get owner_from_image <<<"$v")" "no --owner: owner from the image later"
  flk volumes destroy fresh --delete-data >/dev/null
  assert_fails flk volumes create bad --owner developer
}

# App-level start/stop/restart, and machine verbs without an ID.
test_app_verbs_without_machines() {
  assert_contains "$(flk stop)" "Nothing of $APP is running"
  local out
  out=$(flk start 2>&1) && fail "start with no machines succeeded"
  assert_contains "$out" "$APP has no machines"
  assert_contains "$out" "Next: flk deploy"
  out=$(flk machine stop 2>&1) && fail "machine stop with no ID succeeded"
  assert_contains "$out" "$APP has no machines"
}

# flk doctor's "machines run under flk-machines.service" and the reboot
# check in reap rest on these two readers of /proc.
test_cgroup_unit_and_boot_time() {
  grep -q '^0::' /proc/self/cgroup || skip_test "no cgroup v2"
  local got; got=$(ruby -I"$FLK_SRC/lib" -rflk -e 'puts Flk::VM.cgroup_unit(Process.ppid)')
  assert_eq "$(sed -n 's|^0::.*/||p' /proc/$$/cgroup)" "$got" "cgroup unit of this shell"
  local bt; bt=$(ruby -I"$FLK_SRC/lib" -rflk -e 'puts Flk::Util.boot_time.to_i')
  assert_eq "$(awk '/^btime/ {print $2}' /proc/stat)" "$bt" "boot time"
}

# setup-host.sh --install-service's units, rendered into a scratch dir (no
# root, nothing enabled), must pass systemd-analyze verify, with flk-tmux
# ordered before flk-machines so stop-all runs before the server stops.
test_install_service_units_verify() {
  command -v systemd-analyze >/dev/null || skip_test "no systemd-analyze"
  local d; d=$(mktemp -d)
  awk '/^install_service\(\) \{/,/^}/' "$FLK_SRC/setup-host.sh" |
    sed -e "s|/etc/systemd/system|$d|g" -e '/systemctl /d' >"$d/fn.sh"
  (user=$USER bridge=flkbr0 subnet=172.30.0 taps=16 min_port=1024 src=$FLK_SRC self=$FLK_SRC/setup-host.sh
   sudo() { shift 3; "$@"; } # sudo -u USER -H CMD...
   source "$d/fn.sh"; install_service >/dev/null) || fail "install_service failed"
  local out; out=$(cd "$d" && systemd-analyze verify ./flk-tmux.service ./flk-machines.service 2>&1 |
    grep -v -e CPUAccounting -e 'flk-net.service' || true)
  [[ -z $out ]] || fail "systemd-analyze verify: $out"
  grep -q '^After=.*flk-tmux.service' "$d/flk-machines.service" || fail "flk-machines isn't ordered after flk-tmux"
  grep -qF ' start-server \; set-option -g exit-empty off' "$d/flk-tmux.service" ||
    fail "flk-tmux ExecStart: $(grep ExecStart "$d/flk-tmux.service")"
  grep -qF 'test -n "${MAINPID}" || exit 0' "$d/flk-tmux.service" ||
    fail "flk-tmux ExecStop isn't guarded: installing it next to a running server would stop every machine"
  rm -rf "$d"
}

# Why flk-tmux.service unsets XDG_RUNTIME_DIR: tmux puts each pane in a
# tmux-spawn scope of the user's systemd when its *server* can reach it,
# whatever the client's environment. Without those, panes (machines) stay
# in the server's unit. A transient user unit stands in for flk-tmux.
test_tmux_panes_stay_in_the_server_unit() {
  systemctl --user show-environment >/dev/null 2>&1 || skip_test "no systemd --user"
  local unit="flkt-tmux-$RUN_ID" sock="flkt-unit-$RUN_ID"
  systemd-run --user -q --unit "$unit" -p Type=forking \
    -p UnsetEnvironment=XDG_RUNTIME_DIR -p UnsetEnvironment=DBUS_SESSION_BUS_ADDRESS \
    "$(command -v tmux)" -L "$sock" start-server \; set-option -g exit-empty off || skip_test "systemd-run --user failed"
  wait_until 5 tmux -L "$sock" display-message -p '#{pid}' || fail "the unit's tmux server never came up"
  tmux -L "$sock" new-session -d -s probe "exec sleep 60"
  local pane; pane=$(tmux -L "$sock" display-message -p -t probe '#{pane_pid}')
  local got; got=$(ruby -I"$FLK_SRC/lib" -rflk -e "puts Flk::VM.cgroup_unit($pane)")
  tmux -L "$sock" kill-server
  systemctl --user stop "$unit" 2>/dev/null || true
  systemctl --user reset-failed "$unit" 2>/dev/null || true
  assert_eq "$unit.service" "$got" "the pane's unit"
}
