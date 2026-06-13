import type { SpawnOptions } from "node:child_process";
import type { SrtlaSendOptionsInput } from "./types.js";
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export interface SpawnSrtlaSendOptions {
    args: Array<string>;
    execPath?: string;
    spawnOptions?: SpawnOptions;
}
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export declare function getSrtlaSendExec(execPath?: string): string;
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export declare function spawnSrtlaSend(options: SpawnSrtlaSendOptions): import("node:child_process").ChildProcess;
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export declare function sendSrtlaSendHup(): Promise<void>;
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export declare function sendSrtlaSendTerm(): Promise<void>;
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export declare function isSrtlaSendRunning(): Promise<boolean>;
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Convenience: build args from options and spawn the process.
 */
export declare function buildAndSpawnSrtlaSend(options: SrtlaSendOptionsInput, spawnOptions?: SpawnOptions): import("node:child_process").ChildProcess;
