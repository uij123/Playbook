import {
  DraftExtras,
  PBInput,
  PBStep,
  PBTarget,
  Playbook,
  RecEvent,
  RecMeta,
  TranscriptSeg,
} from "./types.js";

const FIELD_ROLES = new Set([
  "AXTextField",
  "AXTextArea",
  "AXSearchField",
  "AXComboBox",
  "AXSecureTextField",
]);

// Space (49) is deliberately absent: a bare space is printable text and joins
// the typing run; it only becomes a named key inside a chord.
const SPECIAL_KEYS: Record<number, string> = {
  36: "return",
  76: "enter",
  48: "tab",
  51: "delete",
  53: "esc",
  117: "delete",
  123: "left",
  124: "right",
  125: "down",
  126: "up",
};

const KEYCODE_NAMES: Record<number, string> = {
  0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i",
  38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q",
  15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
  18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
  25: "9", 29: "0", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
  43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
};

interface DraftStep extends Omit<PBStep, "id"> {
  t0: number;
  t1: number;
  screenshot?: string;
}

interface TypingRun {
  buffer: string;
  secure: boolean;
  app?: string;
  target?: PBTarget | null;
  fieldLabel?: string | null;
  t0: number;
  t1: number;
}

function isPrintable(chars: string | undefined): string | null {
  if (!chars || chars.length === 0) return null;
  for (const ch of chars) {
    const code = ch.codePointAt(0) ?? 0;
    if (code < 0x20 || code === 0x7f) return null;
    if (code >= 0xf700 && code <= 0xf8ff) return null; // NSFunctionKey range
  }
  return chars;
}

function orderMods(mods: string[]): string[] {
  const order = ["cmd", "ctrl", "alt", "shift"];
  return order.filter((m) => mods.includes(m));
}

function windowFragment(title: string | undefined): string | undefined {
  if (!title) return undefined;
  // Drop volatile suffixes: edited markers ("Untitled — Edited") and
  // auto-numbered documents ("Untitled 2" must match the front "Untitled N").
  const frag = title
    .split(" — ")[0]
    .split(" - ")[0]
    .replace(/\s+\d+$/, "")
    .trim()
    .slice(0, 40);
  return frag.length > 0 ? frag : undefined;
}

function clickTarget(e: RecEvent): PBTarget {
  const el = e.element;
  return {
    app: e.app ?? undefined,
    window: windowFragment(e.window_title)
      ? { title_contains: windowFragment(e.window_title) }
      : undefined,
    a11y: el?.role
      ? {
          role: el.role,
          title: el.title ?? undefined,
          description: el.description ?? undefined,
        }
      : undefined,
    fallback_point:
      e.x != null && e.y != null ? { x: e.x, y: e.y } : undefined,
  };
}

function humanRole(role: string | null | undefined): string {
  if (!role) return "element";
  return role
    .replace(/^AX/, "")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .toLowerCase();
}

