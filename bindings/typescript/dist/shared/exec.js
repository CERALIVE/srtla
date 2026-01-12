import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
/**
 * Try to find an executable in the system PATH using 'which' (Unix) or 'where' (Windows).
 * Returns the full path if found, or undefined if not found.
 */
function findInPath(binaryName) {
    try {
        const isWindows = process.platform === "win32";
        const command = isWindows ? `where ${binaryName}` : `which ${binaryName}`;
        const result = execSync(command, {
            encoding: "utf-8",
            stdio: ["pipe", "pipe", "pipe"],
        }).trim();
        // 'where' on Windows may return multiple lines, take the first
        const firstLine = result.split("\n")[0]?.trim();
        if (firstLine && fs.existsSync(firstLine)) {
            return firstLine;
        }
    }
    catch {
        // Command failed or binary not found in PATH
    }
    return undefined;
}
/**
 * Resolve an executable path given a binary name and optional override directory.
 * Resolution order:
 * 1. If execPath is a file, use it directly.
 * 2. If execPath is a directory, append binaryName.
 * 3. Try to find the binary in the system PATH using 'which'/'where'.
 * 4. If the systemPath exists, use it.
 * 5. Fallback to the binaryName (let PATH decide at spawn time).
 */
export function resolveExec({ execPath, binaryName, systemPath, }) {
    if (execPath) {
        if (fs.existsSync(execPath) && fs.statSync(execPath).isFile()) {
            return execPath;
        }
        const candidate = path.join(execPath, binaryName);
        if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
            return candidate;
        }
        return execPath.endsWith(binaryName) ? execPath : candidate;
    }
    // Try to auto-detect from system PATH
    const pathResult = findInPath(binaryName);
    if (pathResult) {
        return pathResult;
    }
    if (systemPath && fs.existsSync(systemPath) && fs.statSync(systemPath).isFile()) {
        return systemPath;
    }
    return binaryName;
}
