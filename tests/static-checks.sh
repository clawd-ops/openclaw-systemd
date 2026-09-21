#!/bin/sh
# Runs inside the image (entrypoint bypassed). Checks the baked-in layout and
# the env-file writer's quoting and exclusions.
set -eu
getent passwd node | grep -q ':/home/openclaw:'
test -f /var/lib/systemd/linger/node
test "$(readlink /etc/systemd/system/systemd-initctl.socket)" = /dev/null
test -x /usr/local/sbin/openclaw-systemd-entrypoint
test -L /etc/systemd/system/multi-user.target.wants/openclaw-bootstrap.service

nl='
'
env -i PATH=/usr/bin:/bin HOME=/root OPENCLAW_HOME=/x KUBERNETES_PORT=1 \
  QUOTED='a"b$c\d`e' MULTI="line1${nl}line2" \
  /usr/local/bin/node /usr/local/libexec/openclaw-systemd/write-env-file.mjs /tmp/e
grep -qx 'PATH="/usr/bin:/bin"' /tmp/e
grep -qxF 'QUOTED="a\"b\$c\\d\`e"' /tmp/e
! grep -q '^HOME=' /tmp/e
! grep -q '^OPENCLAW_HOME=' /tmp/e
! grep -q '^KUBERNETES_' /tmp/e
test "$(stat -c %a /tmp/e)" = 600

# prune: Kubernetes-owned keys dropped, others kept, unusual files untouched.
printf 'OWNED=old\nKEEP=1\n' > /tmp/s
OWNED=new /usr/local/bin/node /usr/local/libexec/openclaw-systemd/prune-service-env.mjs /tmp/s
test "$(cat /tmp/s)" = "KEEP=1"
printf 'OWNED=old\nKEEP=1\n' > /tmp/w && chmod 644 /tmp/w
OWNED=new /usr/local/bin/node /usr/local/libexec/openclaw-systemd/prune-service-env.mjs /tmp/w
test "$(stat -c %a /tmp/w)" = 600
printf 'OWNED="multi\nline"\n' > /tmp/m
OWNED=new /usr/local/bin/node /usr/local/libexec/openclaw-systemd/prune-service-env.mjs /tmp/m
grep -q multi /tmp/m
OWNED=new /usr/local/bin/node /usr/local/libexec/openclaw-systemd/prune-service-env.mjs /tmp/m | grep -q "WARNING: it overrides Kubernetes-supplied OWNED"
printf 'OWNED=old\n' > /tmp/o
OWNED=new /usr/local/bin/node /usr/local/libexec/openclaw-systemd/prune-service-env.mjs /tmp/o
test ! -e /tmp/o

systemd --version | head -1
echo "static checks passed"
