// Node's own types ship in @types/node, which would mean a node_modules tree the
// rest of this skill deliberately does without; this declares only the surface used.

declare module "node:child_process" {
  export type SpawnSyncOptions = {
    cwd?: string;
    input?: string;
    encoding: "utf8";
    maxBuffer?: number;
    env?: Record<string, string | undefined>;
  };
  export type SpawnSyncReturn = {
    status: number | null;
    stdout: string | null;
    stderr: string | null;
  };
  export function spawnSync(
    command: string,
    args: string[],
    options: SpawnSyncOptions,
  ): SpawnSyncReturn;
}

declare module "node:fs" {
  const fs: {
    existsSync(path: string): boolean;
    readFileSync(path: string, encoding: "utf8"): string;
    writeFileSync(path: string, data: string, encoding: "utf8"): void;
    mkdirSync(path: string, options?: { recursive?: boolean }): void;
    mkdtempSync(prefix: string): string;
    rmSync(path: string, options?: { recursive?: boolean; force?: boolean }): void;
    chmodSync(path: string, mode: number): void;
  };
  export default fs;
}

declare module "node:os" {
  const os: { tmpdir(): string };
  export default os;
}

declare module "node:path" {
  const path: {
    join(...segments: string[]): string;
    resolve(...segments: string[]): string;
    dirname(target: string): string;
  };
  export default path;
}

declare module "node:url" {
  export function fileURLToPath(url: string): string;
}

declare module "node:test" {
  export function test(name: string, fn: () => void | Promise<void>): void;
}

declare module "node:assert/strict" {
  const assert: {
    (value: unknown, message?: string): void;
    equal(actual: unknown, expected: unknown, message?: string): void;
    notEqual(actual: unknown, expected: unknown, message?: string): void;
    deepEqual(actual: unknown, expected: unknown, message?: string): void;
    ok(value: unknown, message?: string): void;
    match(value: string, pattern: RegExp, message?: string): void;
    throws(fn: () => unknown, message?: string | RegExp): void;
  };
  export default assert;
}

declare const process: {
  argv: string[];
  env: Record<string, string | undefined>;
  cwd(): string;
  exit(code: number): never;
  stdout: { write(text: string): boolean };
  stdin: AsyncIterable<Uint8Array | string>;
};

declare const Buffer: {
  from(input: Uint8Array | string, encoding?: string): Uint8Array & { toString(encoding: string): string };
  concat(list: Uint8Array[]): Uint8Array & { toString(encoding: string): string };
};

type Buffer = Uint8Array & { toString(encoding: string): string };

interface ImportMeta {
  url: string;
  filename: string;
  dirname: string;
}
