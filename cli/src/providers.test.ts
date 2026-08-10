import assert from "node:assert/strict";
import { test } from "node:test";
import {
  AnthropicProvider,
  NullProvider,
  OpenAICompatibleProvider,
  buildRefinePrompt,
  parseRefinement,
  selectProvider,
} from "./providers.js";
import { Playbook } from "./types.js";

const VALID: Playbook = {
  playbook: "x",
  version: "0.1.0",
  inputs: [],
  credentials: [],
  steps: [{ id: "s1", intent: "Do", do: "ui.key", value: "cmd+s" }],
};

test("parseRefinement accepts a clean JSON object", () => {
  const r = parseRefinement(JSON.stringify(VALID));
  assert.ok(r.ok && r.playbook.steps.length === 1);
});

test("parseRefinement strips ```json fences the model may add", () => {
  const r = parseRefinement("```json\n" + JSON.stringify(VALID) + "\n```");
  assert.ok(r.ok && r.playbook.playbook === "x");
});

test("parseRefinement rejects schema-invalid output with an error", () => {
  const r = parseRefinement(JSON.stringify({ playbook: "x" })); // missing required fields
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.error.length > 0);
});

test("parseRefinement rejects non-JSON", () => {
  const r = parseRefinement("I cannot help with that.");
  assert.equal(r.ok, false);
});

test("buildRefinePrompt embeds the draft and narration", () => {
  const p = buildRefinePrompt(VALID, { narration: "changes every month", appNames: ["TextEdit"] });
  assert.match(p, /changes every month/);
  assert.match(p, /TextEdit/);
  assert.match(p, /"playbook": "x"/);
});

test("selectProvider honors PLAYBOOKS_PROVIDER and env, and --no-llm", () => {
  const save = { ...process.env };
  try {
    for (const k of ["PLAYBOOKS_PROVIDER", "PLAYBOOKS_OPENAI_BASE_URL", "OPENAI_BASE_URL", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]) {
      delete process.env[k];
    }

    assert.ok(selectProvider(undefined, true) instanceof NullProvider, "--no-llm forces null");
    assert.ok(selectProvider() instanceof NullProvider, "no creds → null");

    process.env.PLAYBOOKS_OPENAI_BASE_URL = "http://localhost:11434/v1";
    assert.ok(selectProvider() instanceof OpenAICompatibleProvider, "openai base url → openai");

    delete process.env.PLAYBOOKS_OPENAI_BASE_URL;
    process.env.ANTHROPIC_API_KEY = "sk-test";
    assert.ok(selectProvider() instanceof AnthropicProvider, "anthropic key → anthropic");

    process.env.PLAYBOOKS_PROVIDER = "none";
    assert.ok(selectProvider() instanceof NullProvider, "explicit none wins");

    process.env.PLAYBOOKS_PROVIDER = "openai";
    assert.ok(selectProvider() instanceof OpenAICompatibleProvider, "explicit openai wins");
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in save)) delete process.env[k];
    Object.assign(process.env, save);
  }
});

test("OpenAICompatibleProvider names itself by model and host", () => {
  const save = process.env.PLAYBOOKS_OPENAI_BASE_URL;
  process.env.PLAYBOOKS_OPENAI_BASE_URL = "http://localhost:11434/v1";
  const p = new OpenAICompatibleProvider("llama3.1");
  assert.match(p.name, /llama3\.1/);
  assert.match(p.name, /localhost/);
  if (save === undefined) delete process.env.PLAYBOOKS_OPENAI_BASE_URL;
  else process.env.PLAYBOOKS_OPENAI_BASE_URL = save;
});
