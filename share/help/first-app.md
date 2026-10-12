# Your first app

Work in the app's directory. flk reads `flk.toml` there, or an existing
`fly.toml` unchanged.

**1. Register it.**

    flk launch --no-deploy

With no config file, this writes a commented `flk.toml` (Dockerfile build,
`internal_port` 8080, 1 CPU, 256MB). Options: `--image IMAGE` for a
prebuilt image, `--port`, `--cpus`, `--memory`, `--name`.

**2. Shape flk.toml** (`flk config show` prints what flk understood):

    app = "myapp"
    kill_timeout = 30            # seconds to shut down cleanly (max 300)

    [build]
      dockerfile = "Dockerfile"  # or: image = "docker.io/library/nginx:1.27"

    [env]
      MODE = "production"

    [http_service]
      internal_port = 8080       # flk waits for this after boot

    [[vm]]
      cpus = 1
      memory = "512mb"

    [[mounts]]
      source = "data"            # a volume, one per machine
      destination = "/data"

    [[restart]]
      policy = "on-failure"      # the default; "always" or "never"

    [flk]
      http_port = 8080           # also on the host's LAN IP:8080 (>= 1024)

**3. Data and secrets.**

    flk volumes create data --size 1                # or --path /big/disk/data.ext4
    flk secrets set API_TOKEN=... --stage           # --stage: no restart yet

**4. Deploy and check.**

    flk deploy        # build, convert to a VM disk, boot; about a minute
    flk status        # state "started", and the IP
    curl http://MACHINE_IP:8080/
    flk logs          # app output

`flk context` lists what's still missing at any point.

Next: flk help operate
