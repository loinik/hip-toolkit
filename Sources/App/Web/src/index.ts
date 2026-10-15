// HIP Toolkit Web — public API.
//
//   const hip = new HIPToolkit();
//   const cif = await hip.encodeCIF(file, "png");
//   const his = await hip.encodeHIS(file);         // OGG / WAV / MP3
//   const dat = await hip.packCiftree("Game", files, { compileLua: true });
//   const { zip } = await hip.unpackCiftree(datFile);
//   const frame = await hip.decodeBIK(bikFile, { format: "png" });
//
// All work happens in a Web Worker running the same C++ Core as the desktop
// apps, compiled to WebAssembly. Files never leave the browser.

import type {
  BIKOptions, CIFKind, DecodedBIK, DecodedCIF, DecodeOptions, Envelope, FolderFile, HISFormat, InitMessage, PackOptions,
  Request, Response, UnpackedCiftree, UnpackOptions,
} from "./protocol";

export type {
  BIKImageFormat, BIKOptions, DecodedBIK, DecodeOptions, LuaState, CIFKind, CIFType, DecodedCIF, HISFormat, PackOptions, UnpackedCiftree, UnpackOptions,
} from "./protocol";

export class HIPError extends Error {
  override name = "HIPError";
}

/** Anything with bytes and a file name (File from <input>/drag-and-drop). */
export type Input = File | { name: string; bytes: Uint8Array | ArrayBuffer };

/** A file inside a folder to pack; `path` is relative to the folder root. */
export type FolderInput = { path: string; file: File } | { path: string; bytes: Uint8Array | ArrayBuffer };

export type ProgressCallback = (done: number, total: number) => void;

export interface HIPToolkitOptions {
  /** Supply your own worker (e.g. if your bundler needs a custom URL). */
  worker?: Worker;
}

type Done = Extract<Response, { ok: true }>;

export class HIPToolkit {
  private worker: Worker;
  private seq = 0;
  private pending = new Map<number, {
    resolve: (r: Done) => void;
    reject: (e: Error) => void;
    progress?: ProgressCallback;
  }>();

  constructor(options: HIPToolkitOptions = {}) {
    this.worker = options.worker ?? new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
    this.worker.onmessage = (e: MessageEvent<Response>) => {
      const r = e.data;
      const p = this.pending.get(r.id);
      if (!p) return;
      if ("progress" in r) {
        p.progress?.(...r.progress);
        return;
      }
      this.pending.delete(r.id);
      if (r.ok) p.resolve(r);
      else p.reject(new HIPError(r.error));
    };
    this.worker.onerror = (e) => {
      const err = new HIPError(e.message || "HIP worker failed");
      for (const p of this.pending.values()) p.reject(err);
      this.pending.clear();
    };
    const init: InitMessage = { init: true };
    this.worker.postMessage(init);
  }

  /** PNG / JPEG / Lua / XSheet / XSheet JSON → .cif */
  async encodeCIF(input: Input, kind: CIFKind): Promise<Uint8Array> {
    return (await this.call({ op: "encodeCIF", kind, ...(await read(input)) })).data;
  }

  /** .cif (modern or standalone legacy) → PNG, Lua (optionally decompiled) or XSheet JSON. */
  async decodeCIF(input: Input, options: DecodeOptions = {}): Promise<DecodedCIF> {
    const r = await this.call({ op: "decodeCIF", options, ...(await read(input)) });
    return {
      type: r.type ?? "unknown", ext: r.ext ?? "bin", width: r.width ?? 0, height: r.height ?? 0,
      data: r.data, lua: r.lua, warning: r.warning,
    };
  }

  /** OGG / WAV / MP3 → .his (format detected by file extension). */
  async encodeHIS(input: Input): Promise<Uint8Array> {
    return (await this.call({ op: "encodeHIS", ...(await read(input)) })).data;
  }

  /** .his → OGG (lossless unwrap), WAV or MP3. */
  async decodeHIS(input: Input, format: HISFormat = "ogg"): Promise<Uint8Array> {
    return (await this.call({ op: "decodeHIS", format, ...(await read(input)) })).data;
  }

  /**
   * Folder → Ciftree .dat. A folder unpacked from a legacy archive (it keeps
   * the `_meta` the original needs) is rebuilt in that legacy format.
   */
  async packCiftree(
    folderName: string,
    files: FolderInput[],
    options: PackOptions = {},
    onProgress?: ProgressCallback,
  ): Promise<{ data: Uint8Array; legacy: boolean }> {
    const list: FolderFile[] = await Promise.all(files.map(async (f) => ({
      path: f.path,
      bytes: "file" in f ? await f.file.arrayBuffer() : copy(f.bytes),
    })));
    const r = await this.call({ op: "packCiftree", name: folderName, files: list, options }, onProgress);
    return { data: r.data, legacy: !!r.legacy };
  }

  /** Ciftree .dat (modern or legacy) → its files, as a ZIP. */
  async unpackCiftree(input: Input, options: UnpackOptions = {}, onProgress?: ProgressCallback): Promise<UnpackedCiftree> {
    const r = await this.call({ op: "unpackCiftree", options, ...(await read(input)) }, onProgress);
    return {
      zip: r.data, fileCount: r.fileCount ?? 0, legacy: !!r.legacy,
      decompiled: r.decompiled ?? 0, decompileFailed: r.decompileFailed ?? [],
    };
  }

  /** Bink video (.bik) → PNG / JPEG: the first frame, or every frame as a ZIP. */
  async decodeBIK(input: Input, options: BIKOptions = {}, onProgress?: ProgressCallback): Promise<DecodedBIK> {
    const r = await this.call({ op: "decodeBIK", options, ...(await read(input)) }, onProgress);
    return {
      data: r.data, ext: r.ext ?? "png", frameCount: r.fileCount ?? 1,
      width: r.width ?? 0, height: r.height ?? 0, alpha: !!r.alpha,
    };
  }

  terminate(): void {
    this.worker.terminate();
    for (const p of this.pending.values()) p.reject(new HIPError("HIP worker terminated"));
    this.pending.clear();
  }

  private call(req: Request, progress?: ProgressCallback): Promise<Done> {
    const id = ++this.seq;
    const env: Envelope = { ...req, id };
    const transfer = "files" in req ? req.files.map((f) => f.bytes) : [req.bytes];
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, progress });
      this.worker.postMessage(env, transfer);
    });
  }
}

// Copy caller-owned buffers: they are transferred to the worker and would
// otherwise be detached on the caller's side.
function copy(bytes: Uint8Array | ArrayBuffer): ArrayBuffer {
  return (bytes instanceof ArrayBuffer ? bytes.slice(0) : bytes.slice().buffer) as ArrayBuffer;
}

async function read(input: Input): Promise<{ name: string; bytes: ArrayBuffer }> {
  if (typeof File !== "undefined" && input instanceof File) {
    return { name: input.name, bytes: await input.arrayBuffer() };
  }
  const { name, bytes } = input as { name: string; bytes: Uint8Array | ArrayBuffer };
  return { name, bytes: copy(bytes) };
}

/** Output file name for a conversion: "bg.png" → "bg.cif", "theme.his" → "theme.ogg". */
export function outputName(inputName: string, ext: string): string {
  const base = inputName.split(/[\\/]/).pop() ?? inputName;
  return base.replace(/\.[^.]*$/, "") + "." + ext.replace(/^\./, "");
}
