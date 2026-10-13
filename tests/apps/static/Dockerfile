# No /bin/sh: scratch with one static busybox at /busybox (not on PATH as sh)
FROM docker.io/library/alpine:3.20 AS bb
RUN apk add --no-cache busybox-static
FROM scratch
COPY --from=bb /bin/busybox.static /busybox
CMD ["/busybox", "sh", "-c", "echo \"hello $GREETING\"; trap 'echo got TERM; exit 0' TERM; while true; do /busybox sleep 1; done"]
