// Types for the Emscripten module emitted by Sources/Platform/Web (hip.mjs).

import type { CIFKind, CIFType, HISFormat } from "./protocol";

type Result =
  | { ok: true; data: Uint8Array; type?: CIFType; ext?: string; width?: number; height?: number; legacy?: boolean }
  | { ok: false; error: string };

type Progress = ((done: number, total: number) => void) | null;

export interface HIPModule {
  FS: {
    mkdir(path: string): void;
    rmdir(path: string): void;
    chdir(path: string): void;
    readdir(path: string): string[];
    readFile(path: string): Uint8Array;
    writeFile(path: string, data: Uint8Array): void;
    unlink(path: string): void;
    stat(path: string): { mode: number };
    isDir(mode: number): boolean;
    analyzePath(path: string): { exists: boolean };
  };
  encodeCIF(path: string, kind: CIFKind): Result;
  decodeCIF(path: string): Result;
  encodeHIS(path: string): Result;
  decodeHIS(path: string, format: HISFormat): Result;
  packCiftree(folder: string, compileLua: boolean, capitalizeNames: boolean, useOVL: boolean, onProgress: Progress): Result;
  unpackCiftree(datPath: string, outDir: string, extractContents: boolean, onProgress: Progress):
    | { ok: true; legacy: boolean }
    | { ok: false; error: string };
  decompileLua(path: string): Result;
  decodeBIK(path: string, format: "png" | "jpeg", allFrames: boolean, onProgress: Progress):
    | { ok: true; frames: Uint8Array[]; width: number; height: number; alpha: boolean }
    | { ok: false; error: string };
}

export default function createHIPModule(): Promise<HIPModule>;
