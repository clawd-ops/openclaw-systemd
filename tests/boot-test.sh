#!/bin/bash
# Boots the image with systemd as PID 1 under Docker, shaped like the
# Kubernetes pod: only the documented capabilities (not --privileged), a
# private cgroup namespace, tmpfs /run, and a PERSISTENT home volume. Covers
# first boot, the native gateway lifecycle, a clean halt, and a second boot
# that reuses the installed unit and prunes a stale persisted key.
# Usage: tests/boot-test.sh <image>
set -euo pipefail
img=$1
vol=openclaw-systemd-ci-home
docker rm -f boot >/dev/null 2>&1 || true
docker volume rm -f "$vol" >/dev/null 2>&1 || true
docker volume create "$vol" >/dev/null
docker run --rm -v "$vol:/home/openclaw" --entrypoint chown "$img" 1000:1000 /home/openclaw

# Plant a fake ~/.local/bin/openclaw on the volume before boot, the way the
# deployed pod's init container would. Exiting 99 makes it obvious if
# anything (root's bare `openclaw`, in particular) ever actually runs it
# instead of being shadowed by the entrypoint.
docker run --rm -v "$vol:/home/openclaw" --entrypoint sh "$img" -c '
  mkdir -p /home/openclaw/.local/bin
  cat > /home/openclaw/.local/bin/openclaw <<"EOF"
#!/bin/sh
exit 99
EOF
  chmod +x /home/openclaw/.local/bin/openclaw
  chown -R 1000:1000 /home/openclaw
'

# AppArmor is disabled only because Docker's default profile forbids the
# cgroup remount; Kubernetes on the target cluster runs without AppArmor.
docker run -d --name boot \
  --cap-drop ALL \
  --cap-add SYS_ADMIN --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add KILL --cap-add SETGID --cap-add SETPCAP --cap-add SETUID \
  --security-opt no-new-privileges --security-opt apparmor=unconfined \
  --cgroupns=private \
  --tmpfs /run --tmpfs /run/lock \
  -v "$vol:/home/openclaw" \
  -e HOME=/home/openclaw -e OPENCLAW_HOME=/home/openclaw \
  -e OPENCLAW_GATEWAY_TOKEN=ci-dummy-token \
  -e OPENCLAW_SYSTEMD_HEAP_MIB=8192 \
  -e OPENCLAW_DISABLE_BONJOUR=1 \
  "$img" >/dev/null
trap 'docker logs boot 2>&1 | tail -80' EXIT

wait_ready() {
  for _ in $(seq 1 60); do
    docker exec boot openclaw-probe-ready 2>/dev/null && return 0
    sleep 3
  done
  echo "gateway never became ready"; return 1
}

halt() {
  local start code logs
  start=$(date +%s)
  docker stop -t 60 boot >/dev/null
  code=$(docker inspect -f '{{.State.ExitCode}}' boot)
  echo "stopped in $(( $(date +%s) - start ))s with exit code $code"
  test "$code" = 0
  logs=$(docker logs boot 2>&1)
  grep -q 'shutdown\] completed cleanly' <<<"$logs"
}

echo "== first boot"
wait_ready
docker exec boot openclaw-probe-live
status=$(docker exec boot oc gateway status)
printf '%s\n' "$status"
if grep -q "Service config issue" <<<"$status"; then
  echo "gateway status reports a service config issue"; exit 1
fi
docker exec boot sh -ec '
  u=/home/openclaw/.config/systemd/user/openclaw-gateway.service
  grep -q -- "--max-old-space-size=[0-9]" "$u"
  test "$(stat -c %U:%a /home/openclaw/.config/systemd/user)" = node:700
  # PID 1 must hold exactly the 7 runtime caps (no SYS_ADMIN).
  test "$(awk "/^CapEff:/ {print \$2}" /proc/1/status)" = 00000000000001eb
  # The unit `openclaw gateway install` wrote must run the built gateway
  # entrypoint directly, never the openclaw wrapper or oc.
  execstart=$(grep "^ExecStart=" "$u")
  echo "$execstart" | grep -q "/app/dist/index.js"
  ! echo "$execstart" | grep -q "openclaw-real\|/usr/local/bin/openclaw\b\|/usr/local/bin/oc\b"
'
# Hosted runners have less RAM than 4x the requested heap, so the pin cannot
# apply here; the entrypoint must say so rather than fail silently.
logs=$(docker logs boot 2>&1)
grep -q "WARNING: OPENCLAW_SYSTEMD_HEAP_MIB=8192 needs 4x" <<<"$logs"

