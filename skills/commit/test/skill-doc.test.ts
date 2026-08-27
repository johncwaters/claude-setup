import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { ALLOWED_TYPES, REQUIRED_TRAILER_LABELS, TRAILER_LABELS } from "../lib/message.ts";
import { EXIT_CODES } from "../lib/outcome.ts";
import { SKILL_DIR } from "./helpers.ts";

const SKILL_DOC = fs.readFileSync(path.join(SKILL_DIR, "SKILL.md"), "utf8");

function outcomeTableRows(): Array<{ outcome: string; exit: number }> {
  return [...SKILL_DOC.matchAll(/^\| `([A-Z_]+)` \| (\d+) \|/gm)].map((match) => ({
    outcome: match[1] ?? "",
    exit: Number(match[2]),
  }));
}

test("the outcome table documents every outcome the scripts can emit", () => {
  const documented = new Set(outcomeTableRows().map((row) => row.outcome));
  const emittable = Object.keys(EXIT_CODES).filter((outcome) => outcome !== "READY");
  assert.deepEqual([...documented].sort(), emittable.sort());
});

test("the outcome table's exit codes match the ones the scripts exit with", () => {
  for (const { outcome, exit } of outcomeTableRows()) {
    assert.equal(exit, EXIT_CODES[outcome as keyof typeof EXIT_CODES], `${outcome} exit code`);
  }
});

test("the documented commit types are the ones validation accepts", () => {
  const documented = SKILL_DOC.match(/`type` is one of ([^.]+)\./);
  assert.ok(documented !== null, "SKILL.md must list the accepted types");
  const listed = (documented?.[1] ?? "").split(",").map((entry) => entry.trim());
  assert.deepEqual(listed, [...ALLOWED_TYPES]);
});

test("the documented trailers are the ones validation accepts", () => {
  for (const label of TRAILER_LABELS) {
    assert.ok(SKILL_DOC.includes(`${label}:`), `SKILL.md must show the ${label} trailer`);
  }
  for (const label of REQUIRED_TRAILER_LABELS) {
    assert.match(
      SKILL_DOC,
      new RegExp(`must carry \`?${label}\`?|\`${label}\` and`),
      `SKILL.md must say ${label} is required`,
    );
  }
});
