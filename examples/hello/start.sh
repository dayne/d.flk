#!/bin/sh
# Demo: env, secrets, and a volume that survives redeploys.
set -e
n=$(( $(cat /data/boots 2>/dev/null || echo 0) + 1 ))
echo "$n" > /data/boots
mkdir -p /www
cat > /www/index.html <<HTML
<h1>Hello from $FLK_HOSTNAME</h1>
<p>machine $FLK_MACHINE_ID, app $FLK_APP_NAME, release $FLK_RELEASE</p>
<p>GREETING=$GREETING</p>
<p>API_TOKEN secret present: ${API_TOKEN:+yes}</p>
<p>boots recorded on /data volume: $n</p>
HTML
echo "serving on :8080 (boot #$n)"
exec busybox httpd -f -v -p 8080 -h /www
