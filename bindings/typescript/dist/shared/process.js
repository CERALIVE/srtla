import { spawn } from "node:child_process";
import { resolveExec } from "./exec.js";
export function spawnSrtla(options) {
    const exec = resolveExec({
        execPath: options.execPath,
        binaryName: options.binaryName,
        systemPath: options.systemPath,
    });
    return spawn(exec, options.args, options.spawnOptions ?? {});
}
/**
 * Send a signal via killall; defaults to SIGTERM.
 * killall returns 1 when no processes match; treat as ok.
 */
export async function sendSignal({ processName, killall, signal, }) {
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
export async function isRunning(processName) {
    return new Promise((resolve) => {
        const proc = spawn("pgrep", ["-x", processName], { stdio: "ignore" });
        proc.on("close", (code) => resolve(code === 0));
        proc.on("error", () => resolve(false));
    });
}
