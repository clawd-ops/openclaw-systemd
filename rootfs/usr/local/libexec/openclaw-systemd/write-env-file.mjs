// Writes this process's environment (the Kubernetes container env, including
// envFrom Secrets) as a systemd EnvironmentFile. Values are double-quoted with
// systemd's escapes, so multi-line values such as PEM keys survive intact.
import { writeFileSync } from "node:fs";

const target = process.argv[2];
if (!target) throw new Error("usage: write-env-file.mjs <path>");

// HOME and OPENCLAW_HOME must not reach the gateway: native service install
// requires HOME to come from the passwd entry and OPENCLAW_HOME to be unset.
// The rest are per-process or Kubernetes plumbing.
const EXCLUDE = new Set([
  "HOME", "OPENCLAW_HOME", "OPENCLAW_STATE_DIR", "OPENCLAW_CONFIG_PATH",
  "PWD", "OLDPWD", "SHLVL", "_", "container", "HOSTNAME", "TERM",
]);

const quote = (v) => '"' + v.replace(/[\\"`$]/g, (c) => "\\" + c) + '"';

const lines = Object.entries(process.env)
  .filter(([k]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(k))
  .filter(([k]) => !EXCLUDE.has(k) && !k.startsWith("KUBERNETES_"))
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([k, v]) => `${k}=${quote(v)}`);

writeFileSync(target, lines.join("\n") + "\n", { mode: 0o600 });
