# Fixtures

Real output from the reference host (flk 0.1.0, commit 5ee0db9, 2026-10-12),
captured with the commands below. Regenerate with the same commands; never
edit them by hand. No secret values: `secrets list --json` has names and
digests only.

| File | Command |
|---|---|
| context-all.json / .txt | `flk context --all [--json]` |
| context-minecraft-flk.json | `flk -a minecraft-flk context --json` |
| context.txt | `flk context` (in ~, outside any app dir) |
| help-all.json | `flk help --all --json` (recaptured at flk 3366f33, with volume backups) |
| help-TOPIC.txt | `flk help TOPIC` for cheatsheet, install, first-app, operate, troubleshoot, uninstall (flk 3366f33) |
| doctor.json | `flk doctor --json` |
| apps-list.json | `flk apps list --json` |
| ports-list.json | `flk ports list --json` |
| status-minecraft-flk.json | `flk -a minecraft-flk status --json` |
| releases-minecraft-flk.json | `flk -a minecraft-flk releases --json` |
| volumes-minecraft-flk.json | `flk -a minecraft-flk volumes list --json` |
| secrets-minecraft-flk.json | `flk -a minecraft-flk secrets list --json` |
| machine-status.json | `flk -a minecraft-flk machine status ID` |
| logs-minecraft-flk.txt | `flk -a minecraft-flk logs -n 40 --no-tail` |
| config-minecraft-flk.json | `flk -a minecraft-flk config show` |
| backups-minecraft-flk.json | `flk -a minecraft-flk volumes backups --json` (flk 407ff4d; no backups yet) |
| backups-sample.json | `flk -a flkt-lazyflk-m2 volumes backups --json`: a test app (since destroyed) after one offline and one stop-mode backup |
| df.txt | `df -k --output=target,size,used,avail,pcent STATE_DIR MOUNT_DIRS...` (the `mount_dirs` of context-all.json) |
