// Minimal ZIP writer (stored, no compression) for handing an unpacked
// archive back as one download. Game assets are already compressed
// (PNG, OGG, bytecode), so deflate would buy little and cost a lot.

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export interface ZipEntry {
  path: string;
  data: Uint8Array;
}

export function zip(entries: ZipEntry[]): Uint8Array {
  const enc = new TextEncoder();
  const names = entries.map((e) => enc.encode(e.path));
  const crcs = entries.map((e) => crc32(e.data));

  let localSize = 0;
  entries.forEach((e, i) => (localSize += 30 + names[i].length + e.data.length));
  let centralSize = 0;
  names.forEach((n) => (centralSize += 46 + n.length));
  if (localSize + centralSize + 22 > 0xffffffff || entries.length > 0xffff) {
    throw new Error("Too much to put in one ZIP (over 4 GB or 65,535 files)");
  }

  const out = new Uint8Array(localSize + centralSize + 22);
  const v = new DataView(out.buffer);
  const offsets: number[] = [];
  let p = 0;

  // Fixed DOS timestamp (2000-01-01) keeps output deterministic.
  const TIME = 0, DATE = (20 << 9) | (1 << 5) | 1;
  const UTF8 = 1 << 11;

  entries.forEach((e, i) => {
    offsets.push(p);
    v.setUint32(p, 0x04034b50, true);
    v.setUint16(p + 4, 10, true);
    v.setUint16(p + 6, UTF8, true);
    v.setUint16(p + 8, 0, true);
    v.setUint16(p + 10, TIME, true);
    v.setUint16(p + 12, DATE, true);
    v.setUint32(p + 14, crcs[i], true);
    v.setUint32(p + 18, e.data.length, true);
    v.setUint32(p + 22, e.data.length, true);
    v.setUint16(p + 26, names[i].length, true);
    v.setUint16(p + 28, 0, true);
    out.set(names[i], p + 30);
    out.set(e.data, p + 30 + names[i].length);
    p += 30 + names[i].length + e.data.length;
  });

  const centralStart = p;
  entries.forEach((e, i) => {
    v.setUint32(p, 0x02014b50, true);
    v.setUint16(p + 4, 20, true);
    v.setUint16(p + 6, 10, true);
    v.setUint16(p + 8, UTF8, true);
    v.setUint16(p + 10, 0, true);
    v.setUint16(p + 12, TIME, true);
    v.setUint16(p + 14, DATE, true);
    v.setUint32(p + 16, crcs[i], true);
    v.setUint32(p + 20, e.data.length, true);
    v.setUint32(p + 24, e.data.length, true);
    v.setUint16(p + 28, names[i].length, true);
    // extra, comment, disk, internal attrs, external attrs: all zero
    v.setUint32(p + 42, offsets[i], true);
    out.set(names[i], p + 46);
    p += 46 + names[i].length;
  });

  v.setUint32(p, 0x06054b50, true);
  v.setUint16(p + 8, entries.length, true);
  v.setUint16(p + 10, entries.length, true);
  v.setUint32(p + 12, p - centralStart, true);
  v.setUint32(p + 16, centralStart, true);
  return out;
}
