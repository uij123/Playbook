import { z } from "zod";

// ---------- Recording session (recorder output) ----------

export interface RecElement {
  role?: string | null;
  title?: string | null;
  description?: string | null;
  value?: string | null;
  secure?: boolean | null;
  frame?: { x: number; y: number; w: number; h: number } | null;
  path?: { role?: string | null; title?: string | null }[] | null;
}

export interface RecEvent {
  t: number;
  type: string;
  button?: string;
  clicks?: number;
  x?: number;
  y?: number;
  app?: string;
  bundle_id?: string;
  window_title?: string;
  element?: RecElement;
  screenshot?: string;
  chars?: string;
  key_code?: number;
  mods?: string[];
  redacted?: boolean;
  dx?: number;
  dy?: number;
}

export interface RecMeta {
  started?: string;
  ended?: string;
  screen?: { w: number; h: number };
  launch_app?: string | null;
  voice?: boolean;
  events?: number;
}

export interface TranscriptSeg {
  t0: number;
  t1: number;
  text: string;
}

// ---------- Playbook DSL (zod is the source of truth) ----------
//
// v0.1: app.activate / ui.click / ui.type / ui.key / wait — deterministic replay.
// v0.2 adds data flow: `capture` reads screen content into a runtime variable,
// `judge` is an explicit, bounded model decision over captured data, `foreach`
// iterates nested steps over a JSON array variable. {{name}} and {{name.path}}
// placeholders resolve at step-execution time from inputs ∪ captured ∪ loop vars.

export interface PBA11y {
  role: string;
  title?: string | null;
  description?: string | null;
}

export interface PBTarget {
  app?: string | null;
  window?: { title_contains?: string | null } | null;
  a11y?: PBA11y | null;
  fallback_point?: { x: number; y: number } | null;
}

export interface PBVerify {
  frontmost_app?: string | null;
  window_title_contains?: string | null;
  element_exists?: PBTarget | null;
  element_value_contains?: string | null;
  wait_ms?: number | null;
}

export interface PBCapture {
  /** variable name the captured text is stored under */
  into: string;
  /** which accessibility attribute to read (default "value") */
  attribute?: "value" | "title" | "description" | null;
  /**
   * "element" reads one node; "subtree" concatenates all text under it;
   * "screenshot" grabs the target's pixels as an image the judge can see
   * (the variable holds an image reference usable in input_vars)
   */
  scope?: "element" | "subtree" | "screenshot" | null;
}

export type PBStepKind =
  | "app.activate"
  | "ui.click"
  | "ui.type"
  | "ui.key"
  | "wait"
  | "capture"
  | "judge"
  | "foreach"
  | "stop";

export interface PBStep {
  id: string;
  intent: string;
  do: PBStepKind;
  target?: PBTarget | null;
  value?: string | null;
  clicks?: number | null;
  button?: "left" | "right" | null;
  verify?: PBVerify | null;
  on_fail?: "abort" | "continue" | "next_item" | null;
  timeout_ms?: number | null;
  notes?: string | null;
  // capture
  capture?: PBCapture | null;
  // judge — the explicit nondeterministic island. Inputs/outputs are logged in
  // the run report; captured screen text is passed as data, never instructions.
  prompt?: string | null;
  input_vars?: string[] | null;
  into?: string | null;
  output?: "json" | "text" | null;
  /** classification mode: the answer must be exactly one of these strings */
  choices?: string[] | null;
  /** optional model override for this judge (e.g. a cheap model for easy calls) */
  model?: string | null;
  // foreach
  /** "{{var}}" whose value must be a JSON array */
  items?: string | null;
  /** loop variable name (default "item") */
  as?: string | null;
  steps?: PBStep[] | null;
  max_iterations?: number | null;
  // stop — graceful early exit ("if none, don't do anything")
  /**
   * variable path; if it is empty (missing, null, "", [] or {}) the run ends
   * successfully here and the remaining steps are skipped. Omit for an
   * unconditional graceful stop.
   */
  if_empty?: string | null;
}

/**
 * A stage groups a contiguous run of top-level steps under a plain-language
 * title + summary — the "boxes" a non-technical user sees. Stage k covers the
 * steps after the previous stage's `until` through its own `until` (a top-level
 * step id). Stages are presentation + intent; the runner ignores them.
 */
export interface PBStage {
  title: string;
  summary?: string | null;
  until: string;
}

export interface PBInput {
  name: string;
  type: "string";
  ask?: string | null;
  default?: string | null;
}

export interface Playbook {
  playbook: string;
  version: string;
  description?: string | null;
  created?: string | null;
  inputs: PBInput[];
  credentials: { slot: string; scope?: string | null }[];
  steps: PBStep[];
  stages?: PBStage[] | null;
}

export const A11ySchema: z.ZodType<PBA11y> = z.object({
  role: z.string(),
  title: z.string().nullish(),
  description: z.string().nullish(),
});

