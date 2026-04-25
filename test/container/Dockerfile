FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus libnss-systemd libpam-systemd \
      ca-certificates curl sudo procps iproute2 \
      ttyd npm nodejs tmux openssl python3 gettext-base \
      jq \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for the install. Ubuntu 24.04 base image ships with a
# default `ubuntu` user at uid 1000; remove it first so we can take that uid.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -s /bin/bash -u 1000 apiary \
    && echo "apiary ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/apiary

# Mask services we don't need in a container.
RUN systemctl mask \
      dev-hugepages.mount sys-fs-fuse-connections.mount \
      getty.target console-getty.service \
      systemd-remount-fs.service systemd-machine-id-commit.service || true

COPY --chown=apiary:apiary . /home/apiary/src/apiary

STOPSIGNAL SIGRTMIN+3
EXPOSE 3443
CMD ["/sbin/init"]
