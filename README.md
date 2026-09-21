# openclaw-systemd

The upstream [OpenClaw](https://github.com/openclaw/openclaw) container image with **systemd as PID 1**, so the gateway runs as a native OpenClaw systemd user service inside a Kubernetes pod.

The upstream image starts the gateway directly, so stopping the gateway ends the container. That rules out every command that needs the gateway down: `openclaw gateway stop/start/restart`, `openclaw doctor --fix`, and database maintenance. Here, those commands behave the way they do on a local install. The container keeps running while the gateway is stopped.

Images: `ghcr.io/clawd-ops/openclaw-systemd:<openclaw-version>`. The version tracks upstream through Renovate. Updates are image bumps; `openclaw update` is not supported in the container.

## How it works

1. A root entrypoint prepares the container, drops to 7 capabilities, and `exec`s systemd.
2. systemd starts a lingering user manager for uid 1000 (`node`, whose home is `/home/openclaw`).
3. On first boot, `openclaw-bootstrap.service` runs `openclaw gateway install`. OpenClaw writes its own user unit onto the state volume. Later boots find that unit and the user manager starts it.
4. The gateway runs as uid 1000 with no capabilities, `NoNewPrivs`, and the pod's seccomp profile, the same as the upstream image.

| Concern | Handling |
|---|---|
| Kubernetes env and Secrets | Written each boot to `/run/openclaw/gateway.env` (tmpfs, root 0600) and loaded by the user manager, so every user unit, including the gateway, gets them. Never written to the state volume. |
| Keys OpenClaw persists | `gateway install` copies some provider keys into `~/.openclaw/gateway.systemd.env`, which would override a rotated Secret. Each boot, keys that Kubernetes also supplies are removed from it. Other keys are kept. |
| Gateway heap | Set `OPENCLAW_SYSTEMD_HEAP_MIB` (>= 8192) to pin `--max-old-space-size` at install. It works by giving the installer a memory limit of 4x that value, so the node needs at least that much RAM; otherwise OpenClaw sizes from RAM and the entrypoint logs a warning. Unset, OpenClaw sizes it from the pod memory limit. |
| Logs | The journal is streamed to the container's stdout, so `kubectl logs` shows systemd, bootstrap, and gateway output, including shutdown. |
| Termination | `STOPSIGNAL SIGRTMIN+3` (systemd's halt signal; SIGTERM would make it re-execute). An idle gateway stops in well under a second. A gateway with work in flight may drain for up to 330s (OpenClaw's fixed service timeout), so set `terminationGracePeriodSeconds` to 360. |
| `/tmp` | Not emptied at boot, since in a pod it is usually shared with other containers. |
| Zombies | systemd reaps them; no tini needed. |

## Pod requirements

- App container: `runAsUser: 0`, `runAsNonRoot: false`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, and add `SYS_ADMIN CHOWN DAC_OVERRIDE FOWNER KILL SETGID SETPCAP SETUID`. `SYS_ADMIN` is only used by the entrypoint to remount the cgroup tree writable, and is dropped before systemd starts. The `RuntimeDefault` seccomp profile works.
- The state volume mounted at `/home/openclaw`.
- `/run` and `/run/lock` as `emptyDir` with `medium: Memory`.
- `terminationGracePeriodSeconds: 360`.
- Probes: `openclaw-probe-live` for liveness (fails only if systemd or the user manager is unhealthy, or the gateway crashed past its restart limit; an intentionally stopped gateway passes), and `openclaw-probe-ready` (gateway answering on `127.0.0.1:18789`) for startup.

**Security note:** `kubectl exec` processes, including exec probes, get the container's capabilities rather than PID 1's reduced set, so an exec session runs as root with `SYS_ADMIN`. Restrict who can exec into the pod accordingly.

## Operating

Use `oc` instead of `openclaw` from `kubectl exec` (which lands as root). It runs the CLI as uid 1000 with the right environment, e.g.:

```sh
kubectl exec -it <pod> -c app -- oc gateway stop
kubectl exec -it <pod> -c app -- oc doctor --fix
kubectl exec -it <pod> -c app -- oc gateway start
```

Extra system units (for example a helper daemon) can be mounted as files into `/etc/openclaw-systemd/units/`; each `*.service` there is installed and enabled at boot.

## Tests

CI builds the image, runs `tests/static-checks.sh` inside it, and boots it with systemd as PID 1 (`tests/boot-test.sh`): first-boot install, pinned heap, stop/start with the container staying up, and a clean halt.
