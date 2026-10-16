# Rootfs builds (libexec/flk-build-rootfs) with a stand-in engine: no
# podman, no VMs.
TIER=fast

# An engine whose `export` prints a tar we made, and an overlay with an
# agent so an image without /bin/sh still builds.
fake_image() { # DIR: writes DIR/root.tar, DIR/engine, DIR/overlay
  mkdir -p "$1/overlay/flk"
  cp /bin/true "$1/overlay/flk/agent"
  printf '#!/bin/sh\ncase $1 in create) echo cid ;; export) cat %q/root.tar ;; esac\n' "$1" >"$1/engine"
  chmod +x "$1/engine"
  ruby -rrubygems/package -e '
    File.open(ARGV[0], "wb") do |f|
      Gem::Package::TarWriter.new(f) do |t|
        t.mkdir "bin", 0o755
        t.add_file_simple("etc-shadow", 0o000, 7) { _1.write "secret\n" }
        t.mkdir "locked", 0o000
        t.add_file_simple("locked/suid", 0o4755, 6) { _1.write "inner\n" }
      end
    end' "$1/root.tar"
}

ext4_mode() { debugfs -R "stat $2" "$1" 2>/dev/null | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p' | head -1; }

test_unreadable_files_keep_their_mode() {
  # Fedora ships /etc/shadow and /etc/gshadow as mode 0000; the build used
  # to fail with "Permission denied while populating file system".
  local d="$WORK/rootfs-$RUN_ID"
  fake_image "$d"
  assert_ok "$FLK_SRC/libexec/flk-build-rootfs" "$d/engine" img "$d/overlay" "$d/out.ext4" 8 >/dev/null
  assert_eq 0000 "$(ext4_mode "$d/out.ext4" /etc-shadow)" "mode-0000 file"
  assert_eq 0000 "$(ext4_mode "$d/out.ext4" /locked)" "mode-0000 dir"
  assert_eq 04755 "$(ext4_mode "$d/out.ext4" /locked/suid)" "setuid file inside it"
  assert_eq secret "$(debugfs -R 'cat /etc-shadow' "$d/out.ext4" 2>/dev/null)" "content copied"
}
