import { spawnSrtla, sendSignal, isRunning } from "../shared/process.js";
import { resolveExec } from "../shared/exec.js";
import { buildSrtlaSendArgs } from "./args.js";
const DEFAULT_BINARY = "srtla_send";
const DEFAULT_SYSTEM_PATH = "/usr/bin/srtla_send";
export function getSrtlaSendExec(execPath) {
    return resolveExec({
        execPath,
        binaryName: DEFAULT_BINARY,
        systemPath: DEFAULT_SYSTEM_PATH,
    });
}
export function spawnSrtlaSend(options) {
    return spawnSrtla({
        binaryName: DEFAULT_BINARY,
        systemPath: DEFAULT_SYSTEM_PATH,
        execPath: options.execPath,
        args: options.args,
        spawnOptions: options.spawnOptions,
    });
}
export async function sendSrtlaSendHup() {
    return sendSignal({ processName: DEFAULT_BINARY, signal: "-HUP" });
}
export async function sendSrtlaSendTerm() {
    return sendSignal({ processName: DEFAULT_BINARY });
}
export async function isSrtlaSendRunning() {
    return isRunning(DEFAULT_BINARY);
}
/**
 * Convenience: build args from options and spawn the process.
 */
export function buildAndSpawnSrtlaSend(options, spawnOptions) {
    const { args, options: parsed } = buildSrtlaSendArgs(options);
    return spawnSrtlaSend({ args, execPath: parsed.execPath, spawnOptions });
}
