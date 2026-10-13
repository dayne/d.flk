# Fixtures

Real output from the reference host (flk 0.1.0, commit 3fd7177, 2026-10-13),
captured with the commands below by `./capture.sh` (read-only; run it on a
quiet host, then review the diff). Never edit them by hand. No secret values: `secrets list --json` has names and
digests only.

| File | Command |
|---|---|
| context-all.json / .txt | `flk context --all [--json]` |
| context-all-nohost.json | `flk context --all --json --no-host` |
| context-minecraft-flk.json | `flk -a minecraft-flk context --json` |
| context.txt | `flk context` (in ~, outside any app dir) |
| help-all.json | `flk help --all --json` |
| help-TOPIC.txt | `flk help TOPIC` for cheatsheet, install, first-app, operate, troubleshoot, uninstall |
| doctor.json | `flk doctor --json` |
| apps-list.json | `flk apps list --json` |
| ports-list.json | `flk ports list --json` |
| status-minecraft-flk.json | `flk -a minecraft-flk status --json` |
| releases-minecraft-flk.json | `flk -a minecraft-flk releases --json` |
| volumes-minecraft-flk.json | `flk -a minecraft-flk volumes list --json` |
| secrets-minecraft-flk.json | `flk -a minecraft-flk secrets list --json` |
| machine-status.json | `flk -a minecraft-flk machine status ID` |
| logs-minecraft-flk.txt | `flk -a minecraft-flk logs -n 40 --no-tail` |
| config-minecraft-flk.json | `flk -a minecraft-flk config show --json` (same as without --json) |
| backups-minecraft-flk.json | `flk -a minecraft-flk volumes backups --json` |
| backups-sample.json | `flk -a flkt-lazyflk-m2 volumes backups --json` at flk 407ff4d: a test app (since destroyed) after one offline and one stop-mode backup |
| df.txt | `df -k --output=target,size,used,avail,pcent MOUNT_DIRS...` (the `mount_dirs` of context-all.json, which start with the state dir) |
| machine-stats.json | `flk machine stats --all --json` |
| disk.json | `flk disk --json` |
| images.json | `flk images --json` |

Host commands for the providers (SPEC 10), as run by lazyflk:

| File | Command |
|---|---|
| podman-ps.json | `podman ps -a --external --format json` (none at capture; the tests use a stub for leftovers) |
| podman-images.json | `podman images --format json` |
| lsblk.json | `lsblk -e7 -b --json -o NAME,PATH,TYPE,SIZE,FSTYPE,FSSIZE,FSAVAIL,MOUNTPOINTS,MODEL` |
| lsblk-snapshot.json | the same, at flk 6183c62, while an LVM snapshot of /data/minecraft existed (since removed); not recaptured |
| systemctl-show.txt | `systemctl show --timestamp=utc -p Id,Description,LoadState,ActiveState,SubState,UnitFileState,ActiveEnterTimestamp,StateChangeTimestamp,MainPID,Result,NRestarts` for flk's units and the default pins |
| id-groups.txt | `id -Gn` |
| buildah-version.txt | `buildah --version` (present: build containers are removed with buildah rm) |
| journal-chrony.txt | `journalctl -u chrony.service -n 40 --no-pager -o short-iso` |
