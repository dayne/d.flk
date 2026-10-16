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
        # cap_setuid=ep in a PAX header, as podman export writes setcap
        rec = "SCHILY.xattr.security.capability=" + ["0100000280000000000000000000000000000000"].pack("H*") + "\n"
        len = rec.bytesize + 3; len += 1 while "#{len} #{rec}".bytesize != len
        pax = "#{len} #{rec}"
        f.write Gem::Package::TarHeader.new(name: "PaxHeader/capped", size: pax.bytesize, mode: 0o644,
                                            typeflag: "x", prefix: "").to_s
        f.write pax.ljust((pax.bytesize + 511) / 512 * 512, "\0")
        t.add_file_simple("capped", 0o755, 5) { _1.write "caps\n" }
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

test_file_capabilities_kept() {
  # setcap (and Arch/Fedora's newuidmap) live in an xattr tar can't restore
  # without root; flk writes them into the image with debugfs.
  local d="$WORK/rootfs-caps-$RUN_ID"
  fake_image "$d"
  out=$("$FLK_SRC/libexec/flk-build-rootfs" "$d/engine" img "$d/overlay" "$d/out.ext4" 8)
  assert_contains "$out" "file capabilities kept on 1 file"
  assert_contains "$(debugfs -R 'ea_get -x /capped security.capability' "$d/out.ext4" 2>/dev/null)" \
    "01 00 00 02 80 00 00 00" "cap_setuid=ep on /capped"
}
