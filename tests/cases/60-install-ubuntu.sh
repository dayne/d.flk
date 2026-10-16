# Install test: run through the flk install steps inside a fresh Ubuntu 24.04 VM.
# Verifies package detection, flk-sanity.sh output, flk setup, and --fix.
#
# TIER=vm because it boots a full microVM (Ubuntu 24.04, ~1GB RAM).
# Expect ~5 minutes: apt-get update + install + firecracker/kernel download.
# Run alone: FLK_CASES=60 tests/run.sh
TIER=vm

setup_file() {
  stage_app install-ubuntu
  flk launch --no-deploy

  # Pack the current flk source tree into a volume. Every run gets a fresh
  # copy so changes to sanity.sh / setup.rb / --fix are immediately tested.
  # Skip .git and *.ext4 to keep the volume small and fast to create.
  local tmp; tmp=$(mktemp -d "$WORK/src-snap.XXXX")
  rsync -a --exclude='.git' --exclude='*.ext4' "$FLK_SRC/" "$tmp/"
  flk volumes create src --size 2 --from-dir "$tmp"
  rm -rf "$tmp"

  flk deploy
}

teardown_file() { destroy_app; }

test_install_steps_pass() {
  # Allow up to 8 minutes: apt-get update, package install, firecracker download
  wait_log "INSTALL TEST PASSED" 480 || {
    echo "--- last 40 lines of console log:"
    console_log | tail -40
    fail "install test did not pass within timeout"
  }
}

test_vm_exits_cleanly() {
  wait_until 30 is_stopped || fail "VM still running after install test"
  log_has "app exited with status 0" || fail "install script exited non-zero (check console log)"
}
