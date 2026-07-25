import { readFileSync, copyFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const hookInput = JSON.parse(readFileSync(0, "utf8").replace(/^﻿/, ""));
const editedPath = hookInput.tool_input?.file_path;
if (!editedPath) process.exit(0);

const sourcePath = join(homedir(), ".claude", "AGENTS.md");
if (resolve(editedPath).toLowerCase() !== sourcePath.toLowerCase()) process.exit(0);

const codexDir = join(homedir(), ".codex");
mkdirSync(codexDir, { recursive: true });
copyFileSync(sourcePath, join(codexDir, "AGENTS.md"));
