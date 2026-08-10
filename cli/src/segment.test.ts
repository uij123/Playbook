import assert from "node:assert/strict";
import { test } from "node:test";
import { compileDraft } from "./segment.js";
import { RecEvent, RecMeta } from "./types.js";

const META: RecMeta = {
  started: "2026-01-01T00:00:00Z",
  screen: { w: 1440, h: 900 },
  launch_app: "Terminal",
  voice: false,
};

function key(t: number, chars: string, app = "TextEdit", extra: Partial<RecEvent> = {}): RecEvent {
  return { t, type: "key", chars, app, ...extra };
}

function draft(events: RecEvent[], transcript: { t0: number; t1: number; text: string }[] = []) {
  return compileDraft(events, { name: "t", meta: META, transcript }).playbook;
}

test("coalesces a run of printable keystrokes into one ui.type", () => {
  const pb = draft([
    { t: 100, type: "app_activate", app: "TextEdit" },
    key(200, "h"), key(260, "e"), key(320, "l"), key(380, "l"), key(440, "o"),
  ]);
  const types = pb.steps.filter((s) => s.do === "ui.type");
  assert.equal(types.length, 1);
  assert.equal(types[0].value, "hello");
});

test("backspace edits the buffer instead of emitting a keypress", () => {
  const pb = draft([
    key(100, "c"), key(160, "a"), key(220, "t"),
    { t: 280, type: "key", chars: "", key_code: 51, app: "TextEdit" },
    key(340, "b"),
  ]);
  const types = pb.steps.filter((s) => s.do === "ui.type");
  assert.equal(types.length, 1);
  assert.equal(types[0].value, "cab");
  assert.equal(pb.steps.filter((s) => s.do === "ui.key").length, 0);
});

test("modifier chord breaks the typing run and becomes ui.key", () => {
  const pb = draft([
    key(100, "h"), key(160, "i"),
    { t: 220, type: "key", chars: "s", key_code: 1, mods: ["cmd"], app: "TextEdit" },
  ]);
  const kinds = pb.steps.map((s) => `${s.do}:${s.value ?? ""}`);
  assert.deepEqual(kinds, ["ui.type:hi", "ui.key:cmd+s"]);
});

test("shift is folded into the typed character, not treated as a chord", () => {
  const pb = draft([
    { t: 100, type: "key", chars: "H", key_code: 4, mods: ["shift"], app: "TextEdit" },
    key(160, "i"),
  ]);
  assert.equal(pb.steps.length, 1);
  assert.equal(pb.steps[0].value, "Hi");
});

test("space is printable text mid-word but a named key inside a chord", () => {
  const typed = draft([key(100, "a"), key(160, " "), key(220, "b")]);
  assert.equal(typed.steps[0].value, "a b");

  const chord = draft([
    { t: 100, type: "key", chars: " ", key_code: 49, mods: ["cmd"], app: "TextEdit" },
  ]);
  assert.equal(chord.steps[0].do, "ui.key");
  assert.equal(chord.steps[0].value, "cmd+space");
});

test("secure keystrokes never surface as text and become a required input", () => {
  const pb = draft([
    { t: 100, type: "key", redacted: true, app: "TextEdit" },
    { t: 160, type: "key", redacted: true, app: "TextEdit" },
    { t: 220, type: "key", redacted: true, app: "TextEdit" },
  ]);
  const typeSteps = pb.steps.filter((s) => s.do === "ui.type");
  assert.equal(typeSteps.length, 1);
  assert.match(typeSteps[0].value ?? "", /^\{\{secure_input_\d+\}\}$/);
  assert.equal(pb.inputs.length, 1);
  assert.equal(pb.inputs[0].default, undefined, "secure input must not carry a demonstrated default");
  // Belt and suspenders: no recorded byte of the secret anywhere in the output.
  assert.equal(JSON.stringify(pb).includes('"redacted"'), false);
});

test("trims launch-app activity from head and tail", () => {
  const pb = draft([
    key(50, "\r", "Terminal"),           // launching the recorder
    { t: 100, type: "app_activate", app: "TextEdit" },
    key(200, "x"),
    { t: 300, type: "app_activate", app: "Terminal" },
    { t: 360, type: "key", chars: "", key_code: 8, mods: ["ctrl"], app: "Terminal" }, // Ctrl+C
  ]);
  const apps = pb.steps
    .map((s) => s.target?.app)
    .filter((a): a is string => !!a);
  assert.ok(!apps.includes("Terminal"), "no Terminal steps should survive trimming");
  assert.ok(pb.steps.some((s) => s.value === "x"));
});

test("a click on a text field seeds the following type's target", () => {
  const pb = draft([
    {
      t: 100, type: "click", button: "left", clicks: 1, x: 400, y: 300,
      app: "TextEdit", window_title: "Untitled",
      element: { role: "AXTextField", title: "Amount", frame: { x: 0, y: 0, w: 10, h: 10 } },
    },
    key(200, "9"), key(260, "9"),
  ]);
  const typeStep = pb.steps.find((s) => s.do === "ui.type");
  assert.ok(typeStep, "expected a ui.type step");
  assert.equal(typeStep!.target?.a11y?.role, "AXTextField");
  assert.equal(typeStep!.target?.a11y?.title, "Amount");
});

test("narration within a step's time window lands in notes", () => {
  const pb = draft(
    [{ t: 5000, type: "app_activate", app: "TextEdit" }],
    [{ t0: 4.5, t1: 5.2, text: "open the editor" }],
  );
  assert.match(pb.steps[0].notes ?? "", /open the editor/);
});
