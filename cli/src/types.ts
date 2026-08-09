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

// ---------- Playbook DSL v0 (zod is the source of truth) ----------

export const A11ySchema = z.object({
  role: z.string(),
  title: z.string().nullish(),
  description: z.string().nullish(),
});

export const TargetSchema = z.object({
  app: z.string().nullish(),
  window: z.object({ title_contains: z.string().nullish() }).nullish(),
  a11y: A11ySchema.nullish(),
  fallback_point: z.object({ x: z.number(), y: z.number() }).nullish(),
});

export const VerifySchema = z.object({
  frontmost_app: z.string().nullish(),
  window_title_contains: z.string().nullish(),
  element_exists: TargetSchema.nullish(),
  element_value_contains: z.string().nullish(),
  wait_ms: z.number().int().nullish(),
});

export const StepSchema = z.object({
  id: z.string(),
  intent: z.string(),
  do: z.enum(["app.activate", "ui.click", "ui.type", "ui.key", "wait"]),
  target: TargetSchema.nullish(),
  value: z.string().nullish(),
  clicks: z.number().int().min(1).max(2).nullish(),
  button: z.enum(["left", "right"]).nullish(),
  verify: VerifySchema.nullish(),
  on_fail: z.enum(["abort", "continue"]).nullish(),
  timeout_ms: z.number().int().nullish(),
  notes: z.string().nullish(),
});

export const InputDefSchema = z.object({
  name: z.string(),
  type: z.literal("string"),
  ask: z.string().nullish(),
  default: z.string().nullish(),
});

export const PlaybookSchema = z.object({
  playbook: z.string(),
  version: z.string(),
  description: z.string().nullish(),
  created: z.string().nullish(),
  inputs: z.array(InputDefSchema),
  credentials: z.array(z.object({ slot: z.string(), scope: z.string().nullish() })),
  steps: z.array(StepSchema).min(1),
});

export type Playbook = z.infer<typeof PlaybookSchema>;
export type PBStep = z.infer<typeof StepSchema>;
export type PBTarget = z.infer<typeof TargetSchema>;
export type PBInput = z.infer<typeof InputDefSchema>;

/** Side data from the compiler that intentionally does not live in the playbook. */
export interface DraftExtras {
  /** step id → screenshot path relative to the session dir (evidence for review) */
  shots: Record<string, string>;
  /** step id → [t0, t1] in ms since session start */
  times: Record<string, [number, number]>;
}
