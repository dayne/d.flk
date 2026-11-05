# Rootfs builds (libexec/flk-build-rootfs) with a stand-in engine: no
# podman, no VMs.
TIER=fast

# An engine whose `export` prints a tar we made, and an overlay with an
# agent so an image without /bin/sh still builds.
fake_image() { # DIR: writes DIR/root.tar, DIR/engine, DIR/overlay
  mkdir -p "$1/overlay/flk"
  cp /bin/true "$1/overlay/flk/agent"
  # image inspect: the size in FAKE_SIZE, or no answer (the space check is skipped)
  printf '#!/bin/sh\ncase $1 in create) echo cid ;; export) touch %q/exported; cat %q/root.tar ;;
    image) [ -n "$FAKE_SIZE" ] && echo "$FAKE_SIZE" || exit 1 ;; esac\n' "$1" "$1" >"$1/engine"
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

test_build_stays_out_of_tmpdir() {
  # /tmp can be a small tmpfs in RAM (enshrouded.flk BUGS #1): the build
  # works next to its output, and leaves nothing behind there either.
  local d="$WORK/rootfs-tmp-$RUN_ID"
  fake_image "$d"
  mkdir -p "$d/ro-tmp" "$d/images" && chmod 555 "$d/ro-tmp"
  TMPDIR=$d/ro-tmp assert_ok "$FLK_SRC/libexec/flk-build-rootfs" "$d/engine" img "$d/overlay" "$d/images/v1.ext4" 8 >/dev/null
  assert_eq "" "$(ls -A "$d/ro-tmp")" "nothing in TMPDIR"
  assert_eq "v1.ext4" "$(ls -A "$d/images")" "only the image next to it"
  chmod 755 "$d/ro-tmp"
}

test_build_checks_free_space_first() {
  local d="$WORK/rootfs-space-$RUN_ID"
  fake_image "$d"
  local out
  out=$(FAKE_SIZE=$((1 << 62)) "$FLK_SRC/libexec/flk-build-rootfs" "$d/engine" img "$d/overlay" "$d/out.ext4" 8 2>&1) &&
    fail "built with no room: $out"
  assert_contains "$out" "not enough space to build the rootfs in $d"
  [[ ! -e $d/exported ]] || fail "exported the image before checking the space"
  FAKE_SIZE=4096 assert_ok "$FLK_SRC/libexec/flk-build-rootfs" "$d/engine" img "$d/overlay" "$d/out.ext4" 8 >/dev/null
}

test_build_removes_dead_builds_leftovers() {
  # A killed build leaves its work dir: the next build removes it, but not
  # the dir of a build that's still running (another app's, say).
  local d="$WORK/rootfs-left-$RUN_ID"
  fake_image "$d"
  mkdir -p "$d/images/.flk-rootfs.99999999.dead" "$d/images/.flk-rootfs.$$.live"
  assert_ok "$FLK_SRC/libexec/flk-build-rootfs" "$d/engine" img "$d/overlay" "$d/images/v2.ext4" 8 >/dev/null
  [[ ! -e $d/images/.flk-rootfs.99999999.dead ]] || fail "a dead build's work dir is still there"
  [[ -d $d/images/.flk-rootfs.$$.live ]] || fail "removed a running build's work dir"
}
