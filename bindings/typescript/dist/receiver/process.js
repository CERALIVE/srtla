import { spawnSrtla, sendSignal, isRunning } from "../shared/process.js";
import { resolveExec } from "../shared/exec.js";
import { buildSrtlaRecArgs } from "./args.js";
const DEFAULT_BINARY = "srtla_rec";
const DEFAULT_SYSTEM_PATH = "/usr/bin/srtla_rec";
export function getSrtlaRecExec(execPath) {
    return resolveExec({
        execPath,
        binaryName: DEFAULT_BINARY,
        systemPath: DEFAULT_SYSTEM_PATH,
    });
}
export function spawnSrtlaRec(options) {
    return spawnSrtla({
        binaryName: DEFAULT_BINARY,
        systemPath: DEFAULT_SYSTEM_PATH,
        execPath: options.execPath,
        args: options.args,
        spawnOptions: options.spawnOptions,
    });
}
export async function sendSrtlaRecHup() {
    return sendSignal({ processName: DEFAULT_BINARY, signal: "-HUP" });
}
export async function sendSrtlaRecTerm() {
    return sendSignal({ processName: DEFAULT_BINARY });
}
export async function isSrtlaRecRunning() {
    return isRunning(DEFAULT_BINARY);
}
/**
 * Convenience: build args from options and spawn the process.
 */
export function buildAndSpawnSrtlaRec(options, spawnOptions) {
    const { args, options: parsed } = buildSrtlaRecArgs(options);
    return spawnSrtlaRec({ args, execPath: parsed.execPath, spawnOptions });
}
