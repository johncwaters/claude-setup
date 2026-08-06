// Render a settings.json by deep-merging a profile overlay onto the shared base,
// then substituting the {{HOME}} token with the machine home directory.
// Usage: node render-settings.mjs <base.json> <overlay.json> <out.json> [homeOverride]
import fs from "node:fs";
import os from "node:os";

function fail(message) {
  process.stderr.write("render-settings: " + message + "\n");
  process.exit(1);
}

function readJson(path) {
  let raw;
  try {
    raw = fs.readFileSync(path, "utf8");
  } catch (readError) {
    return fail("cannot read " + path + ": " + readError.message);
  }
  try {
    return JSON.parse(raw);
  } catch (parseError) {
    return fail("cannot parse JSON in " + path + ": " + parseError.message);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// Plain objects merge recursively with base key order preserved and overlay-only
// keys appended. Arrays and scalars from the overlay replace the base value.
function deepMerge(base, overlay) {
  if (!isPlainObject(base) || !isPlainObject(overlay)) {
    return overlay;
  }
  const merged = {};
  for (const key of Object.keys(base)) {
    if (Object.prototype.hasOwnProperty.call(overlay, key)) {
      merged[key] = deepMerge(base[key], overlay[key]);
      continue;
    }
    merged[key] = base[key];
  }
  for (const key of Object.keys(overlay)) {
    if (Object.prototype.hasOwnProperty.call(merged, key)) {
      continue;
    }
    merged[key] = overlay[key];
  }
  return merged;
}

const [basePath, overlayPath, outPath, homeOverride] = process.argv.slice(2);
if (!basePath || !overlayPath || !outPath) {
  fail("usage: node render-settings.mjs <base.json> <overlay.json> <out.json> [homeOverride]");
}

const merged = deepMerge(readJson(basePath), readJson(overlayPath));
const home = (homeOverride || os.homedir()).replace(/\\/g, "/");
const text = (JSON.stringify(merged, null, 2) + "\n").split("{{HOME}}").join(home);

try {
  fs.writeFileSync(outPath, text, { encoding: "utf8" });
} catch (writeError) {
  fail("cannot write " + outPath + ": " + writeError.message);
}
