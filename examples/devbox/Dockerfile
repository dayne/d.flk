# A small machine to work in: Ubuntu, a user "dev", and the one thing
# `flk ssh mount` needs from an image, the SFTP server program.
# (No sshd, no keys, no open port: flk starts it itself when you mount.)
FROM docker.io/library/ubuntu:26.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-sftp-server ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
# The same package on other bases:
#   Debian:  apt-get install -y --no-install-recommends openssh-sftp-server
#   Alpine:  apk add --no-cache openssh-sftp-server
#   Fedora:  dnf install -y openssh-server

RUN useradd -m -s /bin/bash dev \
 && echo "Files here are on the 'home' volume: they outlive deploys." > /home/dev/README.txt \
 && chown dev:dev /home/dev/README.txt
USER dev
WORKDIR /home/dev

# Nothing to serve: the machine just stays up to be worked in.
CMD ["sleep", "infinity"]
