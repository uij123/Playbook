// Playbooks Studio — local web UI: a library of playbooks and a visual,
// editable brick-tree editor. Serves on 127.0.0.1 only; edits are validated
// against the same zod schema as everything else before touching disk.
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PBStep, Playbook, PlaybookSchema } from "./types.js";
import { findSecretRefs } from "./secrets.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const PLAYBOOK_DIR = path.join(ROOT, "playbooks");
const RUNS_DIR = path.join(ROOT, "runs");
const STUDIO_HTML = path.join(ROOT, "cli", "studio", "studio.html");

function safePlaybookPath(f: string): string | null {
  if (!/^[A-Za-z0-9._ -]+\.pb\.json$/.test(f)) return null;
  const full = path.join(PLAYBOOK_DIR, f);
  return full.startsWith(PLAYBOOK_DIR) ? full : null;
}

function countSteps(steps: PBStep[]): { total: number; judges: number } {
  let total = 0;
  let judges = 0;
  for (const s of steps) {
    total += 1;
    if (s.do === "judge") judges += 1;
    if (s.steps) {
      const inner = countSteps(s.steps);
      total += inner.total;
      judges += inner.judges;
    }
  }
  return { total, judges };
}

interface RunSummary {
  file: string;
  started: string;
  result: string;
  steps: number;
}

function runsFor(name: string): RunSummary[] {
  if (!fs.existsSync(RUNS_DIR)) return [];
  const out: RunSummary[] = [];
  for (const f of fs.readdirSync(RUNS_DIR)) {
    if (!f.startsWith(`${name}-`) || !f.endsWith(".json")) continue;
    try {
      const r = JSON.parse(fs.readFileSync(path.join(RUNS_DIR, f), "utf8")) as {
        playbook?: string;
        started?: string;
        result?: string;
        steps?: unknown[];
      };
      if (r.playbook !== name) continue;
      out.push({
        file: f,
        started: r.started ?? "",
        result: r.result ?? "?",
        steps: Array.isArray(r.steps) ? r.steps.length : 0,
      });
    } catch {
      /* skip unreadable */
    }
  }
  return out.sort((a, b) => b.started.localeCompare(a.started));
}

function json(res: http.ServerResponse, code: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(code, { "content-type": "application/json" });
  res.end(data);
}

async function readBody(req: http.IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

export function startStudio(port: number): http.Server {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    try {
      if (req.method === "GET" && url.pathname === "/") {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        res.end(fs.readFileSync(STUDIO_HTML, "utf8"));
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/playbooks") {
        const items = [];
        for (const f of fs.readdirSync(PLAYBOOK_DIR).sort()) {
          if (!f.endsWith(".pb.json")) continue;
          try {
            const text = fs.readFileSync(path.join(PLAYBOOK_DIR, f), "utf8");
            const pb = JSON.parse(text) as Playbook;
            const counts = countSteps(pb.steps ?? []);
            const runs = runsFor(pb.playbook);
            items.push({
              file: f,
              name: pb.playbook,
              description: pb.description ?? "",
              version: pb.version,
              steps: counts.total,
              judges: counts.judges,
              determinism: counts.total > 0 ? Math.round(((counts.total - counts.judges) / counts.total) * 100) : 100,
              secrets: findSecretRefs(text),
              lastRun: runs[0] ?? null,
              runCount: runs.length,
            });
          } catch {
            items.push({ file: f, name: f, description: "(unreadable)", version: "?", steps: 0, judges: 0, determinism: 0, secrets: [], lastRun: null, runCount: 0 });
          }
        }
        json(res, 200, items);
        return;
      }

      if (url.pathname === "/api/playbook") {
        const f = url.searchParams.get("f") ?? "";
        const full = safePlaybookPath(f);
        if (!full || !fs.existsSync(full)) {
          json(res, 404, { error: "unknown playbook" });
          return;
        }
        if (req.method === "GET") {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(fs.readFileSync(full, "utf8"));
          return;
        }
        if (req.method === "POST") {
          const body = await readBody(req);
          let parsed: unknown;
          try {
            parsed = JSON.parse(body);
          } catch {
            json(res, 400, { error: "not valid JSON" });
            return;
          }
          const result = PlaybookSchema.safeParse(parsed);
          if (!result.success) {
            json(res, 400, { error: "schema validation failed", issues: result.error.issues.slice(0, 10) });
            return;
          }
          fs.writeFileSync(full, JSON.stringify(result.data, (_k, v) => (v === null ? undefined : v), 2) + "\n");
          json(res, 200, { ok: true });
          return;
        }
      }

      if (req.method === "GET" && url.pathname === "/api/runs") {
        json(res, 200, runsFor(url.searchParams.get("name") ?? ""));
        return;
      }

      if (req.method === "GET" && url.pathname === "/api/report") {
        const f = url.searchParams.get("f") ?? "";
        if (!/^[A-Za-z0-9._: -]+\.json$/.test(f)) {
          json(res, 400, { error: "bad report name" });
          return;
        }
        const full = path.join(RUNS_DIR, f);
        if (!full.startsWith(RUNS_DIR) || !fs.existsSync(full)) {
          json(res, 404, { error: "unknown report" });
          return;
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(fs.readFileSync(full, "utf8"));
        return;
      }

      if (req.method === "POST" && url.pathname === "/api/run") {
        const f = url.searchParams.get("f") ?? "";
        const full = safePlaybookPath(f);
        if (!full || !fs.existsSync(full)) {
          json(res, 404, { error: "unknown playbook" });
          return;
        }
        res.writeHead(200, { "content-type": "text/plain; charset=utf-8", "x-accel-buffering": "no" });
        const child = spawn(process.execPath, [path.join(ROOT, "cli", "dist", "index.js"), "run", full], {
          env: process.env,
        });
        child.stdout.on("data", (d: Buffer) => res.write(d));
        child.stderr.on("data", (d: Buffer) => res.write(d));
        child.on("exit", (code) => {
          res.end(`\n[studio] exit ${code}\n`);
        });
        req.on("close", () => child.kill("SIGINT"));
        return;
      }

      json(res, 404, { error: "not found" });
    } catch (err) {
      json(res, 500, { error: String(err).slice(0, 300) });
    }
  });
  server.listen(port, "127.0.0.1");
  return server;
}
