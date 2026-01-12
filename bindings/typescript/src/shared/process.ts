import { spawn, type ChildProcess, type SpawnOptions } from "node:child_process";

import { resolveExec, type ExecResolveOptions } from "./exec.js";

export interface SpawnSrtlaOptions extends Partial<ExecResolveOptions> {
	args: Array<string>;
	spawnOptions?: SpawnOptions;
}

export function spawnSrtla(
	options: SpawnSrtlaOptions & { binaryName: string },
): ChildProcess {
	const exec = resolveExec({
		execPath: options.execPath,
		binaryName: options.binaryName,
		systemPath: options.systemPath,
	});
	return spawn(exec, options.args, options.spawnOptions ?? {});
}

export interface SignalOptions {
	processName: string;
	killall?: (args: Array<string>) => void | Promise<void>;
	signal?: string;
}

/**
 * Send a signal via killall; defaults to SIGTERM.
 * killall returns 1 when no processes match; treat as ok.
 */
export async function sendSignal({
	processName,
	killall,
	signal,
}: SignalOptions): Promise<void> {
	const args = signal ? [signal, processName] : [processName];
	if (killall) {
		await killall(args);
		return;
	}

	return new Promise((resolve, reject) => {
		const proc = spawn("killall", args, {
			stdio: "ignore",
		});
		proc.on("close", () => resolve());
		proc.on("error", reject);
	});
}

/**
 * Check if a process with the given name is running via pgrep.
 */
export async function isRunning(processName: string): Promise<boolean> {
	return new Promise((resolve) => {
		const proc = spawn("pgrep", ["-x", processName], { stdio: "ignore" });
		proc.on("close", (code) => resolve(code === 0));
		proc.on("error", () => resolve(false));
	});
}
