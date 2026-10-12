# harness.sh: helpers for tests/cases/*.sh (sourced by tests/run.sh).
#
# A case file sets TIER (fast = no VMs, vm = boots microVMs), optionally
# defines setup_file/teardown_file, and any number of test_* functions,
# which run in file order. Each test runs in its own subshell with
# `set -euo pipefail`, so any failing command fails the test.
# APP and APP_DIR set in setup_file reach the tests; list any other
# variables setup_file sets in SETUP_VARS="A B".
#
# Test apps are staged from tests/apps/ under a unique name (flkt-*) in the
# user's real FLK_HOME: the tap pool is shared with real machines, so tests
# must see them. `tests/run.sh --clean` removes leftover flkt-* apps.

FLK_HOME=${FLK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/flk}
APP="" APP_DIR=""

# ---------- outcomes ----------
fail()      { echo "FAIL: $*" >&2; exit 1; }
pending()   { echo "PENDING: $*"; exit 99; }  # feature not built yet
skip_test() { echo "SKIP: $*"; exit 98; }     # can't run here (e.g. offline)

# ---------- assertions ----------
assert_eq() { # EXPECTED ACTUAL [LABEL]
  [[ $1 == "$2" ]] || fail "${3:-value}: expected '$1', got '$2'"
}
assert_ne() { [[ $1 != "$2" ]] || fail "${3:-value}: expected something other than '$1'"; }
assert_contains() { # HAYSTACK NEEDLE [LABEL]
  [[ $1 == *"$2"* ]] || fail "${3:-output} doesn't contain '$2'"$'\n'"--- got:"$'\n'"$1"
}
assert_ok()   { "$@" || fail "command failed: $*"; }
assert_fails() { if "$@"; then fail "expected failure: $*"; fi; }

# wait_until SECONDS CMD...: poll every 0.5s until CMD succeeds
wait_until() {
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

# ---------- flk wrappers ----------
flk() { (cd "${APP_DIR:-$PWD}" && "$FLK_BIN" "$@"); }

# stage_app SRC: copy tests/apps/SRC to a scratch dir as app
# flkt-SRC-NN-<run id>, NN from the case file, so files never share an app.
# Host ports ([[services.ports]] port = ...) become $HOST_PORT (see run.sh).
stage_app() {
  APP="flkt-$1-${CUR%%-*}-$RUN_ID"
  APP_DIR=$(mktemp -d "$WORK/$APP.XXXX")
  cp -r "$TESTS/apps/$1/." "$APP_DIR"
  sed -i -e "s/^app = .*/app = \"$APP\"/" -e "s/^\(\s*\)port = [0-9]*$/\1port = $HOST_PORT/" "$APP_DIR/flk.toml"
}

destroy_app() { [[ -z $APP ]] || "$FLK_BIN" apps destroy "$APP" --yes >/dev/null 2>&1 || true; }

# toml_set KEY_LINE_REGEX NEW_LINE: edit the staged flk.toml in place
toml_set()    { sed -i "s|^\(\s*\)$1.*|\1$2|" "$APP_DIR/flk.toml"; }
toml_append() { printf '%s\n' "$@" >>"$APP_DIR/flk.toml"; }

# json_get PATH < json: dotted path, numeric segments index arrays
json_get() {
  ruby -rjson -e 'v = JSON.parse($stdin.read)
    ARGV[0].split(".").each { |k| v = k.match?(/\A\d+\z/) ? v[k.to_i] : v[k] }
    puts v.is_a?(String) ? v : JSON.generate(v)' "$1"
}

# machine records for $APP, ordered by tap index: machines FIELD
machines() {
  ruby -rjson -e 'Dir[File.join(ARGV[0], "apps", ARGV[1], "machines", "*", "machine.json")]
    .map { JSON.parse(File.read(_1)) }.sort_by { _1["tap_index"] }
    .each { puts _1[ARGV[2]] }' "$FLK_HOME" "$APP" "$1"
}
machine_id() { machines id | sed -n "${1:-1}p"; }
machine_ip() { machines ip | sed -n "${1:-1}p"; }
machine_count() { machines id | grep -c . || true; }
machine_state() { flk machine status "${1:-$(machine_id)}" | json_get state; }
is_stopped() { [[ $(machine_state "$@") == stopped ]]; }

console_log() { cat "$FLK_HOME/apps/$APP/machines/${1:-$(machine_id)}/console.log" 2>/dev/null; }
log_has() { console_log "${2:-}" | grep -qF -- "$1"; }
log_count() { console_log "${2:-}" | grep -cF -- "$1" || true; }
log_count_gt() { (($(log_count "$2" "${3:-}") > $1)); } # N NEEDLE [ID]
wait_log() { wait_until "${2:-30}" log_has "$1" "${3:-}" || fail "console log never showed '$1'"; }

# ---------- minecraft ----------
mcping() { ruby "$TESTS/lib/mcping.rb" "$@"; }
mc_up()  { mcping "${1:-$(machine_ip)}" "${2:-25565}" -t 2 >/dev/null 2>&1; }
wait_mc() { wait_until "${1:-60}" mc_up "${2:-}" || fail "mcshadow never answered a status ping"; }
mcq()    { mcping "${2:-$(machine_ip)}" 25565 -q "$1"; } # mcq flk.boots [IP]

# ---------- environment probes ----------
host_online() { timeout 3 bash -c '</dev/tcp/1.1.1.1/53' 2>/dev/null; }
port_helper_ready() { sudo -n -l /usr/local/libexec/flk-ports >/dev/null 2>&1; }
port_map() { sudo -n /usr/local/libexec/flk-ports list; } # the live nft map
host_lan_ip() { ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

# Called by the runner after a failed vm test: append context to its log.
dump_context() {
  [[ -n $APP ]] || return 0
  echo "--- flk status"; flk status 2>&1 || true
  echo "--- console.log (tail)"; console_log | tail -n 30
}
