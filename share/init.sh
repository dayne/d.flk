#!/bin/sh
# /flk/init: PID 1 inside every flk microVM (role of Fly's init).
# Only needs /bin/sh; uses `ip`/`setpriv` when the image happens to have them.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
log() { echo "[flk-init] $*"; }

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /dev/shm 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
# devtmpfs has device nodes only; udev or a container runtime would add
# these. Without /dev/fd, bash process substitution (<(...), >(...)) fails,
# and configs that log to /dev/stdout or /dev/stderr break.
ln -sfn /proc/self/fd /dev/fd
ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr
ln -sf /proc/kcore /dev/core

# The kernel's default Ctrl-Alt-Del action is an immediate hard reboot; real
# init systems turn it off at boot. flk stops VMs with Ctrl-Alt-Del, so turn
# it into SIGINT to us (trapped below) and the app gets a clean SIGTERM.
echo 0 > /proc/sys/kernel/ctrl-alt-del
# Write cached file data to disk within about a second (kernel default:
# 30s), and volumes commit their journal every second (ext4 default: 5s),
# so a host-side copy a few seconds after the app flushes (flk volumes
# backup, mode "live") holds that flush, and a crash loses less.
echo 100 > /proc/sys/vm/dirty_expire_centisecs
echo 100 > /proc/sys/vm/dirty_writeback_centisecs

mkdir -p /flk/config
mount -t ext4 -o ro /dev/vdb /flk/config 2>/dev/null || log "WARNING: config drive missing"

[ -f /flk/image.env ] && . /flk/image.env
[ -f /flk/config/env ] && . /flk/config/env

echo "$FLK_HOSTNAME" > /proc/sys/kernel/hostname

# Networking: the kernel `ip=` boot arg normally configures eth0 (and lo).
# Fall back to iproute2/busybox `ip` if this kernel lacks CONFIG_IP_PNP.
if ! grep -q "$FLK_IP" /proc/net/fib_trie 2>/dev/null; then
  if command -v ip >/dev/null 2>&1; then
    ip link set lo up
    ip link set eth0 up
    ip addr add "$FLK_IP/$FLK_PREFIX" dev eth0
    ip route add default via "$FLK_GATEWAY"
  else
    log "WARNING: eth0 not configured by kernel and no 'ip' binary in image"
  fi
fi

rm -f /etc/resolv.conf
for ns in $FLK_DNS; do echo "nameserver $ns"; done > /etc/resolv.conf
grep -q localhost /etc/hosts 2>/dev/null || echo "127.0.0.1 localhost" >> /etc/hosts
echo "$FLK_IP $FLK_HOSTNAME" >> /etc/hosts

if [ -f /flk/config/mounts ]; then
  while read -r dev path; do
    [ -n "$dev" ] || continue
    mkdir -p "$path"
    if mount -t ext4 -o commit=1 "$dev" "$path"; then log "mounted volume $dev at $path"
    else log "WARNING: failed to mount $dev at $path"; fi
  done < /flk/config/mounts
fi

# flk exec / flk ssh console: the agent listens on vsock (it's in releases
# built since flk had it; it reports to the console only if it fails)
[ -x /flk/agent ] && (cd / && exec /flk/agent </dev/null >/dev/console 2>&1) &

cd "$(cat /flk/workdir 2>/dev/null || echo /)" 2>/dev/null || cd /

start_app() {
  u=$(cat /flk/user 2>/dev/null)
  case "$u" in ""|root|0|0:0) exec /flk/cmd ;; esac
  usr=${u%%:*}; grp=""
  [ "$usr" != "$u" ] && grp=${u#*:}
  if command -v setpriv >/dev/null 2>&1; then
    [ -n "$grp" ] || grp=$(id -g "$usr" 2>/dev/null || echo "$usr")
    exec setpriv --reuid="$usr" --regid="$grp" --clear-groups /flk/cmd
  elif chroot --help 2>&1 | grep -q userspec; then
    exec chroot --userspec="$u" / /flk/cmd
  else
    log "WARNING: can't switch to user '$u' (no setpriv or chroot --userspec); running as root"
    exec /flk/cmd
  fi
}

child=0
status=0
on_stop() {
  log "shutdown requested, sending SIGTERM to app"
  [ "$child" -gt 0 ] && kill -TERM "$child" 2>/dev/null
}
trap on_stop TERM INT

log "starting app: $(tail -n1 /flk/cmd | sed 's/^exec //')"
# A background job's stdin is /dev/null unless redirected, so hand the app
# the serial console explicitly: `flk console` input reaches it (server
# consoles: stop, say, op...). [flk] stdin = "null" gives it /dev/null, as
# `docker run` without -i does. Not a controlling tty: Ctrl-C typed on the
# console doesn't signal the app.
if [ "${FLK_STDIN:-console}" = null ]; then
  start_app </dev/null &
else
  start_app </dev/console &
fi
child=$!
# `wait` returns early when a trapped signal arrives, so loop until the app is gone.
while kill -0 "$child" 2>/dev/null; do
  wait "$child"
  status=$?
done

log "app exited with status $status; powering off"

# Leave every filesystem clean, so a stop never looks like a crash (no
# journal to replay, and the host can inspect a stopped volume): stop
# whatever the app left behind, unmount volumes in reverse order, then make
# the rootfs read-only.
kill -TERM -1 2>/dev/null; sleep 1; kill -KILL -1 2>/dev/null
sync
if [ -f /flk/config/mounts ]; then
  sed -n '1!G;h;$p' /flk/config/mounts | while read -r dev path; do
    [ -n "$path" ] || continue
    umount "$path" 2>/dev/null || mount -o remount,ro "$path" 2>/dev/null ||
      log "WARNING: couldn't unmount or remount read-only $path; it will need journal recovery"
  done
fi
umount /flk/config 2>/dev/null
mount -o remount,ro / 2>/dev/null || { sync; echo u > /proc/sysrq-trigger; } # u: emergency remount read-only
sync
echo b > /proc/sysrq-trigger   # guest reboot makes firecracker exit (reboot=k)
sleep 5
