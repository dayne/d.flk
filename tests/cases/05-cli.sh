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
        h = (s || c)[:run] || (s ? "#{c[:name]}_#{s[:name]}" : "cmd_#{c[:name]}")
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
  out=$(flk releases extra 2>&1) && fail "accepted an extra argument"
  assert_contains "$out" "unexpected argument 'extra'"
  out=$(flk machine stop 2>&1) && fail "accepted machine stop without an ID"
  assert_contains "$out" "missing arguments"
}

# OptionParser hands a literal --no-x switch false; flk must treat it as given
test_no_flags_are_true() {
  local out; out=$(flk launch --no-deploy 2>&1)
  assert_contains "$out" "Run 'flk deploy' when ready"
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
  stage_app hello
  trap destroy_app EXIT
  toml_append '[[mounts]]' '  source = "data"' '  destination = "/data"'
  flk launch --no-deploy >/dev/null
  local out
  out=$(flk deploy 2>&1) && fail "deployed without the volume [[mounts]] needs"
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

  stage_app hello
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
