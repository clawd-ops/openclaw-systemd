// Removes, from OpenClaw's persisted service env file, every key that
// Kubernetes also supplies in this process's environment, so the Kubernetes
// value (refreshed each boot) wins. Other keys are kept. The file is only
// rewritten if every non-blank, non-comment line is a single-line KEY=value;
// anything else (for example a quoted multi-line value) is left untouched.
import { existsSync, readFileSync, writeFileSync, rmSync, chownSync } from "node:fs";

const file = process.argv[2];
if (!file || !existsSync(file)) process.exit(0);

const text = readFileSync(file, "utf8");
const lines = text.split("\n");
const assignment = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;

const simple = lines.every((l) => {
  if (l.trim() === "" || l.trimStart().startsWith("#")) return true;
  const m = assignment.exec(l);
  if (!m) return false;
  const v = m[2];
  // A value opening a quote it does not close continues on the next line.
  for (const q of ['"', "'"]) {
    if (v.startsWith(q) && (v.length < 2 || !v.endsWith(q))) return false;
  }
  return !v.endsWith("\\");
});
if (!simple) {
  console.log(`openclaw-systemd: ${file} is not plain KEY=value lines; left unchanged`);
  process.exit(0);
}

const kept = [];
const dropped = [];
for (const l of lines) {
  const m = assignment.exec(l);
  if (m && Object.hasOwn(process.env, m[1])) dropped.push(m[1]);
  else kept.push(l);
}
if (dropped.length === 0) process.exit(0);

if (kept.some((l) => assignment.test(l))) {
  writeFileSync(file, kept.join("\n"), { mode: 0o600 });
  chownSync(file, 1000, 1000);
} else {
  rmSync(file);
}
console.log(`openclaw-systemd: dropped Kubernetes-owned keys from ${file}: ${dropped.join(" ")}`);
