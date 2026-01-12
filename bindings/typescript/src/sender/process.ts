import type { SpawnOptions } from "node:child_process";

import { spawnSrtla, sendSignal, isRunning } from "../shared/process.js";
import { resolveExec } from "../shared/exec.js";
import { buildSrtlaSendArgs } from "./args.js";
import type { SrtlaSendOptionsInput } from "./types.js";

const DEFAULT_BINARY = "srtla_send";
const DEFAULT_SYSTEM_PATH = "/usr/bin/srtla_send";

export interface SpawnSrtlaSendOptions {
	args: Array<string>;
	execPath?: string;
	spawnOptions?: SpawnOptions;
}

export function getSrtlaSendExec(execPath?: string): string {
	return resolveExec({
		execPath,
		binaryName: DEFAULT_BINARY,
		systemPath: DEFAULT_SYSTEM_PATH,
	});
}

export function spawnSrtlaSend(options: SpawnSrtlaSendOptions) {
	return spawnSrtla({
		binaryName: DEFAULT_BINARY,
		systemPath: DEFAULT_SYSTEM_PATH,
		execPath: options.execPath,
		args: options.args,
		spawnOptions: options.spawnOptions,
	});
}

export async function sendSrtlaSendHup(): Promise<void> {
	return sendSignal({ processName: DEFAULT_BINARY, signal: "-HUP" });
}

export async function sendSrtlaSendTerm(): Promise<void> {
	return sendSignal({ processName: DEFAULT_BINARY });
}

export async function isSrtlaSendRunning(): Promise<boolean> {
	return isRunning(DEFAULT_BINARY);
}

/**
 * Convenience: build args from options and spawn the process.
 */
export function buildAndSpawnSrtlaSend(
	options: SrtlaSendOptionsInput,
	spawnOptions?: SpawnOptions,
) {
	const { args, options: parsed } = buildSrtlaSendArgs(options);
	return spawnSrtlaSend({ args, execPath: parsed.execPath, spawnOptions });
}
