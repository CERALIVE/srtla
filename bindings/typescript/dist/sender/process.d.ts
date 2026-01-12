import type { SpawnOptions } from "node:child_process";
import type { SrtlaSendOptionsInput } from "./types.js";
export interface SpawnSrtlaSendOptions {
    args: Array<string>;
    execPath?: string;
    spawnOptions?: SpawnOptions;
}
export declare function getSrtlaSendExec(execPath?: string): string;
export declare function spawnSrtlaSend(options: SpawnSrtlaSendOptions): import("node:child_process").ChildProcess;
export declare function sendSrtlaSendHup(): Promise<void>;
export declare function sendSrtlaSendTerm(): Promise<void>;
export declare function isSrtlaSendRunning(): Promise<boolean>;
/**
 * Convenience: build args from options and spawn the process.
 */
export declare function buildAndSpawnSrtlaSend(options: SrtlaSendOptionsInput, spawnOptions?: SpawnOptions): import("node:child_process").ChildProcess;
