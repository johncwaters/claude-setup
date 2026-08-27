import assert from "node:assert/strict";
import { test } from "node:test";
import { findBannedChars, normalizeMessage, validateMessage } from "../lib/message.ts";

const EM_DASH = String.fromCodePoint(0x2014);
const EN_DASH = String.fromCodePoint(0x2013);
const SPARKLES = String.fromCodePoint(0x2728);

const VALID = ["feat(commit): land the change", "", "Body paragraph.", "", "Confidence: high", "Scope-risk: narrow"].join(
  "\n",
);

test("a conventional message with required trailers passes", () => {
  assert.deepEqual(validateMessage(VALID), []);
});

test("a trivial message with no trailers passes", () => {
  assert.deepEqual(validateMessage("chore: bump version to 1.2.3\n\nNo logic change.\n"), []);
});

test("a header-only message passes", () => {
  assert.deepEqual(validateMessage("docs: fix a typo"), []);
});

test("an unknown type is rejected", () => {
  assert.match(validateMessage("wibble: do a thing")[0] ?? "", /type must be one of/);
});

test("a malformed header is rejected", () => {
  assert.match(validateMessage("did some stuff")[0] ?? "", /header must be/);
});

test("a description over 72 characters is rejected", () => {
  const errors = validateMessage(`feat: ${"x".repeat(73)}`);
  assert.ok(errors.some((error) => error.includes("72 characters or fewer")));
});

test("a trailing period in the description is rejected", () => {
  const errors = validateMessage("feat: add a thing.");
  assert.ok(errors.some((error) => error.includes("trailing period")));
});

test("a missing blank line after the header is rejected", () => {
  const errors = validateMessage("feat: add a thing\nbody with no blank line");
  assert.ok(errors.some((error) => error.includes("must be blank")));
});

test("trailers without Confidence and Scope-risk are rejected", () => {
  const errors = validateMessage("feat: add a thing\n\nBody.\n\nConstraint: keep the ABI stable");
  assert.ok(errors.some((error) => error.includes("Confidence trailer is required")));
  assert.ok(errors.some((error) => error.includes("Scope-risk trailer is required")));
});

test("an unknown trailer label is rejected", () => {
  const errors = validateMessage(
    "feat: add a thing\n\nBody.\n\nConfidence: high\nScope-risk: narrow\nReviewed-by: nobody",
  );
  assert.ok(errors.some((error) => error.includes("unknown trailer")));
});

test("an out-of-range trailer value is rejected", () => {
  const errors = validateMessage("feat: add a thing\n\nBody.\n\nConfidence: certain\nScope-risk: narrow");
  assert.ok(errors.some((error) => error.includes("Confidence must be one of")));
});

test("a body line shaped like a trailer does not become the trailer block", () => {
  const message = "feat: add a thing\n\nNote: this reads like a trailer but is prose";
  assert.deepEqual(validateMessage(message), []);
});

test("an em dash is rejected", () => {
  const errors = validateMessage(`feat: add a thing\n\nBody ${EM_DASH} more body.`);
  assert.ok(errors.some((error) => error.includes("em dash")));
});

test("an en dash is rejected", () => {
  const errors = validateMessage(`feat: add a thing\n\nBody ${EN_DASH} more body.`);
  assert.ok(errors.some((error) => error.includes("en dash")));
});

test("an emoji is rejected", () => {
  const errors = validateMessage(`feat: add a thing ${SPARKLES}`);
  assert.ok(errors.some((error) => error.includes("emoji")));
});

test("an empty message is rejected", () => {
  assert.deepEqual(validateMessage("   \n"), ["message must not be empty"]);
});

test("findBannedChars reports each banned class once, sorted", () => {
  assert.deepEqual(findBannedChars(`a ${EM_DASH} b ${EM_DASH} c ${EN_DASH}`), ["em dash", "en dash"]);
});

test("normalizeMessage collapses trailing newlines to exactly one", () => {
  assert.equal(normalizeMessage("feat: x\r\n\r\nbody\n\n\n"), "feat: x\n\nbody\n");
});

test("a malformed line inside a trailer block is an error, not prose", () => {
  const errors = validateMessage("feat: add a thing\n\nBody.\n\nConfidence: high\nScope-risk:");
  assert.ok(errors.some((error) => error.includes("trailer line must be")));
  assert.ok(errors.some((error) => error.includes("Scope-risk trailer is required")));
});

test("a misspelled trailer beside a real one is still rejected", () => {
  const errors = validateMessage(
    "feat: add a thing\n\nBody.\n\nConfidence: high\nScope-risk: narrow\nConfidance: high",
  );
  assert.ok(errors.some((error) => error.includes("unknown trailer")));
});
