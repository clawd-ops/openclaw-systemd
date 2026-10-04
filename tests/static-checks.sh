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

# The env file must round-trip exactly when sourced by POSIX sh, which is how
# `oc` loads it.
env -i PATH=/usr/bin:/bin QUOTED='a"b$c\d`e' MULTI="line1${nl}line2" SPACED='x  y' \
  /usr/local/bin/node /usr/local/libexec/openclaw-systemd/write-env-file.mjs /tmp/rt
env -i /bin/sh -ec '
  set -a; . /tmp/rt; set +a
  nl="
"
  test "$QUOTED" = '"'"'a"b$c\d`e'"'"'
  test "$MULTI" = "line1${nl}line2"
  test "$SPACED" = "x  y"
'
grep -q '^  \. /run/openclaw/gateway.env$' /usr/local/bin/oc
! grep -q runuser /usr/local/bin/openclaw-probe-live
grep -q '^unset LD_PRELOAD' /usr/local/bin/oc

# openclaw wrapper: not a symlink (that's what it replaced), hands root to
# `oc`, and runs the image CLI directly for anyone else via a stable
# libexec symlink that still resolves to /app/openclaw.mjs.
test ! -L /usr/local/bin/openclaw
test -x /usr/local/bin/openclaw
grep -q 'exec /usr/local/bin/oc "$@"' /usr/local/bin/openclaw
grep -q 'exec /usr/local/libexec/openclaw-systemd/openclaw-real "$@"' /usr/local/bin/openclaw
test "$(readlink /usr/local/libexec/openclaw-systemd/openclaw-real)" = /app/openclaw.mjs

# The PVC shadow shim mirrors the same uid check, so bind-mounting it over
# ~/.local/bin/openclaw does not change non-root behavior.
test -x /usr/local/libexec/openclaw-systemd/local-bin-openclaw-shadow
grep -q 'exec /usr/local/bin/oc "$@"' /usr/local/libexec/openclaw-systemd/local-bin-openclaw-shadow
grep -q 'exec node /app/openclaw.mjs "$@"' /usr/local/libexec/openclaw-systemd/local-bin-openclaw-shadow

# Doctor-on-upgrade: the drop-in is wired up, and repair-if-needed's decision
# table holds. Doctor itself is simulated here; boot-test.sh runs it for real.
r=/usr/local/libexec/openclaw-systemd/repair-if-needed
d=/etc/systemd/user/service.d/10-openclaw-gateway-repair.conf
test -x "$r"
test -x /usr/local/libexec/openclaw-systemd/mark-healthy
# Must live in the top-level service.d: OpenClaw seals its unit
# (SERVICE_DEFINITION_SEALED [foreign-owner]) if a unit-specific drop-in is
# owned by another account.
test ! -e /etc/systemd/user/openclaw-gateway.service.d
grep -qx "ExecStartPre=$r %n" "$d"
grep -q '^ExecStartPost=-.*mark-healthy %n &' "$d"
grep -qx 'TimeoutStartSec=15min' "$d"
grep -q 'OPENCLAW_SERVICE_REPAIR_POLICY=external' "$r"
grep -q 'openclaw-systemd/repair-blocked' /usr/local/bin/openclaw-probe-live
# ...and honors it only for the current image version.
grep -q 'require("/app/package.json").version' /usr/local/bin/openclaw-probe-live
grep -q 'openclaw.mjs doctor --fix --non-interactive' "$r"

v=$(/usr/local/bin/node -p 'require("/app/package.json").version')
st=/tmp/rh/.openclaw/state/openclaw-systemd
rr() { HOME=/tmp/rh OPENCLAW_SYSTEMD_REPAIR_SIMULATE=$1 "$r" openclaw-gateway.service; }
fresh() { rm -rf /tmp/rh; mkdir -p "$st"; }

# The drop-in applies to every user service: anything but the gateway is a
# silent no-op, even with a repair forced and a failing Doctor.
fresh; touch "$st/force-repair"
out=$(HOME=/tmp/rh OPENCLAW_SYSTEMD_REPAIR_SIMULATE=fail "$r" dbus.service)
test -z "$out"
out=$(HOME=/tmp/rh OPENCLAW_SYSTEMD_REPAIR_SIMULATE=fail "$r")
test -z "$out"
test -e "$st/force-repair"
test ! -e "$st/repaired-version"
test ! -e "$st/start-pending"
out=$(HOME=/tmp/rh /usr/local/libexec/openclaw-systemd/mark-healthy dbus.service)
test -z "$out"

# Never repaired: upgrade repair, stamp written, failed-start detection armed.
fresh
out=$(rr ok)
echo "$out" | grep -qF "upgrade <never repaired> -> $v"
test "$(cat "$st/repaired-version")" = "$v"
test "$(cat "$st/start-pending")" = 0

# Current and last start healthy: Doctor does not run (a simulated failure
# would otherwise exit non-zero), no output, detection re-armed.
rm "$st/start-pending"
out=$(rr fail)
test -z "$out"
test "$(cat "$st/start-pending")" = 0

# Upgrade repair failure fails closed, leaves the old stamp, and blocks.
fresh; echo 2026.1.1 > "$st/repaired-version"
if rr fail >/dev/null; then echo "failed upgrade repair must fail closed"; exit 1; fi
test "$(cat "$st/repaired-version")" = 2026.1.1
grep -q "^$v doctor exited 1 (upgrade 2026.1.1 -> $v)" "$st/repair-blocked"

# While blocked for this version, starts fail fast without running Doctor,
# even if Doctor would now succeed: no automatic retry loop.
if out=$(rr ok); then echo "blocked repair must keep failing"; exit 1; fi
echo "$out" | grep -q 'not retrying automatically'
! echo "$out" | grep -q 'running doctor'
test "$(cat "$st/repaired-version")" = 2026.1.1

# An older force-repair does not lift the block; a newer one retries, and
# success clears both the block and the request.
touch -d '2000-01-01' "$st/force-repair"
if rr ok >/dev/null; then echo "a stale force-repair must not lift the block"; exit 1; fi
touch "$st/force-repair"; touch -d '2000-01-02' "$st/repair-blocked"
out=$(rr ok); echo "$out" | grep -q 'running doctor --fix (forced'
test ! -e "$st/repair-blocked"; test ! -e "$st/force-repair"
test "$(cat "$st/repaired-version")" = "$v"

# A block recorded for a different version (a newer image) is not honored.
fresh; echo 2026.1.1 > "$st/repaired-version"; echo "2026.1.1 old failure" > "$st/repair-blocked"
out=$(rr ok); echo "$out" | grep -q "upgrade 2026.1.1 -> $v"
test ! -e "$st/repair-blocked"

# Upgrade repair success resets the failed-start budget.
fresh; echo 2026.1.1 > "$st/repaired-version"; echo 2 > "$st/start-pending"
rr ok >/dev/null
test "$(cat "$st/start-pending")" = 0

# Doctor succeeding is not enough: if the stamp cannot be written, an upgrade
# repair still fails closed (and would otherwise rerun every start).
fresh; mkdir "$st/repaired-version.tmp"
if rr ok >/dev/null; then echo "unwritable stamp must fail closed"; exit 1; fi
test -e "$st/repair-blocked"
rmdir "$st/repaired-version.tmp"

# Forced repair fails closed and keeps the request for the retry.
fresh; echo "$v" > "$st/repaired-version"; touch "$st/force-repair"
if rr fail >/dev/null; then echo "failed forced repair must fail closed"; exit 1; fi
test -e "$st/force-repair"
test -e "$st/repair-blocked"

# Failed start: repairs, fails open, counts attempts, stops at the cap.
fresh; echo "$v" > "$st/repaired-version"; echo 0 > "$st/start-pending"
out=$(rr fail); echo "$out" | grep -q 'never became healthy (repair 1 of 2)'
test "$(cat "$st/start-pending")" = 1
out=$(rr fail); echo "$out" | grep -q 'repair 2 of 2'
test "$(cat "$st/start-pending")" = 2
out=$(rr fail); echo "$out" | grep -q 'starting without repair'
! echo "$out" | grep -q 'running doctor'
test "$(cat "$st/start-pending")" = 2

# A successful failed-start repair keeps its attempt count.
fresh; echo "$v" > "$st/repaired-version"; echo 1 > "$st/start-pending"
rr ok >/dev/null
test "$(cat "$st/start-pending")" = 2
rm -rf /tmp/rh

systemd --version | head -1
echo "static checks passed"
