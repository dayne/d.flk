# Fixtures

Real output from the reference host (flk 0.1.0, commit a51bf79, 2026-10-12),
captured with the commands below. Regenerate with the same commands; never
edit them by hand. No secret values: `secrets list --json` has names and
digests only.

| File | Command |
|---|---|
| context-all.json / .txt | `flk context --all [--json]` |
| context-minecraft-flk.json | `flk -a minecraft-flk context --json` |
| context.txt | `flk context` (outside any app dir) |
| help-all.json | `flk help --all --json` |
| doctor.json | `flk doctor --json` |
| apps-list.json | `flk apps list --json` |
| ports-list.json | `flk ports list --json` |
| status-minecraft-flk.json | `flk -a minecraft-flk status --json` |
| releases-minecraft-flk.json | `flk -a minecraft-flk releases --json` |
| volumes-minecraft-flk.json | `flk -a minecraft-flk volumes list --json` |
| secrets-minecraft-flk.json | `flk -a minecraft-flk secrets list --json` |
| machine-status.json | `flk -a minecraft-flk machine status ID` |
| logs-minecraft-flk.txt | `flk -a minecraft-flk logs -n 40 --no-tail` |
