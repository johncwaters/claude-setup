export const ALLOWED_TYPES = [
  "feat",
  "fix",
  "refactor",
  "chore",
  "docs",
  "test",
  "style",
  "perf",
  "build",
  "ci",
] as const;

export const TRAILER_LABELS = [
  "Constraint",
  "Rejected",
  "Directive",
  "Confidence",
  "Scope-risk",
  "Not-tested",
] as const;

export const REQUIRED_TRAILER_LABELS = ["Confidence", "Scope-risk"] as const;

const TRAILER_VALUES: Record<string, readonly string[]> = {
  Confidence: ["high", "medium", "low"],
  "Scope-risk": ["narrow", "moderate", "broad"],
};

const MAX_DESCRIPTION_LENGTH = 72;

// Numeric code points, not literal characters: this source stays ASCII so the
// repo format guard does not deny edits to the file that bans the dashes.
const EM_DASH = String.fromCodePoint(0x2014);
const EN_DASH = String.fromCodePoint(0x2013);

const EMOJI_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x1f300, 0x1faff],
  [0x2600, 0x26ff],
  [0x2700, 0x27bf],
  [0x1f1e6, 0x1f1ff],
  [0xfe00, 0xfe0f],
];

const HEADER_PATTERN = /^(?<type>[a-z]+)(?:\((?<scope>[^()]+)\))?: (?<description>.*)$/;

const TRAILER_PATTERN = /^(?<label>[A-Z][A-Za-z-]*): (?<value>.+)$/;

function isEmoji(codePoint: number): boolean {
  return EMOJI_RANGES.some(([low, high]) => codePoint >= low && codePoint <= high);
}

export function findBannedChars(text: string): string[] {
  const found = new Set<string>();
  if (text.includes(EM_DASH)) {
    found.add("em dash");
  }
  if (text.includes(EN_DASH)) {
    found.add("en dash");
  }
  for (const character of text) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (isEmoji(codePoint)) {
      found.add(`emoji ${JSON.stringify(character)}`);
    }
  }
  return [...found].sort();
}

function startsWithKnownTrailer(line: string): boolean {
  return TRAILER_LABELS.some((label) => line.startsWith(`${label}:`));
}

// A block is trailers as soon as one line names a known trailer, not only when
// every line parses: a malformed line there is an error, not prose.
function trailerBlockLines(lines: string[]): string[] {
  const lastBlankIndex = lines.lastIndexOf("");
  if (lastBlankIndex === -1) {
    return [];
  }
  const block = lines.slice(lastBlankIndex + 1);
  if (!block.some(startsWithKnownTrailer)) {
    return [];
  }
  return block;
}

function validateHeader(header: string, errors: string[]): void {
  const match = HEADER_PATTERN.exec(header);
  if (!match?.groups) {
    errors.push(
      "header must be `<type>(<scope>): <description>` or `<type>: <description>`, " +
        `got ${JSON.stringify(header)}`,
    );
    return;
  }
  const { type, description } = match.groups;
  if (!(ALLOWED_TYPES as readonly string[]).includes(type ?? "")) {
    errors.push(`type must be one of ${ALLOWED_TYPES.join(", ")}, got ${JSON.stringify(type)}`);
  }
  const text = description ?? "";
  if (text.trim() === "") {
    errors.push("description must not be empty");
  }
  if (text.length > MAX_DESCRIPTION_LENGTH) {
    errors.push(`description must be ${MAX_DESCRIPTION_LENGTH} characters or fewer`);
  }
  if (text.endsWith(".")) {
    errors.push("description must not end with a trailing period");
  }
}

function validateTrailers(block: string[], errors: string[]): void {
  if (block.length === 0) {
    return;
  }
  const values = new Map<string, string>();
  for (const line of block) {
    const match = TRAILER_PATTERN.exec(line);
    if (!match?.groups) {
      errors.push(`trailer line must be \`<Label>: <value>\`, got ${JSON.stringify(line)}`);
      continue;
    }
    const label = match.groups.label ?? "";
    const value = match.groups.value ?? "";
    if (!(TRAILER_LABELS as readonly string[]).includes(label)) {
      errors.push(
        `unknown trailer ${JSON.stringify(label)}; allowed trailers are ${TRAILER_LABELS.join(", ")}`,
      );
      continue;
    }
    values.set(label, value.trim());
  }
  for (const label of REQUIRED_TRAILER_LABELS) {
    if (!values.has(label)) {
      errors.push(`${label} trailer is required when the message carries trailers`);
    }
  }
  for (const [label, allowed] of Object.entries(TRAILER_VALUES)) {
    const value = values.get(label);
    if (value !== undefined && !allowed.includes(value)) {
      errors.push(`${label} must be one of ${allowed.join(", ")}, got ${JSON.stringify(value)}`);
    }
  }
}

export function validateMessage(message: string): string[] {
  const errors: string[] = [];
  const lines = message.replace(/\r\n/g, "\n").replace(/\n+$/, "").split("\n");

  if (message.trim() === "") {
    return ["message must not be empty"];
  }

  validateHeader(lines[0] ?? "", errors);

  if (lines.length > 1 && lines[1] !== "") {
    errors.push("the line after the header must be blank");
  }

  validateTrailers(trailerBlockLines(lines), errors);

  const banned = findBannedChars(message);
  if (banned.length > 0) {
    errors.push(`message contains banned characters: ${banned.join(", ")}`);
  }

  return errors;
}

export function normalizeMessage(message: string): string {
  return `${message.replace(/\r\n/g, "\n").replace(/\n+$/, "")}\n`;
}
