#!/usr/bin/env bash
# tests/run.sh: end-to-end checks that flk still works after you hack on it.
#
#   tests/run.sh                  all tiers (vm tier only if the host is ready)
#   tests/run.sh --fast           config/parsing tests only; no VMs, no root
#   tests/run.sh hello mcshadow   only case files / tests matching these words
#   tests/run.sh --keep           leave test apps behind for poking at
#   tests/run.sh --clean          destroy leftover flkt-* apps and exit
#   tests/run.sh --list           list tests without running them
#
# Before the vm tier it runs ../flk-sanity.sh; fix whatever that reports
# first (or pass --force to try anyway). Per-test logs go to $FLK_TEST_OUT
# (default: a fresh dir under /tmp), and failures print the tail inline.
#
# Writing tests: see tests/lib/harness.sh. Results are PASS, FAIL,
# PEND (feature not built yet: `pending "why"`) and SKIP (`skip_test "why"`).
# Exit: 0 if nothing failed, 1 otherwise.
set -uo pipefail

TESTS=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
FLK_SRC=$(dirname "$TESTS")
FLK_BIN="$FLK_SRC/bin/flk"
RUN_ID=$(printf '%04x' $((RANDOM % 65536)))

# Host port for test apps' [[services.ports]], instead of their real one
# (25565), so a real server on this host can't answer in a test's place.
free_port() {
  local p
  while :; do
    p=$((30000 + RANDOM % 20000))
    ss -Htuln "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return; }
  done
}
HOST_PORT=$(free_port)
export TESTS FLK_SRC FLK_BIN RUN_ID HOST_PORT

TIER=all FORCE=0 KEEP=0 LIST=0 FILTERS=() CUR=""
COLOR=1; [[ -t 1 && -z ${NO_COLOR:-} ]] || COLOR=0
c() { ((COLOR)) && printf '\e[%sm%s\e[0m' "$1" "$2" || printf '%s' "$2"; }

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

clean() {
  local home=${FLK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/flk} d
  for d in "$home"/apps/flkt-*; do
    [[ -d $d ]] || continue
    "$FLK_BIN" apps destroy "$(basename "$d")" --yes
  done
}

parse_args() {
  while (($#)); do
    case $1 in
      --fast)  TIER=fast ;;
      --vm)    TIER=vm ;;
      --force) FORCE=1 ;;
      --keep)  KEEP=1 ;;
      --list)  LIST=1 ;;
      --clean) clean; exit 0 ;;
      -h|--help) usage ;;
      -*) echo "unknown option: $1" >&2; usage 1 ;;
      *)  FILTERS+=("$1") ;;
    esac
    shift
  done
}

# test function names in the order they're written
tests_in() { grep -oE '^test_[A-Za-z0-9_]+' "$1"; }
file_tier() { sed -n 's/^TIER=\([a-z]*\).*/\1/p' "$1" | head -1; }

matches() { # FILE TEST
  ((${#FILTERS[@]})) || return 0
  local f
  for f in "${FILTERS[@]}"; do [[ $1 == *"$f"* || $2 == *"$f"* ]] && return 0; done
  return 1
}

record() { # RESULT LABEL LOGFILE SECONDS
  local res=$1 label=$2 log=$3 secs=$4 icon
  case $res in
    PASS) icon=$(c 32 ✔) ;;
    FAIL) icon=$(c 31 ✘) ;;
    PEND) icon=$(c 33 …) ;;
    SKIP) icon=$(c 90 -) ;;
  esac
  echo "$res $CUR/$label" >>"$OUT/results"   # file, so subshells can report
  local why=""
  [[ $res == PEND || $res == SKIP ]] && why=$(grep -m1 -oE '(PENDING|SKIP): .*' "$log" | cut -d' ' -f2-)
  printf '  %s %s %s%s\n' "$icon" "$label" "$(c 90 "(${secs}s)")" "${why:+  $(c 90 "$why")}"
  if [[ $res == FAIL ]]; then
    tail -n 25 "$log" | sed 's/^/      /'
    echo "      $(c 90 "full log: $log")"
  fi
}

