#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Command } from "commander";
import { compileSession } from "./compile.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const RECORD_BIN = path.join(ROOT, "native", ".build", "release", "pb-record");
const REPLAY_BIN = path.join(ROOT, "native", ".build", "release", "pb-replay");
// The signed .app carries its own TCC identity, which on-device voice requires
// (a shell-spawned binary is attributed to the host terminal, which has no
// speech entitlement). Built by `make bundle` at a stable path so grants persist.
const RECORD_APP = path.join(os.homedir(), "Applications", "Playbooks", "pb-record.app");

function ensureBinary(bin: string): void {
  if (!fs.existsSync(bin)) {
    console.error(`error: ${path.basename(bin)} not built — run \`make native\` first`);
    process.exit(1);
  }
}

function runBinary(bin: string, args: string[]): void {
  const child = spawn(bin, args, { stdio: "inherit" });
  // Ctrl+C goes to the whole foreground group; the recorder handles it and
  // flushes — the CLI just waits for it to finish.
  process.on("SIGINT", () => {});
  child.on("exit", (code, signal) => {
    process.exit(signal ? 130 : code ?? 0);
  });
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Find the pb-record process for this session (launched detached via `open`). */
function findRecorderPid(sessionDir: string): number | null {
  const res = spawnSync("pgrep", ["-f", sessionDir], { encoding: "utf8" });
  if (res.status !== 0 || !res.stdout.trim()) return null;
  for (const pid of res.stdout.trim().split("\n").map(Number).filter(Boolean)) {
    if (pid === process.pid) continue; // our own argv contains the dir too
    const comm = spawnSync("ps", ["-o", "comm=", "-p", String(pid)], { encoding: "utf8" })
      .stdout.trim();
    if (comm.endsWith("pb-record")) return pid;
  }
  return null;
}

/**
 * Drive the signed .app (voice path). `open` launches it as its own TCC subject
 * and returns immediately, so we locate its pid, then forward Ctrl+C to it and
 * wait for the session to finalize (meta.json).
 */
function runViaBundle(sessionDir: string, appArgs: string[]): void {
  const open = spawnSync("open", [RECORD_APP, "--args", ...appArgs], { encoding: "utf8" });
  if (open.status !== 0) {
    console.error(`error: could not launch ${path.basename(RECORD_APP)}: ${open.stderr.trim()}`);
    process.exit(1);
  }

  let pid: number | null = null;
  const deadline = Date.now() + 6000;
  const awaitStart = () => {
    pid = findRecorderPid(sessionDir);
    if (pid) {
      console.log(`● Recording (voice, via pb-record.app) → ${sessionDir}`);
      console.log("  Do the task now. Ctrl+C to stop.");
      const alive = setInterval(() => {
        if (pid && !isAlive(pid)) {
          clearInterval(alive);
          finalize();
        }
      }, 700);
    } else if (Date.now() < deadline) {
      setTimeout(awaitStart, 300);
    } else {
      console.error("error: the recorder app did not start.");
      console.error("  It likely needs a one-time Accessibility grant:");
      console.error("  System Settings → Privacy & Security → Accessibility → enable pb-record.");
      console.error(`  (trigger the prompt: open ${RECORD_APP} --args --out /tmp/pb --voice )`);
      process.exit(2);
    }
  };

  let finalized = false;
  const finalize = () => {
    if (finalized) return;
    finalized = true;
    const dl = Date.now() + 5000;
    const check = () => {
      if (fs.existsSync(path.join(sessionDir, "meta.json")) || Date.now() > dl) {
        const events = fs.existsSync(path.join(sessionDir, "events.jsonl"));
        console.log(`\n■ Stopped → ${sessionDir}${events ? "" : " (no events captured)"}`);
        process.exit(0);
      } else {
        setTimeout(check, 200);
      }
    };
    check();
  };

  const stop = () => {
    if (pid) {
      try {
        process.kill(pid, "SIGINT");
      } catch {
        /* already gone */
      }
    }
    finalize();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  awaitStart();
}

function collect(value: string, previous: string[]): string[] {
  return [...previous, value];
}

const program = new Command();
program
  .name("pb")
  .description("Playbooks — record your screen once, compile it, run it forever")
  .version("0.1.0");

program
  .command("record")
  .description("record a session (screen interactions + optional narration)")
  .option("--name <name>", "session name", "session")
  .option("--voice", "capture voice narration (on-device transcription)", false)
  .option("--locale <locale>", "narration locale, e.g. en-US or fr-FR", "en-US")
  .option("--no-shots", "skip per-click screenshots")
  .action((opts: { name: string; voice: boolean; locale: string; shots: boolean }) => {
    const stamp = new Date()
      .toISOString()
      .slice(0, 16)
      .replace(/[:T]/g, "-");
    const dir = path.join(ROOT, "recordings", `${stamp}_${opts.name}`);
    const args = ["--out", dir];
    if (opts.voice) args.push("--voice", "--locale", opts.locale);
    if (!opts.shots) args.push("--no-shots");

    // Voice needs the app's own permission identity → drive the signed bundle.
    // Everything else runs the binary directly (inherits the terminal's grants).
    if (opts.voice) {
      if (fs.existsSync(RECORD_APP)) {
        runViaBundle(dir, args);
        return;
      }
      console.warn(
        "note: voice needs the signed app bundle, which isn't built.\n" +
          "      run `make bundle` (and `make signing-setup` once) to enable voice.\n" +
          "      recording without narration for now.",
      );
      const i = args.indexOf("--voice");
      if (i >= 0) args.splice(i, 3); // drop --voice --locale <x>
    }
    ensureBinary(RECORD_BIN);
    runBinary(RECORD_BIN, args);
  });

program
  .command("compile")
  .description("compile a recorded session into a playbook")
  .argument("<session>", "path to the recording session directory")
  .option("--name <name>", "playbook name (default: derived from session dir)")
  .option("--no-llm", "heuristic compile only, no model refinement")
  .option("--model <model>", "model for refinement (default: claude-opus-5 or $PLAYBOOKS_MODEL)")
  .action(async (session: string, opts: { name?: string; llm: boolean; model?: string }) => {
    try {
      const { jsonPath, mdPath, playbook } = await compileSession(path.resolve(session), {
        name: opts.name,
        noLlm: !opts.llm,
        model: opts.model,
        outDir: path.join(ROOT, "playbooks"),
      });
      console.log(`✓ ${playbook.steps.length} steps → ${path.relative(process.cwd(), jsonPath)}`);
      console.log(`  review: ${path.relative(process.cwd(), mdPath)}`);
      if (playbook.inputs.length > 0) {
        console.log(`  inputs: ${playbook.inputs.map((i) => i.name).join(", ")}`);
      }
    } catch (err) {
      console.error(`error: ${err instanceof Error ? err.message : err}`);
      process.exit(1);
    }
  });

program
  .command("run")
  .description("replay a playbook deterministically")
  .argument("<playbook>", "path to a .pb.json playbook")
  .option("--input <k=v>", "input value (repeatable)", collect, [])
  .option("--strict", "disable the coordinate fallback rung", false)
  .option("--step-delay <ms>", "pause between steps", "350")
  .action((playbook: string, opts: { input: string[]; strict: boolean; stepDelay: string }) => {
    ensureBinary(REPLAY_BIN);
    const args = [path.resolve(playbook), "--report-dir", path.join(ROOT, "runs")];
    for (const kv of opts.input) args.push("--input", kv);
    if (opts.strict) args.push("--strict");
    args.push("--step-delay", opts.stepDelay);
    runBinary(REPLAY_BIN, args);
  });

program
  .command("doctor")
  .description("check toolchain and permissions")
  .action(() => {
    const checks: [string, string][] = [];
    checks.push(["node", process.version]);
    checks.push(["pb-record", fs.existsSync(RECORD_BIN) ? "built" : "missing — run `make native`"]);
    checks.push(["pb-replay", fs.existsSync(REPLAY_BIN) ? "built" : "missing — run `make native`"]);
    if (fs.existsSync(RECORD_BIN)) {
      const res = spawnSync(RECORD_BIN, ["--check"], { encoding: "utf8" });
      try {
        const status = JSON.parse(res.stdout.trim()) as Record<string, boolean>;
        checks.push([
          "accessibility",
          status.accessibility ? "granted" : "NOT granted — System Settings → Privacy & Security → Accessibility",
        ]);
        checks.push([
          "screen recording",
          status.screen_recording ? "granted" : "NOT granted — System Settings → Privacy & Security → Screen Recording",
        ]);
      } catch {
        checks.push(["permissions", "could not check"]);
      }
    }
    checks.push([
      "model credentials",
      process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN
        ? "present (model refinement on)"
        : "not set (heuristic compile only — export ANTHROPIC_API_KEY)",
    ]);
    for (const [k, v] of checks) {
      console.log(`  ${k.padEnd(18)} ${v}`);
    }
  });

program.parse();
