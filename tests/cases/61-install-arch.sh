# Install test: run through the flk install steps inside a fresh Arch Linux VM.
# Verifies package detection, flk-sanity.sh output, flk setup, and --fix.
#
# TIER=vm because it boots a full microVM (Arch Linux, ~1GB RAM).
# Expect a minute or two after the image build: pacman -Sy + install + firecracker/kernel download.
# Run alone: tests/run.sh 61
TIER=vm

setup_file() {
  stage_app install-arch
  flk launch --no-deploy

  local tmp; tmp=$(mktemp -d "$WORK/src-snap.XXXX")
  rsync -a --exclude='.git' --exclude='*.ext4' "$FLK_SRC/" "$tmp/"
  flk volumes create src --size 2 --from-dir "$tmp"
  rm -rf "$tmp"

  flk deploy
}

teardown_file() { destroy_app; }

test_install_steps_pass() {
  # Allow up to 10 minutes: pacman sync + package install + firecracker download
  wait_log "INSTALL TEST PASSED" 600 || {
    echo "--- last 40 lines of console log:"
    console_log | tail -40
    fail "install test did not pass within timeout"
  }
}

test_vm_exits_cleanly() {
  wait_until 30 is_stopped || fail "VM still running after install test"
  log_has "app exited with status 0" || fail "install script exited non-zero (check console log)"
}