export const TargetSchema: z.ZodType<PBTarget> = z.object({
  app: z.string().nullish(),
  window: z.object({ title_contains: z.string().nullish() }).nullish(),
  a11y: A11ySchema.nullish(),
  fallback_point: z.object({ x: z.number(), y: z.number() }).nullish(),
});

export const VerifySchema: z.ZodType<PBVerify> = z.object({
  frontmost_app: z.string().nullish(),
  window_title_contains: z.string().nullish(),
  element_exists: TargetSchema.nullish(),
  element_value_contains: z.string().nullish(),
  wait_ms: z.number().int().nullish(),
});

export const CaptureSchema: z.ZodType<PBCapture> = z.object({
  into: z.string().regex(/^[A-Za-z][A-Za-z0-9_]*$/),
  attribute: z.enum(["value", "title", "description"]).nullish(),
  scope: z.enum(["element", "subtree", "screenshot"]).nullish(),
});

export const StepSchema: z.ZodType<PBStep> = z.lazy(() =>
  z
    .object({
      id: z.string(),
      intent: z.string(),
      do: z.enum([
        "app.activate",
        "ui.click",
        "ui.type",
        "ui.key",
        "wait",
        "capture",
        "judge",
        "foreach",
        "stop",
      ]),
      target: TargetSchema.nullish(),
      value: z.string().nullish(),
      clicks: z.number().int().min(1).max(2).nullish(),
      button: z.enum(["left", "right"]).nullish(),
      verify: VerifySchema.nullish(),
      on_fail: z.enum(["abort", "continue", "next_item"]).nullish(),
      timeout_ms: z.number().int().nullish(),
      notes: z.string().nullish(),
      capture: CaptureSchema.nullish(),
      prompt: z.string().nullish(),
      input_vars: z.array(z.string()).nullish(),
      into: z.string().regex(/^[A-Za-z][A-Za-z0-9_]*$/).nullish(),
      output: z.enum(["json", "text"]).nullish(),
      choices: z.array(z.string()).min(2).nullish(),
      model: z.string().nullish(),
      items: z.string().nullish(),
      as: z.string().regex(/^[A-Za-z][A-Za-z0-9_]*$/).nullish(),
      steps: z.array(StepSchema).nullish(),
      max_iterations: z.number().int().min(1).max(1000).nullish(),
      if_empty: z.string().regex(/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*$/).nullish(),
    })
    .superRefine((s, ctx) => {
      if (s.do === "capture") {
        if (!s.capture?.into) ctx.addIssue({ code: "custom", message: `step ${s.id}: capture requires capture.into` });
        if (!s.target) ctx.addIssue({ code: "custom", message: `step ${s.id}: capture requires a target` });
      }
      if (s.do === "judge") {
        if (!s.prompt) ctx.addIssue({ code: "custom", message: `step ${s.id}: judge requires prompt` });
        if (!s.into) ctx.addIssue({ code: "custom", message: `step ${s.id}: judge requires into` });
        if (s.choices && s.output === "json") {
          ctx.addIssue({ code: "custom", message: `step ${s.id}: judge choices and output=json are exclusive` });
        }
      }
      if (s.do === "foreach") {
        if (!s.items) ctx.addIssue({ code: "custom", message: `step ${s.id}: foreach requires items` });
        if (!s.steps || s.steps.length === 0) {
          ctx.addIssue({ code: "custom", message: `step ${s.id}: foreach requires non-empty steps` });
        }
      }
    }),
);

export const InputDefSchema: z.ZodType<PBInput> = z.object({
  name: z.string(),
  type: z.literal("string"),
  ask: z.string().nullish(),
  default: z.string().nullish(),
});

export const StageSchema: z.ZodType<PBStage> = z.object({
  title: z.string().min(1),
  summary: z.string().nullish(),
  until: z.string().min(1),
});

export const PlaybookSchema: z.ZodType<Playbook> = z
  .object({
    playbook: z.string(),
    version: z.string(),
    description: z.string().nullish(),
    created: z.string().nullish(),
    inputs: z.array(InputDefSchema),
    credentials: z.array(z.object({ slot: z.string(), scope: z.string().nullish() })),
    steps: z.array(StepSchema).min(1),
    stages: z.array(StageSchema).nullish(),
  })
  .superRefine((pb, ctx) => {
    if (!pb.stages || pb.stages.length === 0) return;
    const order = new Map(pb.steps.map((s, i) => [s.id, i]));
    let prev = -1;
    for (const st of pb.stages) {
      const at = order.get(st.until);
      if (at === undefined) {
        ctx.addIssue({ code: "custom", message: `stage "${st.title}": until "${st.until}" is not a top-level step id` });
        continue;
      }
      if (at <= prev) {
        ctx.addIssue({ code: "custom", message: `stage "${st.title}": stages must cover steps in order (until "${st.until}" is out of order)` });
      }
      prev = at;
    }
  });

/** Side data from the compiler that intentionally does not live in the playbook. */
export interface DraftExtras {
  /** step id → screenshot path relative to the session dir (evidence for review) */
  shots: Record<string, string>;
  /** step id → [t0, t1] in ms since session start */
  times: Record<string, [number, number]>;
}
