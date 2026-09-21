#!/bin/bash
# Boots the image with systemd as PID 1 under Docker and exercises the native
# gateway lifecycle. Usage: tests/boot-test.sh <image>
set -euo pipefail
img=$1
docker rm -f boot >/dev/null 2>&1 || true
docker run -d --name boot --privileged --cgroupns=private \
  --tmpfs /run --tmpfs /run/lock \
  --tmpfs /home/openclaw:uid=1000,gid=1000,mode=0755 \
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

wait_ready
docker exec boot openclaw-probe-live
docker exec boot oc gateway status
docker exec boot sh -ec '
  u=/home/openclaw/.config/systemd/user/openclaw-gateway.service
  grep -q -- "--max-old-space-size=8192" "$u"
  test "$(stat -c %U:%a /home/openclaw/.config/systemd/user)" = node:700
'

docker exec boot oc gateway stop --force
docker exec boot openclaw-probe-live
if docker exec boot openclaw-probe-ready; then echo "gateway still answering after stop"; exit 1; fi
docker exec boot oc gateway start
wait_ready

start=$(date +%s)
docker stop -t 60 boot >/dev/null
code=$(docker inspect -f '{{.State.ExitCode}}' boot)
echo "stopped in $(( $(date +%s) - start ))s with exit code $code"
test "$code" = 0
docker logs boot 2>&1 | grep -q 'shutdown\] completed cleanly'
echo "boot test passed"
