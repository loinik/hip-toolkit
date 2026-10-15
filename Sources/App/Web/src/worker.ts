/// <reference lib="webworker" />
// Runs the HIP Core (WebAssembly) off the main thread.
//
// Each job gets a fresh MEMFS directory; inputs are written under their own
// file names so Core sees the right extensions, and compiled Lua carries
// "@<name>" as its chunk name exactly like the desktop apps.

import createHIPModule from "./hip.mjs";
import type { HIPModule } from "./hip.mjs";
import type { Envelope, InitMessage, Response } from "./protocol";
import { zip, type ZipEntry } from "./zip";
import { isLuaBytecode, luaSourceForEngine, luaSourceToUTF8 } from "./encoding";

declare const self: DedicatedWorkerGlobalScope;

let modulePromise: Promise<HIPModule> | null = null;
let jobSeq = 0;

// The wasm binary is embedded in hip.mjs, so there is nothing to locate.
function load(): Promise<HIPModule> {
  modulePromise ??= createHIPModule();
  return modulePromise;
}

const isJPEG = (name: string, bytes: Uint8Array) =>
  /\.jpe?g$/i.test(name) || (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff);

// Core encodes PNG only (the macOS app converts JPEG through AppKit);
// here the browser decodes the JPEG and re-encodes it as PNG.
async function jpegToPNG(bytes: Uint8Array): Promise<Uint8Array> {
  const bitmap = await createImageBitmap(new Blob([bytes as Uint8Array<ArrayBuffer>]));
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0);
  bitmap.close();
  const png = await canvas.convertToBlob({ type: "image/png" });
  return new Uint8Array(await png.arrayBuffer());
}

const swapExt = (name: string, ext: string) => name.replace(/\.[^.]*$/, "") + "." + ext;
const stem = (name: string) => name.replace(/\.[^.]*$/, "");

/** A safe single path segment (no separators, no control bytes, not "." / ".."). */
function segment(name: string): string {
  const clean = name.replace(/[\x00-\x1f]/g, "_");
  return clean === "." || clean === ".." || clean === "" ? "_" : clean;
}

function baseName(name: string): string {
  return segment(name.split(/[\\/]/).pop() || "input");
}

function mkdirs(M: HIPModule, path: string) {
  let cur = "";
  for (const part of path.split("/").filter(Boolean)) {
    cur += "/" + part;
    if (!M.FS.analyzePath(cur).exists) M.FS.mkdir(cur);
  }
}

function rmrf(M: HIPModule, path: string) {
  if (!M.FS.analyzePath(path).exists) return;
  if (M.FS.isDir(M.FS.stat(path).mode)) {
    for (const e of M.FS.readdir(path)) if (e !== "." && e !== "..") rmrf(M, path + "/" + e);
    M.FS.rmdir(path);
  } else {
    M.FS.unlink(path);
  }
}

function collect(M: HIPModule, dir: string, prefix: string, out: ZipEntry[]) {
  for (const e of M.FS.readdir(dir).sort()) {
    if (e === "." || e === "..") continue;
    const full = dir + "/" + e;
    if (M.FS.isDir(M.FS.stat(full).mode)) collect(M, full, prefix + e + "/", out);
    else out.push({ path: prefix + e, data: M.FS.readFile(full) });
  }
}

/** Bytecode → UTF-8 source (desktop format), or the error message. */
function decompile(M: HIPModule, name: string, bytecode: Uint8Array): Uint8Array | string {
  M.FS.writeFile(name, bytecode);
  try {
    const r = M.decompileLua(name);
    return r.ok ? luaSourceToUTF8(r.data) : r.error;
  } finally {
    M.FS.unlink(name);
  }
}

function decodeCIF(M: HIPModule, name: string, decompileLua: boolean): Omit<Extract<Response, { ok: true }>, "id"> | { ok: false; error: string } {
  const r = M.decodeCIF(name);
  if (!r.ok || r.type !== "lua") return r;
  if (!isLuaBytecode(r.data)) return { ...r, lua: "source" };
  if (!decompileLua) return { ...r, lua: "bytecode" };
  const src = decompile(M, `${stem(name)}.lua`, r.data);
  return typeof src === "string" ? { ...r, lua: "bytecode", warning: src } : { ...r, data: src, lua: "decompiled" };
}

