ARG OPENCLAW_VERSION=2026.9.5
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

USER root

# systemd as PID 1, a D-Bus user session for the uid 1000 user manager, and
# the tools the entrypoint and probes use.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd dbus dbus-user-session libpam-systemd \
      util-linux libcap2-bin procps curl \
 && rm -rf /var/lib/apt/lists/*

# Native `openclaw gateway install` requires HOME to be the account's passwd
# home. Kubernetes mounts the state volume at /home/openclaw, so that becomes
# uid 1000's home. The unit files below assume uid 1000; fail the build if
# the upstream image ever changes it.
RUN test "$(id -u node)" = 1000 \
 && usermod -d /home/openclaw node \
 && mkdir -p /var/lib/systemd/linger \
 && touch /var/lib/systemd/linger/node

# Units that fail or make no sense in a container, or that would do
# unattended work nobody asked for (apt timers).
RUN for u in systemd-initctl.socket apt-daily.timer apt-daily-upgrade.timer \
             dpkg-db-backup.timer e2scrub_all.timer fstrim.timer \
             systemd-tmpfiles-clean.timer getty.target console-getty.service; do \
      ln -sf /dev/null "/etc/systemd/system/$u"; \
    done

COPY rootfs/ /

RUN chmod 0755 /usr/local/sbin/openclaw-systemd-entrypoint \
               /usr/local/libexec/openclaw-systemd/* \
               /usr/local/bin/oc \
               /usr/local/bin/openclaw-probe-live \
               /usr/local/bin/openclaw-probe-ready \
 && mkdir -p /etc/systemd/system/multi-user.target.wants \
 && ln -sf /etc/systemd/system/k8s-log.service \
           /etc/systemd/system/multi-user.target.wants/k8s-log.service \
 && ln -sf /etc/systemd/system/openclaw-bootstrap.service \
           /etc/systemd/system/multi-user.target.wants/openclaw-bootstrap.service \
 && systemd-analyze verify --man=no \
      /etc/systemd/system/k8s-log.service \
      /etc/systemd/system/openclaw-bootstrap.service

# systemd PID 1 treats SIGTERM as "re-execute". SIGRTMIN+3 is its halt
# signal; the container runtime sends this on pod termination.
STOPSIGNAL SIGRTMIN+3
HEALTHCHECK NONE
ENTRYPOINT ["/usr/local/sbin/openclaw-systemd-entrypoint"]
CMD []
