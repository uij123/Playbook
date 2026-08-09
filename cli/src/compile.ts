import fs from "node:fs";
import path from "node:path";
import { compileDraft } from "./segment.js";
import { AnthropicProvider, ModelProvider, NullProvider } from "./providers.js";
import {
  DraftExtras,
  PBStep,
  Playbook,
  PlaybookSchema,
  RecEvent,
  RecMeta,
  TranscriptSeg,
} from "./types.js";

export interface CompileOptions {
  name?: string;
  noLlm?: boolean;
  model?: string;
  outDir: string;
}

function readJson<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function stripNulls(_key: string, value: unknown): unknown {
  return value === null ? undefined : value;
}

function targetSummary(step: PBStep): string {
  const t = step.target;
  if (!t) return "current focus";
  const bits: string[] = [];
  if (t.app) bits.push(t.app);
  if (t.window?.title_contains) bits.push(`window "${t.window.title_contains}"`);
  if (t.a11y) {
    const label = t.a11y.title ?? t.a11y.description;
    bits.push(label ? `${t.a11y.role} "${label}"` : t.a11y.role);
  }
  if (t.fallback_point) {
    bits.push(`fallback (${Math.round(t.fallback_point.x)}, ${Math.round(t.fallback_point.y)})`);
  }
  return bits.join(" › ") || "current focus";
}

function verifySummary(step: PBStep): string {
  const v = step.verify;
  if (!v) return "—";
  const bits: string[] = [];
  if (v.frontmost_app) bits.push(`frontmost app is ${v.frontmost_app}`);
  if (v.window_title_contains) bits.push(`window title contains "${v.window_title_contains}"`);
  if (v.element_exists) bits.push("element exists");
  if (v.element_value_contains) bits.push(`value contains "${v.element_value_contains}"`);
  return bits.join("; ") || "—";
}

function renderMarkdown(
  pb: Playbook,
  extras: DraftExtras,
  sessionDir: string,
  outDir: string,
  providerName: string,
): string {
  const lines: string[] = [];
  lines.push(`# ${pb.playbook}`);
  lines.push("");
  if (pb.description) lines.push(`> ${pb.description}`);
  lines.push("");
  lines.push(`Compiled ${pb.created ?? ""} · ${pb.steps.length} steps · refinement: ${providerName}`);
  lines.push("");
  if (pb.inputs.length > 0) {
    lines.push("## Inputs");
    lines.push("");
    lines.push("| name | ask | default |");
    lines.push("|---|---|---|");
    for (const input of pb.inputs) {
      lines.push(`| \`${input.name}\` | ${input.ask ?? ""} | ${input.default ?? "*(required)*"} |`);
    }
    lines.push("");
  }
  lines.push("## Steps");
  lines.push("");
  pb.steps.forEach((step, i) => {
    lines.push(`### ${i + 1}. ${step.intent}`);
    lines.push("");
    lines.push(`- action: \`${step.do}\`${step.value != null ? ` — \`${step.value.replaceAll("`", "'")}\`` : ""}`);
    lines.push(`- target: ${targetSummary(step)}`);
    lines.push(`- verify: ${verifySummary(step)}`);
    if (step.notes) lines.push(`- narration: *${step.notes}*`);
    const shot = extras.shots[step.id];
    if (shot) {
      const rel = path.relative(outDir, path.join(sessionDir, shot));
      lines.push(`- evidence: [${shot}](${rel})`);
    }
    lines.push("");
  });
  lines.push("---");
  lines.push("Review this file, fix anything mis-mapped in the .pb.json, then `pb run` it.");
  lines.push("");
  return lines.join("\n");
}

export async function compileSession(
  sessionDir: string,
  opts: CompileOptions,
): Promise<{ jsonPath: string; mdPath: string; playbook: Playbook }> {
  const eventsPath = path.join(sessionDir, "events.jsonl");
  if (!fs.existsSync(eventsPath)) {
    throw new Error(`${eventsPath} not found — is this a recording session directory?`);
  }
  const events: RecEvent[] = fs
    .readFileSync(eventsPath, "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l) as RecEvent);

  const meta = readJson<RecMeta>(path.join(sessionDir, "meta.json"), {});
  const transcript = readJson<{ segments: TranscriptSeg[] }>(
    path.join(sessionDir, "transcript.json"),
    { segments: [] },
  ).segments;

  const derived = path
    .basename(sessionDir)
    .replace(/^[0-9-]+_/, "")
    .replace(/[^a-zA-Z0-9-]+/g, "-")
    .toLowerCase();
  const name = opts.name ?? (derived || "playbook");

  const { playbook: draft, extras } = compileDraft(events, { name, meta, transcript });
  if (draft.steps.length === 0) {
    throw new Error("no steps could be compiled from this recording (after trimming terminal activity)");
  }

  let provider: ModelProvider = new NullProvider();
  if (!opts.noLlm) {
    if (process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN) {
      provider = new AnthropicProvider(opts.model);
    } else {
      console.warn(
        "note: no Anthropic credentials (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN) — heuristic compile only (pass --no-llm to silence this)",
      );
    }
  }

  let refined = draft;
  let providerName = provider.name;
  if (!(provider instanceof NullProvider)) {
    const appNames = [...new Set(events.map((e) => e.app).filter((a): a is string => !!a))];
    const narration = transcript.map((s) => s.text).join(" ").trim();
    try {
      console.log(`refining with ${provider.name}…`);
      refined = await provider.refine(draft, { narration, appNames });
    } catch (err) {
      console.warn(`warning: refinement failed (${err}) — using heuristic draft`);
      providerName = `${provider.name} → failed, heuristic used`;
    }
  }

  const validated = PlaybookSchema.parse(refined);

  fs.mkdirSync(opts.outDir, { recursive: true });
  const jsonPath = path.join(opts.outDir, `${validated.playbook}.pb.json`);
  const mdPath = path.join(opts.outDir, `${validated.playbook}.pb.md`);
  fs.writeFileSync(jsonPath, JSON.stringify(validated, stripNulls, 2) + "\n");
  fs.writeFileSync(
    mdPath,
    renderMarkdown(validated, extras, sessionDir, opts.outDir, providerName),
  );

  return { jsonPath, mdPath, playbook: validated };
}
