// Secrets vault — macOS Keychain via /usr/bin/security.
//
// Design: playbooks reference secrets as {{secret.NAME}} and NEVER contain
// values, so a playbook file is always safe to share. Values live in the login
// keychain (service "playbooks"). The pb CLI resolves referenced secrets before
// spawning the replayer (using the `security` tool, which created the items, so
// macOS does not prompt) and hands them over via PB_SECRETS_JSON. The replayer
// masks secret values in every console line and run report.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const SERVICE = "playbooks";
const INDEX_DIR = path.join(os.homedir(), ".playbooks");
const INDEX_FILE = path.join(INDEX_DIR, "secret-names.json");

/** Find every {{secret.NAME}} reference in a playbook's raw JSON text. */
export function findSecretRefs(playbookText: string): string[] {
  const names = new Set<string>();
  for (const m of playbookText.matchAll(/\{\{\s*secret\.([A-Za-z][A-Za-z0-9_]*)/g)) {
    names.add(m[1]);
  }
  return [...names].sort();
}

function readIndex(): string[] {
  try {
    const parsed = JSON.parse(fs.readFileSync(INDEX_FILE, "utf8")) as { names?: string[] };
    return Array.isArray(parsed.names) ? parsed.names : [];
  } catch {
    return [];
  }
}

function writeIndex(names: string[]): void {
  fs.mkdirSync(INDEX_DIR, { recursive: true });
  fs.writeFileSync(INDEX_FILE, JSON.stringify({ names: [...new Set(names)].sort() }, null, 2));
  fs.chmodSync(INDEX_FILE, 0o600);
}

export function listSecretNames(): string[] {
  return readIndex();
}

export function getSecret(name: string): string | null {
  const res = spawnSync(
    "security",
    ["find-generic-password", "-s", SERVICE, "-a", name, "-w"],
    { encoding: "utf8" },
  );
  if (res.status !== 0) return null;
  return res.stdout.replace(/\n$/, "");
}

export function setSecret(name: string, value: string): void {
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(name)) {
    throw new Error("secret names must be alphanumeric_underscore, starting with a letter");
  }
  // -U updates in place if the item exists.
  const res = spawnSync(
    "security",
    ["add-generic-password", "-s", SERVICE, "-a", name, "-w", value, "-U"],
    { encoding: "utf8" },
  );
  if (res.status !== 0) {
    throw new Error(`keychain write failed: ${res.stderr.trim()}`);
  }
  writeIndex([...readIndex(), name]);
}

export function removeSecret(name: string): boolean {
  const res = spawnSync(
    "security",
    ["delete-generic-password", "-s", SERVICE, "-a", name],
    { encoding: "utf8" },
  );
  writeIndex(readIndex().filter((n) => n !== name));
  return res.status === 0;
}

/** Resolve every secret a playbook references; returns missing names too. */
export function resolveSecretsFor(playbookText: string): {
  secrets: Record<string, string>;
  missing: string[];
} {
  const secrets: Record<string, string> = {};
  const missing: string[] = [];
  for (const name of findSecretRefs(playbookText)) {
    const value = getSecret(name);
    if (value === null) missing.push(name);
    else secrets[name] = value;
  }
  return { secrets, missing };
}