async function run(job: Envelope, progress: (done: number, total: number) => void): Promise<Response> {
  const M = await load();
  const dir = `/job${++jobSeq}`;
  M.FS.mkdir(dir);
  M.FS.chdir(dir);
  try {
    switch (job.op) {
      case "encodeCIF":
      case "decodeCIF":
      case "encodeHIS":
      case "decodeHIS": {
        let name = baseName(job.name);
        let bytes: Uint8Array = new Uint8Array(job.bytes);
        if (job.op === "encodeCIF" && (job.kind === "png" || job.kind === "ovl") && isJPEG(name, bytes)) {
          bytes = await jpegToPNG(bytes);
          name = swapExt(name, "png");
        }
        // Decompiled sources carry "-- @encoding:"; the engine wants its own bytes.
        if (job.op === "encodeCIF" && (job.kind === "lua" || job.kind === "lua-compile")) {
          bytes = luaSourceForEngine(bytes);
        }
        M.FS.writeFile(name, bytes);
        const r =
          job.op === "encodeCIF" ? M.encodeCIF(name, job.kind)
          : job.op === "decodeCIF" ? decodeCIF(M, name, !!job.options?.decompileLua)
          : job.op === "encodeHIS" ? M.encodeHIS(name)
          : M.decodeHIS(name, job.format);
        return { id: job.id, ...r };
      }

      case "packCiftree": {
        const root = baseName(job.name);
        for (const f of job.files) {
          const parts = f.path.split(/[\\/]/).filter(Boolean).map(segment);
          let file = parts.pop() ?? "file";
          let bytes: Uint8Array = new Uint8Array(f.bytes);
          // Core skips JPEGs when packing a folder; convert them like single files.
          if (/\.jpe?g$/i.test(file)) {
            bytes = await jpegToPNG(bytes);
            file = swapExt(file, "png");
          }
          const at = [root, ...parts].join("/");
          mkdirs(M, `${dir}/${at}`);
          M.FS.writeFile(`${at}/${file}`, bytes);
        }
        const o = job.options;
        const r = M.packCiftree(root, !!o.compileLua, !!o.capitalizeNames, !!o.useOVL, progress);
        return { id: job.id, ...r };
      }

      case "unpackCiftree": {
        const name = baseName(job.name);
        M.FS.writeFile(name, new Uint8Array(job.bytes));
        const outDir = `${dir}/out`;
        const r = M.unpackCiftree(name, outDir, job.options.extractContents !== false, progress);
        if (!r.ok) return { id: job.id, ...r };
        const entries: ZipEntry[] = [];
        collect(M, outDir, stem(name) + "/", entries);
        let decompiled = 0;
        const decompileFailed: string[] = [];
        if (job.options.decompileLua && job.options.extractContents !== false) {
          for (const e of entries) {
            if (!/\.lua$/i.test(e.path) || !isLuaBytecode(e.data)) continue;
            const src = decompile(M, e.path.split("/").pop()!, e.data);
            if (typeof src === "string") decompileFailed.push(e.path.split("/").pop()!);
            else { e.data = src; decompiled++; }
          }
        }
        return {
          id: job.id, ok: true, data: zip(entries), legacy: r.legacy, fileCount: entries.length,
          decompiled, decompileFailed,
        };
      }

      case "decodeBIK": {
        const name = baseName(job.name);
        M.FS.writeFile(name, new Uint8Array(job.bytes));
        const format = job.options.format ?? "png";
        const r = M.decodeBIK(name, format, !!job.options.allFrames, progress);
        if (!r.ok) return { id: job.id, ...r };
        const ext = format === "jpeg" ? "jpg" : "png";
        const meta = { width: r.width, height: r.height, alpha: r.alpha, fileCount: r.frames.length };
        if (r.frames.length === 1) return { id: job.id, ok: true, data: r.frames[0], ext, ...meta };
        // Same layout as the desktop apps: <stem>/<stem>_0001.png …
        const s = stem(name);
        const entries = r.frames.map((data, i) => ({ path: `${s}/${s}_${String(i + 1).padStart(4, "0")}.${ext}`, data }));
        return { id: job.id, ok: true, data: zip(entries), ext: "zip", ...meta };
      }
    }
  } finally {
    M.FS.chdir("/");
    rmrf(M, dir);
  }
}

self.onmessage = async (e: MessageEvent<Envelope | InitMessage>) => {
  const msg = e.data;
  if ("init" in msg) {
    void load(); // warm up while the user picks files
    return;
  }
  const progress = (done: number, total: number) => self.postMessage({ id: msg.id, progress: [done, total] });
  let res: Response;
  try {
    res = await run(msg, progress);
  } catch (err) {
    res = { id: msg.id, ok: false, error: err instanceof Error ? err.message : String(err) };
  }
  self.postMessage(res, "ok" in res && res.ok ? [res.data.buffer] : []);
};
