import { type ChildProcess, type SpawnOptions } from "node:child_process";
import { type ExecResolveOptions } from "./exec.js";
export interface SpawnSrtlaOptions extends Partial<ExecResolveOptions> {
    args: Array<string>;
    spawnOptions?: SpawnOptions;
}
export declare function spawnSrtla(options: SpawnSrtlaOptions & {
    binaryName: string;
}): ChildProcess;
export interface SignalOptions {
    processName: string;
    killall?: (args: Array<string>) => void | Promise<void>;
    signal?: string;
}
/**
 * Send a signal via killall; defaults to SIGTERM.
 * killall returns 1 when no processes match; treat as ok.
 */
export declare function sendSignal({ processName, killall, signal, }: SignalOptions): Promise<void>;
/**
 * Check if a process with the given name is running via pgrep.
 */
export declare function isRunning(processName: string): Promise<boolean>;