echo "== oc works from a systemd job (empty environment), not just exec"
# env -i guarantees nothing from this exec session leaks in: the test only
# passes if oc reloads the boot env file itself.
out=$(docker exec boot systemd-run --quiet --wait --pipe --collect \
  env -i PATH=/usr/local/bin:/usr/bin:/bin oc gateway status 2>&1)
grep -q "^Runtime: running" <<<"$out" || { printf '%s\n' "$out"; echo "oc failed inside a systemd job"; exit 1; }

check_root_openclaw_shadow() {
  # Same PATH order the deployed pod uses (~/.local/bin first). The entrypoint
  # must have bind-mounted our shim over the fake, exit-99 file planted before
  # boot; if it did not, this either fails outright or exits 99.
  docker exec boot mountpoint -q /home/openclaw/.local/bin/openclaw
  local out
  out=$(docker exec boot systemd-run --quiet --wait --pipe --collect \
    env -i PATH=/home/openclaw/.local/bin:/usr/local/bin:/usr/bin:/bin openclaw gateway status 2>&1)
  grep -q "^Runtime: running" <<<"$out" || { printf '%s\n' "$out"; echo "bare openclaw failed or ran the shadowed PVC file as root"; exit 1; }
}

echo "== bare openclaw works as root, even with the PVC ~/.local/bin shadow"
check_root_openclaw_shadow

echo "== uid 1000 runs the real CLI directly, no handoff through oc"
# Break oc first: if uid 1000's bare `openclaw` still works, it proves the
# wrapper's non-root branch never called oc.
docker exec boot chmod 000 /usr/local/bin/oc
out=$(docker exec boot setpriv --reuid=1000 --regid=1000 --init-groups openclaw --version 2>&1) && rc=0 || rc=$?
docker exec boot chmod 0755 /usr/local/bin/oc
{ test "$rc" = 0 && [ -n "$out" ]; } || { printf '%s\n' "$out"; echo "uid 1000 openclaw --version failed"; exit 1; }

echo "== probes do not open PAM sessions (log noise)"
# Read the journal inside the container around one probe run, flushing it
# before taking the cursor and before reading, so late lines from earlier
# steps cannot land in the window and the probe's own lines cannot be missed.
docker exec boot sh -ec '
  journalctl --sync
  c=$(journalctl -n 1 --show-cursor -q -o cat | sed -n "s/^-- cursor: //p"); test -n "$c"
  openclaw-probe-live >/dev/null
  journalctl --sync
  n=$(journalctl --after-cursor="$c" -o cat | grep -c "pam_unix(runuser" || true)
  test "$n" = 0 || { echo "probe opened $n PAM session lines"; exit 1; }
'

echo "== native stop/start, container stays up"
docker exec boot oc gateway stop --force
docker exec boot openclaw-probe-live
if docker exec boot openclaw-probe-ready; then echo "gateway still answering after stop"; exit 1; fi
docker exec boot oc gateway start
wait_ready

echo "== plant a stale Kubernetes-owned key plus an operator key, then halt"
docker exec boot sh -ec '
  f=/home/openclaw/.openclaw/gateway.systemd.env
  printf "OPENCLAW_GATEWAY_TOKEN=stale\nCI_OPERATOR_KEY=kept\n" > "$f"
  chown 1000:1000 "$f"; chmod 644 "$f"
'
halt

echo "== bind mount never wrote through to the PVC file"
# The shadow only shadows the path inside the container's mount namespace;
# the fake, exit-99 file the earlier check ran against must still be exactly
# what was planted before first boot, unowned by the mount and untouched by
# either boot.
docker run --rm -v "$vol:/home/openclaw" --entrypoint sh "$img" -c '
  test "$(cat /home/openclaw/.local/bin/openclaw)" = "#!/bin/sh
exit 99"
  test "$(stat -c %U:%a /home/openclaw/.local/bin/openclaw)" = node:755
'

echo "== second boot (unit already on the volume, fresh /run)"
docker start boot >/dev/null
wait_ready
logs=$(docker logs boot 2>&1)
grep -q "bootstrap: gateway unit already installed" <<<"$logs"
docker exec boot sh -ec '
  f=/home/openclaw/.openclaw/gateway.systemd.env
  test "$(cat "$f")" = "CI_OPERATOR_KEY=kept"
  test "$(stat -c %U:%a "$f")" = node:600
'
docker exec boot openclaw-probe-live
echo "== bind mount re-applies on a fresh /run after restart"
check_root_openclaw_shadow
halt
docker rm -f boot >/dev/null
docker volume rm -f "$vol" >/dev/null
trap - EXIT
echo "boot test passed"
