#!/bin/sh
# Recapture fixtures/ from this host: every command here only reads. Run
# it on a quiet host (no flkt-* test apps, nothing in next_steps), then
# review the diff and the goldens (go test ./internal/ui -update).
# backups-sample.json isn't recaptured: it came from a test app.
set -eu
cd "$(dirname "$0")"
APP=minecraft-flk
F() { NO_COLOR=1 flk "$@"; }

F context --all --json > context-all.json
F context --all > context-all.txt
F context --all --json --no-host > context-all-nohost.json
(cd ~ && NO_COLOR=1 flk context) > context.txt
F -a $APP context --json > context-$APP.json
F help --all --json > help-all.json
for t in cheatsheet install first-app operate troubleshoot uninstall; do F help $t > help-$t.txt; done
F doctor --json > doctor.json
F apps list --json > apps-list.json
F ports list --json > ports-list.json
F -a $APP status --json > status-$APP.json
F -a $APP releases --json > releases-$APP.json
F -a $APP volumes list --json > volumes-$APP.json
F -a $APP secrets list --json > secrets-$APP.json
ID=$(python3 -c "import json; print(json.load(open('context-$APP.json'))['app']['machines'][0]['id'])")
F -a $APP machine status "$ID" > machine-status.json
F -a $APP logs -n 40 --no-tail > logs-$APP.txt
F -a $APP config show > config-$APP.json
F -a $APP volumes backups --json > backups-$APP.json
F machine stats --all --json > machine-stats.json
F disk --json > disk.json
F images --json > images.json

# df over flk's mount_dirs (they start with the state dir)
df -k --output=target,size,used,avail,pcent $(python3 -c "import json; print(' '.join(json.load(open('context-all.json'))['mount_dirs']))") > df.txt

# host tools, for the providers
podman ps -a --external --format json > podman-ps.json
podman images --format json > podman-images.json
lsblk -e7 -b --json -o NAME,PATH,TYPE,SIZE,FSTYPE,FSSIZE,FSAVAIL,MOUNTPOINTS,MODEL > lsblk.json
systemctl show --timestamp=utc \
  -p Id,Description,LoadState,ActiveState,SubState,UnitFileState,ActiveEnterTimestamp,StateChangeTimestamp,MainPID,Result,NRestarts \
  flk-net.service flk-machines.service ssh.service snap.mosquitto.mosquitto.service chrony.service > systemctl-show.txt
id -Gn > id-groups.txt
buildah --version > buildah-version.txt
journalctl -u chrony.service -n 40 --no-pager -o short-iso > journal-chrony.txt

echo "captured at flk $(git -C "$(dirname "$(readlink -f "$(command -v flk)")")/.." log -1 --format=%h 2>/dev/null || echo '?'); update fixtures/README.md"