function clickIntent(e: RecEvent): string {
  const el = e.element;
  const label = el?.title ?? el?.description;
  const what = label ? `"${label}"` : `the ${humanRole(el?.role)}`;
  const dbl = (e.clicks ?? 1) > 1 ? "Double-click" : e.button === "right" ? "Right-click" : "Click";
  return `${dbl} ${what}${e.app ? ` in ${e.app}` : ""}`;
}

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n)}…` : s;
}

/** Drop leading/trailing events that happened in the app the recording was started from
 *  (typically the terminal: the command that launched pb, and the Ctrl+C that stopped it). */
function trimLaunchApp(events: RecEvent[], launchApp?: string): RecEvent[] {
  if (!launchApp) return events;
  const inLaunch = (e: RecEvent) => e.app === launchApp;
  let start = 0;
  while (start < events.length && inLaunch(events[start])) start++;
  let end = events.length;
  while (end > start && inLaunch(events[end - 1])) end--;
  return events.slice(start, end);
}

export interface DraftResult {
  playbook: Playbook;
  extras: DraftExtras;
}

export function compileDraft(
  allEvents: RecEvent[],
  opts: { name: string; meta: RecMeta; transcript: TranscriptSeg[] },
): DraftResult {
  const events = trimLaunchApp(allEvents, opts.meta.launch_app ?? undefined);
  const drafts: DraftStep[] = [];
  const inputs: PBInput[] = [];
  let run: TypingRun | null = null;
  let lastFieldTarget: PBTarget | null = null;
  let lastFieldLabel: string | null = null;
  let currentApp: string | undefined = undefined;
  let secureCount = 0;

  const flush = () => {
    if (!run) return;
    const r = run;
    run = null;
    if (r.secure) {
      secureCount += 1;
      const name = `secure_input_${secureCount}`;
      inputs.push({
        name,
        type: "string",
        ask: "This value was typed into a secure field and never recorded — provide it at run time.",
      });
      drafts.push({
        intent: "Type a secure value (redacted at recording time)",
        do: "ui.type",
        target: r.target ?? undefined,
        value: `{{${name}}}`,
        t0: r.t0,
        t1: r.t1,
      });
      return;
    }
    if (r.buffer.length === 0) return;
    const fieldBit = r.fieldLabel ? ` into "${r.fieldLabel}"` : "";
    drafts.push({
      intent: `Type "${truncate(r.buffer, 40)}"${fieldBit}`,
      do: "ui.type",
      target: r.target ?? undefined,
      value: r.buffer,
      verify:
        r.target?.a11y && r.target.a11y.role !== "AXSecureTextField"
          ? { element_value_contains: r.buffer }
          : undefined,
      t0: r.t0,
      t1: r.t1,
    });
  };

  for (const e of events) {
    switch (e.type) {
      case "app_activate": {
        flush();
        if (e.app && e.app !== currentApp) {
          currentApp = e.app;
          drafts.push({
            intent: `Switch to ${e.app}`,
            do: "app.activate",
            target: { app: e.app },
            verify: { frontmost_app: e.app },
            t0: e.t,
            t1: e.t,
          });
        }
        lastFieldTarget = null;
        lastFieldLabel = null;
        break;
      }
      case "click": {
        flush();
        const target = clickTarget(e);
        drafts.push({
          intent: clickIntent(e),
          do: "ui.click",
          target,
          clicks: (e.clicks ?? 1) > 1 ? 2 : undefined,
          button: e.button === "right" ? "right" : undefined,
          t0: e.t,
          t1: e.t,
          screenshot: e.screenshot,
        });
        const role = e.element?.role;
        if (role && FIELD_ROLES.has(role)) {
          lastFieldTarget = target;
          lastFieldLabel = e.element?.title ?? e.element?.description ?? null;
        } else {
          lastFieldTarget = null;
          lastFieldLabel = null;
        }
        if (e.app) currentApp = e.app;
        break;
      }
      case "key": {
        const hardMods = orderMods((e.mods ?? []).filter((m) => m !== "shift"));
        const special = e.key_code != null ? SPECIAL_KEYS[e.key_code] : undefined;

        if (e.redacted) {
          if (!run || !(run as TypingRun).secure) {
            flush();
            run = {
              buffer: "",
              secure: true,
              app: e.app,
              target: lastFieldTarget,
              t0: e.t,
              t1: e.t,
            };
          }
          run.t1 = e.t;
          break;
        }

        if (hardMods.length > 0) {
          flush();
          const printable = isPrintable(e.chars);
          const keyName =
            special ??
            (printable === " " ? "space" : printable?.toLowerCase()) ??
            (e.key_code != null ? KEYCODE_NAMES[e.key_code] : undefined);
          if (!keyName) break;
          const withShift = (e.mods ?? []).includes("shift")
            ? [...hardMods, "shift"]
            : hardMods;
          const chord = [...withShift, keyName].join("+");
          drafts.push({
            intent: `Press ${chord}`,
            do: "ui.key",
            value: chord,
            target: e.app ? { app: e.app } : undefined,
            t0: e.t,
            t1: e.t,
          });
          break;
        }

        if (special === "delete") {
          if (run && !run.secure && run.buffer.length > 0) {
            run.buffer = run.buffer.slice(0, -1);
            run.t1 = e.t;
          } else {
            flush();
            drafts.push({
              intent: "Press delete",
              do: "ui.key",
              value: "delete",
              target: e.app ? { app: e.app } : undefined,
              t0: e.t,
              t1: e.t,
            });
          }
          break;
        }

        if (special) {
          flush();
          drafts.push({
            intent: `Press ${special}`,
            do: "ui.key",
            value: special,
            target: e.app ? { app: e.app } : undefined,
            t0: e.t,
            t1: e.t,
          });
          break;
        }

        const ch = isPrintable(e.chars);
        if (!ch) break;
        if (run && !run.secure && run.app === e.app && e.t - run.t1 <= 3000) {
          run.buffer += ch;
          run.t1 = e.t;
        } else {
          flush();
          run = {
            buffer: ch,
            secure: false,
            app: e.app,
            target: lastFieldTarget,
            fieldLabel: lastFieldLabel,
            t0: e.t,
            t1: e.t,
          };
        }
        break;
      }
      default:
        break; // scrolls are evidence only in v0
    }
  }
  flush();

  // Narration alignment + final assembly
  const steps: PBStep[] = [];
  const extras: DraftExtras = { shots: {}, times: {} };
  drafts.forEach((d, i) => {
    const id = `s${i + 1}`;
    const notes = narrationFor(opts.transcript, d.t0, d.t1);
    const { t0, t1, screenshot, ...step } = d;
    steps.push({ ...step, id, notes: notes || undefined });
    if (screenshot) extras.shots[id] = screenshot;
    extras.times[id] = [t0, t1];
  });

  const fullNarration = opts.transcript.map((s) => s.text).join(" ").trim();

  const playbook: Playbook = {
    playbook: opts.name,
    version: "0.1.0",
    description: fullNarration ? truncate(fullNarration, 240) : undefined,
    created: opts.meta.started ?? new Date().toISOString(),
    inputs,
    credentials: [],
    steps,
  };

  return { playbook, extras };
}

export function narrationFor(
  transcript: TranscriptSeg[],
  t0Ms: number,
  t1Ms: number,
): string {
  if (transcript.length === 0) return "";
  const lo = t0Ms / 1000 - 3.0;
  const hi = t1Ms / 1000 + 1.5;
  const words = transcript.filter((s) => s.t1 >= lo && s.t0 <= hi);
  return words.map((w) => w.text).join(" ").trim();
}
