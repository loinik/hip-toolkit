// Single-byte text encodings of the games' Lua scripts — a port of the
// desktop apps' detectSingleByteEncoding / -- @encoding: handling
// (Sources/Platform/macOS/HIPWrapper.mm), so web and desktop write and
// read the same files.

const CANDIDATES = ["windows-1251", "windows-1252", "windows-1250", "windows-1253", "windows-1254"] as const;
type SingleByte = (typeof CANDIDATES)[number];

const COMMENT = "-- @encoding:";

function score(str: string, enc: SingleByte): number {
  let cyrillic = 0, western = 0, polish = 0, greek = 0, turkish = 0, control = 0;
  const n = Math.min(str.length, 4000);
  for (let i = 0; i < n; i++) {
    const c = str.charCodeAt(i);
    if (c >= 0x0400 && c <= 0x04ff) cyrillic++;
    else if (c >= 0x0391 && c <= 0x03c9) greek++;
    else if ([0x105, 0x104, 0x119, 0x118, 0x15b, 0x15a, 0x142, 0x141, 0x17a, 0x179, 0x17c, 0x17b, 0x107, 0x106, 0x144, 0x143].includes(c)) polish++;
    else if ([0x11e, 0x11f, 0x130, 0x131, 0x15e, 0x15f].includes(c)) turkish++;
    else if (c >= 0x00c0 && c <= 0x024f) western++;
    else if (c < 0x20 && c !== 9 && c !== 10 && c !== 13) control++;
  }
  if (control > 2) return -1000;
  switch (enc) {
    case "windows-1251": return cyrillic * 4 - western - greek * 2 - polish * 3;
    case "windows-1252": return (western - polish) * 3 - cyrillic * 4 - greek * 2;
    case "windows-1250": return (western + polish * 4) * 2 - cyrillic * 4 - greek * 2;
    case "windows-1253": return greek * 4 - cyrillic * 2 - western;
    case "windows-1254": return western + turkish * 5 - cyrillic * 4 - greek * 2;
  }
}

/**
 * Game-encoded Lua source → UTF-8 text. Non-UTF-8 input gets the desktop
 * apps' `-- @encoding: <name>` first line so it can be packed back exactly.
 */
export function luaSourceToUTF8(bytes: Uint8Array): Uint8Array {
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return bytes; // ASCII or already UTF-8: nothing to annotate
  } catch { /* single-byte */ }

  let best: SingleByte = "windows-1251";
  let bestScore = -Infinity;
  let text = "";
  for (const enc of CANDIDATES) {
    const decoded = new TextDecoder(enc).decode(bytes);
    const s = score(decoded, enc);
    if (s > bestScore) { best = enc; bestScore = s; text = decoded; }
  }
  return new TextEncoder().encode(`${COMMENT} ${best}\n${text}`);
}

const reverseTables = new Map<string, Map<number, number>>();

function reverseTable(enc: SingleByte): Map<number, number> {
  let t = reverseTables.get(enc);
  if (!t) {
    t = new Map();
    const all = new Uint8Array(256).map((_, i) => i);
    const chars = new TextDecoder(enc).decode(all);
    for (let i = 0; i < 256; i++) t.set(chars.charCodeAt(i), i);
    reverseTables.set(enc, t);
  }
  return t;
}

/**
 * UTF-8 source carrying `-- @encoding: <name>` → the game's single-byte
 * bytes (comment line dropped), as the desktop apps do before compiling.
 * Anything else is returned unchanged.
 */
export function luaSourceForEngine(bytes: Uint8Array): Uint8Array {
  const head = new TextDecoder().decode(bytes.subarray(0, 64));
  if (!head.startsWith(COMMENT)) return bytes;
  const text = new TextDecoder().decode(bytes);
  const nl = text.indexOf("\n");
  const name = text.slice(COMMENT.length, nl < 0 ? undefined : nl).trim().toLowerCase();
  const enc = (name === "iso-8859-1" || name === "latin-1" ? "windows-1252" : name) as SingleByte;
  if (!CANDIDATES.includes(enc)) return bytes;
  const body = nl < 0 ? "" : text.slice(nl + 1);
  const table = reverseTable(enc);
  const out = new Uint8Array(body.length);
  let n = 0;
  for (const ch of body) out[n++] = table.get(ch.charCodeAt(0)) ?? 0x3f; // '?' like a lossy conversion
  return out.subarray(0, n);
}

export const isLuaBytecode = (b: Uint8Array) => b[0] === 0x1b && b[1] === 0x4c && b[2] === 0x75 && b[3] === 0x61;
