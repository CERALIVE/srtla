import type { SpawnOptions } from "node:child_process";
import type { SrtlaRecOptionsInput } from "./types.js";
export interface SpawnSrtlaRecOptions {
    args: Array<string>;
    execPath?: string;
    spawnOptions?: SpawnOptions;
}
export declare function getSrtlaRecExec(execPath?: string): string;
export declare function spawnSrtlaRec(options: SpawnSrtlaRecOptions): import("node:child_process").ChildProcess;
export declare function sendSrtlaRecHup(): Promise<void>;
export declare function sendSrtlaRecTerm(): Promise<void>;
export declare function isSrtlaRecRunning(): Promise<boolean>;
/**
 * Convenience: build args from options and spawn the process.
 */
export declare function buildAndSpawnSrtlaRec(options: SrtlaRecOptionsInput, spawnOptions?: SpawnOptions): import("node:child_process").ChildProcess;
