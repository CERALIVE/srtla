import type { SpawnOptions } from "node:child_process";

import { spawnSrtla, sendSignal, isRunning } from "../shared/process.js";
import { resolveExec } from "../shared/exec.js";
import { buildSrtlaRecArgs } from "./args.js";
import type { SrtlaRecOptionsInput } from "./types.js";

const DEFAULT_BINARY = "srtla_rec";
const DEFAULT_SYSTEM_PATH = "/usr/bin/srtla_rec";

export interface SpawnSrtlaRecOptions {
	args: Array<string>;
	execPath?: string;
	spawnOptions?: SpawnOptions;
}

export function getSrtlaRecExec(execPath?: string): string {
	return resolveExec({
		execPath,
		binaryName: DEFAULT_BINARY,
		systemPath: DEFAULT_SYSTEM_PATH,
	});
}

export function spawnSrtlaRec(options: SpawnSrtlaRecOptions) {
	return spawnSrtla({
		binaryName: DEFAULT_BINARY,
		systemPath: DEFAULT_SYSTEM_PATH,
		execPath: options.execPath,
		args: options.args,
		spawnOptions: options.spawnOptions,
	});
}

export async function sendSrtlaRecHup(): Promise<void> {
	return sendSignal({ processName: DEFAULT_BINARY, signal: "-HUP" });
}

export async function sendSrtlaRecTerm(): Promise<void> {
	return sendSignal({ processName: DEFAULT_BINARY });
}

export async function isSrtlaRecRunning(): Promise<boolean> {
	return isRunning(DEFAULT_BINARY);
}

/**
 * Convenience: build args from options and spawn the process.
 */
export function buildAndSpawnSrtlaRec(
	options: SrtlaRecOptionsInput,
	spawnOptions?: SpawnOptions,
) {
	const { args, options: parsed } = buildSrtlaRecArgs(options);
	return spawnSrtlaRec({ args, execPath: parsed.execPath, spawnOptions });
}
