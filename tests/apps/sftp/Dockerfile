# For flk ssh mount: an image with OpenSSH's sftp-server (no sshd) and a
# user whose uid (1100) isn't the test runner's.
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache openssh-sftp-server && adduser -D -u 1100 dev \
 && echo "hello from the guest" > /home/dev/note.txt && chown dev:dev /home/dev/note.txt \
 && mkdir /srv/private && chmod 700 /srv/private
CMD ["sh", "-c", "echo up; trap 'exit 0' TERM; while true; do sleep 1; done"]
