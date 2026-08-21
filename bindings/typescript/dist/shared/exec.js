import fs from 'node:fs';
import path from 'node:path';
/**
 * Try to find an executable in the system PATH.
 * Returns the full path if found, or undefined if not found.
 *
 * `Bun.which` replaces the previous `execSync('which …')`: it performs the same
 * PATH scan without a shell, so a binary name is never interpreted as a command
 * line. It returns null instead of throwing when nothing matches, which is why
 * the old try/catch is gone — this function is total. The existence re-check is
 * kept so a path that disappears between lookup and use still yields undefined.
 */
function findInPath(binaryName) {
    const resolved = Bun.which(binaryName);
    if (resolved && fs.existsSync(resolved)) {
        return resolved;
    }
    return undefined;
}
/**
 * Resolve an executable path given a binary name and optional override directory.
 * Resolution order:
 * 1. If execPath is a file, use it directly.
 * 2. If execPath is a directory, append binaryName.
 * 3. Try to find the binary in the system PATH.
 * 4. If the systemPath exists, use it.
 * 5. Fallback to the binaryName (let PATH decide at spawn time).
 */
export function resolveExec({ execPath, binaryName, systemPath }) {
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
