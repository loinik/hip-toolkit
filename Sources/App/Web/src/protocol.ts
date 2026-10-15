// Messages between the main thread (HIPToolkit) and the WASM worker.

export type CIFKind = "png" | "ovl" | "lua" | "lua-compile" | "xsheet" | "xsheet-json";
export type HISFormat = "ogg" | "wav" | "mp3";
export type CIFType = "png" | "lua" | "ovl" | "xsheet" | "unknown";
export type BIKImageFormat = "png" | "jpeg";

export interface BIKOptions {
  format?: BIKImageFormat;
  /** Every frame (as a ZIP when there is more than one) or just the first. */
  allFrames?: boolean;
}

export interface PackOptions {
  compileLua?: boolean;
  capitalizeNames?: boolean;
  /** Encode PNGs as type-4 overlay CIFs (Sea of Darkness). */
  useOVL?: boolean;
}

export interface UnpackOptions {
  /** Decode each entry to PNG / Lua / JSON instead of keeping raw .cif files. */
  extractContents?: boolean;
  /** Turn compiled Lua back into source (needs extractContents). */
  decompileLua?: boolean;
}

export interface DecodeOptions {
  /** Turn compiled Lua back into source; on failure the bytecode is kept. */
  decompileLua?: boolean;
}

/** One file of a folder being packed; `path` is relative to the folder root. */
export interface FolderFile {
  path: string;
  bytes: ArrayBuffer;
}

export type Request =
  | { op: "encodeCIF"; name: string; bytes: ArrayBuffer; kind: CIFKind }
  | { op: "decodeCIF"; name: string; bytes: ArrayBuffer; options: DecodeOptions }
  | { op: "encodeHIS"; name: string; bytes: ArrayBuffer }
  | { op: "decodeHIS"; name: string; bytes: ArrayBuffer; format: HISFormat }
  | { op: "packCiftree"; name: string; files: FolderFile[]; options: PackOptions }
  | { op: "unpackCiftree"; name: string; bytes: ArrayBuffer; options: UnpackOptions }
  | { op: "decodeBIK"; name: string; bytes: ArrayBuffer; options: BIKOptions };

export type Envelope = Request & { id: number };

export interface DecodedCIF {
  type: CIFType;
  /** Extension of the decoded file: "png", "lua" or "json" (XSheet). */
  ext: string;
  width: number;
  height: number;
  data: Uint8Array;
  /** Lua only: "source", "bytecode" or "decompiled". */
  lua?: LuaState;
  /** Why decompilation failed (the bytecode was kept). */
  warning?: string;
}

export type LuaState = "source" | "bytecode" | "decompiled";

export interface DecodedBIK {
  /** One image, or a ZIP of `<stem>/<stem>_0001.png …` when several frames. */
  data: Uint8Array;
  /** "png" / "jpg" for a single frame, "zip" for a sequence. */
  ext: string;
  frameCount: number;
  width: number;
  height: number;
  /** The video has an alpha channel (conversations); JPEG output drops it. */
  alpha: boolean;
}

export interface UnpackedCiftree {
  /** The extracted files as a ZIP archive. */
  zip: Uint8Array;
  fileCount: number;
  /** Pre-Trail of the Twister archive: images are editable PNGs + repack metadata. */
  legacy: boolean;
  /** Scripts decompiled to source / left as bytecode because luadec failed. */
  decompiled: number;
  decompileFailed: string[];
}

export type Response =
  | {
      id: number; ok: true; data: Uint8Array;
      type?: CIFType; ext?: string; width?: number; height?: number;
      legacy?: boolean; fileCount?: number; alpha?: boolean;
      lua?: LuaState; warning?: string; decompiled?: number; decompileFailed?: string[];
    }
  | { id: number; ok: false; error: string }
  | { id: number; progress: [done: number, total: number] };

/** First message to the worker: starts loading the WASM Core early. */
export interface InitMessage {
  init: true;
}
