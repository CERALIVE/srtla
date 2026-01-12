import fs from "node:fs";
import path from "node:path";
/**
 * Resolve an executable path given a binary name and optional override directory.
 * Resolution order:
 * 1. If execPath is a file, use it directly.
 * 2. If execPath is a directory, append binaryName.
 * 3. If the systemPath exists, use it.
 * 4. Fallback to the binaryName (let PATH decide).
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
    if (systemPath && fs.existsSync(systemPath) && fs.statSync(systemPath).isFile()) {
        return systemPath;
    }
    return binaryName;
}
