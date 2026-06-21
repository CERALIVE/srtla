import type { SpawnOptions } from "node:child_process";

import { spawnSrtla, sendSignal, isRunning } from "../shared/process.js";
import { resolveExec } from "../shared/exec.js";
import { buildSrtlaSendArgs } from "./args.js";
import type { SrtlaSendOptionsInput } from "./types.js";

const DEFAULT_BINARY = "srtla_send";
const DEFAULT_SYSTEM_PATH = "/usr/bin/srtla_send";

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export interface SpawnSrtlaSendOptions {
	args: Array<string>;
	execPath?: string;
	spawnOptions?: SpawnOptions;
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export function getSrtlaSendExec(execPath?: string): string {
	return resolveExec({
		execPath,
		binaryName: DEFAULT_BINARY,
		systemPath: DEFAULT_SYSTEM_PATH,
	});
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export function spawnSrtlaSend(options: SpawnSrtlaSendOptions) {
	return spawnSrtla({
		binaryName: DEFAULT_BINARY,
		systemPath: DEFAULT_SYSTEM_PATH,
		execPath: options.execPath,
		args: options.args,
		spawnOptions: options.spawnOptions,
	});
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export async function sendSrtlaSendHup(): Promise<void> {
	return sendSignal({ processName: DEFAULT_BINARY, signal: "-HUP" });
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export async function sendSrtlaSendTerm(): Promise<void> {
	return sendSignal({ processName: DEFAULT_BINARY });
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export async function isSrtlaSendRunning(): Promise<boolean> {
	return isRunning(DEFAULT_BINARY);
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Convenience: build args from options and spawn the process.
 */
export function buildAndSpawnSrtlaSend(
	options: SrtlaSendOptionsInput,
	spawnOptions?: SpawnOptions,
) {
	const { args, options: parsed } = buildSrtlaSendArgs(options);
	return spawnSrtlaSend({ args, execPath: parsed.execPath, spawnOptions });
}
