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
'
# Hosted runners have less RAM than 4x the requested heap, so the pin cannot
# apply here; the entrypoint must say so rather than fail silently.
logs=$(docker logs boot 2>&1)
grep -q "WARNING: OPENCLAW_SYSTEMD_HEAP_MIB=8192 needs 4x" <<<"$logs"

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
halt
docker rm -f boot >/dev/null
docker volume rm -f "$vol" >/dev/null
trap - EXIT
echo "boot test passed"