# Runs in a subshell per file, so setup_file state is shared by its tests
# but never leaks into the next file.
run_file() {
  local file=$1 name tier t log rc start
  name=$(basename "$file" .sh)
  tier=$(file_tier "$file")
  CUR=$name
  local todo=()
  for t in $(tests_in "$file"); do matches "$name" "$t" && todo+=("$t"); done
  ((${#todo[@]})) || return 0

  echo; echo "$(c 1 "$name") $(c 90 "[$tier]")"
  if ((LIST)); then printf '    %s\n' "${todo[@]}"; return 0; fi
  if [[ $tier == vm && $VM_OK != 1 ]]; then
    for t in "${todo[@]}"; do echo "SKIP: host not ready for VMs (see flk-sanity.sh)" >"$OUT/$name.$t.log"; record SKIP "$t" "$OUT/$name.$t.log" 0; done
    return 0
  fi

  (
    # shellcheck source=lib/harness.sh
    . "$TESTS/lib/harness.sh"
    . "$file"
    trap '((KEEP)) || { declare -F teardown_file >/dev/null && teardown_file >>"$OUT/$name.teardown.log" 2>&1; }' EXIT

    if declare -F setup_file >/dev/null; then
      log="$OUT/$name.setup.log"; start=$SECONDS
      # setup runs in a subshell (for set -e); hand its variables back
      # (even when it fails partway, so teardown knows what to clean up)
      (set -euo pipefail
       trap 'declare -p APP APP_DIR ${SETUP_VARS:-} >"$OUT/$name.state" 2>/dev/null' EXIT
       setup_file) >"$log" 2>&1; rc=$?
      [[ -f $OUT/$name.state ]] && . "$OUT/$name.state"
      if ((rc != 0)); then
        record FAIL "setup_file" "$log" $((SECONDS - start))
        dump_context >>"$log" 2>&1
        for t in "${todo[@]}"; do echo "SKIP: setup_file failed" >"$OUT/$name.$t.log"; record SKIP "$t" "$OUT/$name.$t.log" 0; done
        exit 0
      fi
    fi

    for t in "${todo[@]}"; do
      log="$OUT/$name.$t.log"; start=$SECONDS
      (set -euo pipefail; "$t") >"$log" 2>&1; rc=$?
      case $rc in
        0)  record PASS "$t" "$log" $((SECONDS - start)) ;;
        99) record PEND "$t" "$log" $((SECONDS - start)) ;;
        98) record SKIP "$t" "$log" $((SECONDS - start)) ;;
        *)  [[ $tier == vm ]] && dump_context >>"$log" 2>&1
            record FAIL "$t" "$log" $((SECONDS - start)) ;;
      esac
    done
  )
  return 0
}

preflight() {
  VM_OK=0
  ((LIST)) && return 0
  if ! "$FLK_BIN" version >/dev/null 2>&1; then
    echo "$(c 31 "bin/flk doesn't run"); fix that first: $FLK_SRC/flk-sanity.sh"; exit 1
  fi
  [[ $TIER == fast ]] && return 0
  echo "$(c 1 "host readiness") $(c 90 "(flk-sanity.sh -q)")"
  local out rc
  out=$("$FLK_SRC/flk-sanity.sh" -q --no-color 2>&1); rc=$?
  sed 's/^/  /' <<<"$out"
  # exit 2 is warnings only: good enough to boot VMs
  if ((rc == 0 || rc == 2)); then VM_OK=1
  elif ((FORCE)); then VM_OK=1; echo "  $(c 33 "--force: running vm tests anyway")"
  else echo "  $(c 33 "vm tests will be skipped; fix the above or pass --force")"
  fi
}

main() {
  parse_args "$@"
  OUT=${FLK_TEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/flk-tests.XXXXXX")}
  WORK="$OUT/apps"; mkdir -p "$WORK"
  export OUT WORK KEEP
  preflight

  local file tier
  for file in "$TESTS"/cases/*.sh; do
    tier=$(file_tier "$file")
    [[ $TIER == all || $TIER == "$tier" ]] || continue
    run_file "$file"
  done
  ((LIST)) && exit 0

  touch "$OUT/results"
  local n_fail; n_fail=$(grep -c '^FAIL ' "$OUT/results")
  echo
  printf '%s passed, %s failed, %s pending, %s skipped   %s\n' \
    "$(c 32 "$(grep -c '^PASS ' "$OUT/results")")" "$(c 31 "$n_fail")" \
    "$(c 33 "$(grep -c '^PEND ' "$OUT/results")")" "$(grep -c '^SKIP ' "$OUT/results")" "$(c 90 "logs: $OUT")"
  ((n_fail)) && sed -n 's/^FAIL /  failed: /p' "$OUT/results"
  ((KEEP)) && echo "kept test apps (flkt-*-$RUN_ID); remove with: $0 --clean"
  ((n_fail)) && exit 1
  exit 0
}

main "$@"
