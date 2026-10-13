# The root side of port forwarding (setup-host.sh's nft table and the
# flk-ports helper), run for real inside a private network namespace where
# we're root: no sudo, nothing on the host changes. Needs podman (its user
# namespace is allowed where plain `unshare -r` isn't, e.g. Ubuntu), nft
# and ip.
TIER=fast

netns_ok() {
  command -v podman >/dev/null && command -v nft >/dev/null &&
    podman unshare unshare -n true >/dev/null 2>&1
}

test_per_address_forwarding_in_a_netns() {
  netns_ok || skip_test "can't make a private network namespace here (podman unshare + unshare -n)"
  local work="$WORK/netns-$RUN_ID" out
  mkdir -p "$work"
  out=$(timeout 90 podman unshare unshare -n bash "$TESTS/lib/ports-netns.sh" "$FLK_SRC" "$work" 2>&1)
  echo "$out"
  [[ $out == *$'\ndone'* ]] || fail "the netns script didn't finish"
  [[ $out != *FAIL* ]] || fail "$(grep FAIL <<<"$out")"
}
