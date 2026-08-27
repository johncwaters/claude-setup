export const EXIT_CODES = {
  READY: 0,
  COMMITTED: 0,
  NOT_A_REPO: 10,
  DETACHED_HEAD: 11,
  OPERATION_IN_PROGRESS: 12,
  NOTHING_TO_COMMIT: 13,
  MESSAGE_INVALID: 20,
  HOOK_FAILED: 21,
  PUSH_FAILED: 22,
  PROMOTE_CONFLICT: 23,
  PROMOTE_FAILED: 24,
} as const;

export type OutcomeName = keyof typeof EXIT_CODES;

type FieldValueByKind = {
  string: string;
  boolean: boolean;
  stringList: string[];
  object: Record<string, unknown>;
};

type FieldKind = keyof FieldValueByKind;

type FieldSpec = { kind: FieldKind; isRequired: boolean };

type FieldSpecs = Record<string, FieldSpec>;

type RequiredFieldNames<Specs extends FieldSpecs> = {
  [Name in keyof Specs]: Specs[Name]["isRequired"] extends true ? Name : never;
}[keyof Specs];

type OptionalFieldNames<Specs extends FieldSpecs> = {
  [Name in keyof Specs]: Specs[Name]["isRequired"] extends true ? never : Name;
}[keyof Specs];

type Payload<Specs extends FieldSpecs> = {
  [Name in RequiredFieldNames<Specs>]: FieldValueByKind[Specs[Name]["kind"]];
} & {
  [Name in OptionalFieldNames<Specs>]?: FieldValueByKind[Specs[Name]["kind"]];
} & { warnings?: string[] };

export type Result = { outcome: OutcomeName } & Record<string, unknown>;

export function required<Kind extends FieldKind>(kind: Kind) {
  return { kind, isRequired: true } as const;
}

export function optional<Kind extends FieldKind>(kind: Kind) {
  return { kind, isRequired: false } as const;
}

function matchesKind(kind: FieldKind, value: unknown): boolean {
  if (kind === "string") {
    return typeof value === "string";
  }
  if (kind === "boolean") {
    return typeof value === "boolean";
  }
  if (kind === "stringList") {
    return Array.isArray(value) && value.every((entry) => typeof entry === "string");
  }
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function defineOutcome<const Specs extends FieldSpecs>(outcome: OutcomeName, specs: Specs) {
  return (payload: Payload<Specs>): Result => {
    const fields = payload as Record<string, unknown>;
    for (const [name, value] of Object.entries(fields)) {
      if (name === "warnings") {
        if (!matchesKind("stringList", value)) {
          throw new Error(`${outcome} field warnings must be a stringList`);
        }
        continue;
      }
      const spec = specs[name];
      if (!spec) {
        throw new Error(`${outcome} has no field named ${name}`);
      }
      if (!matchesKind(spec.kind, value)) {
        throw new Error(`${outcome} field ${name} must be a ${spec.kind}`);
      }
    }
    for (const [name, spec] of Object.entries(specs)) {
      if (spec.isRequired && !(name in fields)) {
        throw new Error(`${outcome} is missing required field ${name}`);
      }
    }
    const warnings = payload.warnings ?? [];
    const result: Result = { outcome, ...fields };
    if (warnings.length === 0) {
      delete result.warnings;
    }
    return result;
  };
}

export const ready = defineOutcome("READY", {
  branch: required("string"),
  branchAllowed: required("boolean"),
  changed: required("stringList"),
  untracked: required("stringList"),
  profile: optional("string"),
  policy: optional("object"),
});

export const committed = defineOutcome("COMMITTED", {
  commit: required("string"),
  pushed: required("boolean"),
  promoted: required("stringList"),
});

export const messageValid = defineOutcome("READY", {});

export const notARepo = defineOutcome("NOT_A_REPO", {});

export const detachedHead = defineOutcome("DETACHED_HEAD", {});

export const operationInProgress = defineOutcome("OPERATION_IN_PROGRESS", {
  operation: required("string"),
});

export const nothingToCommit = defineOutcome("NOTHING_TO_COMMIT", {
  pushed: optional("boolean"),
  promoted: optional("stringList"),
});

export const messageInvalid = defineOutcome("MESSAGE_INVALID", {
  errors: required("stringList"),
});

export const hookFailed = defineOutcome("HOOK_FAILED", {});

export const pushFailed = defineOutcome("PUSH_FAILED", {
  commit: optional("string"),
  pushed: required("boolean"),
  promoted: required("stringList"),
});

export const promoteConflict = defineOutcome("PROMOTE_CONFLICT", {
  commit: optional("string"),
  pushed: required("boolean"),
  promoted: required("stringList"),
  conflicts: required("stringList"),
});

export const promoteFailed = defineOutcome("PROMOTE_FAILED", {
  commit: optional("string"),
  pushed: required("boolean"),
  promoted: required("stringList"),
});

export function emit(result: Result): never {
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exit(EXIT_CODES[result.outcome]);
}
