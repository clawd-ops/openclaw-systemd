# openclaw-systemd

The upstream [OpenClaw](https://github.com/openclaw/openclaw) container image with **systemd as PID 1**, so the gateway runs as a native OpenClaw systemd user service inside a Kubernetes pod.

The upstream image starts the gateway directly, so stopping the gateway ends the container. That rules out every command that needs the gateway down: `openclaw gateway stop/start/restart`, `openclaw doctor --fix`, and database maintenance. Here, those commands behave the way they do on a local install. The container keeps running while the gateway is stopped.

Images: `ghcr.io/clawd-ops/openclaw-systemd:<openclaw-version>`. The version tracks upstream through Renovate. Updates are image bumps; `openclaw update` is not supported in the container.

## How it works

1. A root entrypoint prepares the container, drops to 7 capabilities, and `exec`s systemd.
2. systemd starts a lingering user manager for uid 1000 (`node`, whose home is `/home/openclaw`).
3. On first boot, `openclaw-bootstrap.service` runs `openclaw gateway install`. OpenClaw writes its own user unit onto the state volume. Later boots find that unit and the user manager starts it.
4. The gateway runs as uid 1000 with no capabilities, `NoNewPrivs`, and the pod's seccomp profile, the same as the upstream image.
5. Before each gateway start, a drop-in decides whether to run `openclaw doctor --fix` first. See [Upgrades and repair](#upgrades-and-repair).

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
- Probes: `openclaw-probe-live` for liveness (fails only if systemd or the user manager is unhealthy, or the gateway crashed past its restart limit; an intentionally stopped gateway passes), and `openclaw-probe-ready` (gateway answering on `127.0.0.1:18789`) for startup. The startup probe's window must exceed the drop-in's `TimeoutStartSec` (15 minutes) plus gateway startup, for example 20 minutes: a probe that gives up first kills the pod mid-repair, before the repaired version is recorded, so every boot would repeat it. Liveness is unaffected while a repair runs, because the gateway unit is `activating`, not `failed`.

**Security note:** `kubectl exec` processes, including exec probes, get the container's capabilities rather than PID 1's reduced set, so an exec session runs as root with `SYS_ADMIN`. Restrict who can exec into the pod accordingly.

## Operating

The command is just `openclaw`, from `kubectl exec` or anywhere else in the container:

```sh
kubectl exec -it <pod> -c app -- openclaw gateway stop
kubectl exec -it <pod> -c app -- openclaw doctor --fix
kubectl exec -it <pod> -c app -- openclaw gateway start
```

`kubectl exec` lands as root, which can't reach uid 1000's systemd user bus and would otherwise create root-owned files under the account's home. `/usr/local/bin/openclaw` is a small wrapper: as root it hands off to `oc`, which runs the CLI as uid 1000 with the right environment; as any other user it runs the image CLI directly, unchanged. The entrypoint also shadows the same handoff onto `~/.local/bin/openclaw` (an init container's copy that would otherwise win on PATH for a root shell), without touching that file on the state volume. `oc` is still there as an implementation detail, and works the same as a direct alias if you prefer to type it.

Extra system units (for example a helper daemon) can be mounted as files into `/etc/openclaw-systemd/units/`; each `*.service` there is installed and enabled at boot.

## Upgrades and repair

The upstream image's entrypoint runs `openclaw doctor --fix --non-interactive` before every gateway start; that is how retained state is migrated and drifted official plugins are brought to the new release after an image bump. This image replaces that entrypoint, so it runs the same command from an `ExecStartPre` drop-in instead, but only when needed, because a Doctor pass takes on the order of minutes even with nothing to fix.

The drop-in is `/etc/systemd/user/service.d/10-openclaw-gateway-repair.conf`, the top-level drop-in directory that applies to every user service; its scripts receive the unit name and do nothing for anything but `openclaw-gateway.service`. It cannot be a unit-specific `openclaw-gateway.service.d` drop-in: OpenClaw refuses to install or change its unit (`SERVICE_DEFINITION_SEALED [foreign-owner]`) when such a drop-in belongs to another account, and exempts only top-level `service.d` files as shared.

| Trigger | When | If Doctor fails |
|---|---|---|
| Upgrade | The image's OpenClaw version differs from the last version repaired successfully, or nothing has been repaired yet | Fail closed: the gateway is held stopped (see below) |
| Forced | `~/.openclaw/state/openclaw-systemd/force-repair` exists | Fail closed |
| Failed start | The previous start never answered `/healthz` | Fail open: start anyway. After two such repairs without a healthy start, stop repairing until the gateway is healthy again |

Every other start, including `openclaw gateway restart`, skips Doctor and costs a few milliseconds. Doctor runs as the state-owning account with `OPENCLAW_SERVICE_REPAIR_POLICY=external`, since systemd owns the gateway's lifecycle here, so it repairs state without stopping, starting or reinstalling the service. Its output is in the container log, prefixed `repair:`.

When a fail-closed repair fails, it writes `~/.openclaw/state/openclaw-systemd/repair-blocked`. While that names the current version, every later start (systemd's automatic restarts, `openclaw gateway start`, a pod restart) fails immediately without running Doctor again, and `openclaw-probe-live` reports the container live, so Kubernetes leaves it up for inspection instead of restart-looping. Readiness also passes in that state, as it does for an intentionally stopped gateway.

To recover, read the `repair:` lines in the log and fix the cause, then retry. A `force-repair` newer than `repair-blocked` lifts the block:

```sh
kubectl exec -it <pod> -c app -- touch /home/openclaw/.openclaw/state/openclaw-systemd/force-repair
kubectl exec -it <pod> -c app -- openclaw gateway start
```

If the unit has hit systemd's start limit, the start is refused until it is reset; as uid 1000, `systemctl --user reset-failed openclaw-gateway.service`. A successful repair removes both files. To force a repair at any time, touch `force-repair` the same way. To deliberately start without a repair, write the current version (`node -p 'require("/app/package.json").version'`) to `repaired-version` and remove `repair-blocked`.

## Tests

CI builds the image, runs `tests/static-checks.sh` inside it, and boots it with systemd as PID 1 (`tests/boot-test.sh`): first-boot install, pinned heap, stop/start with the container staying up, and a clean halt. The static checks cover the repair decision table with Doctor simulated; the boot test runs Doctor for real on first boot and on a simulated failed start, checks that a plain restart skips it, and checks that a failing repair holds the gateway down with the container still live, then recovers through `force-repair`.
