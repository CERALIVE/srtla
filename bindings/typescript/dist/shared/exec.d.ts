export interface ExecResolveOptions {
    execPath?: string;
    binaryName: string;
    systemPath?: string;
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
export declare function resolveExec({ execPath, binaryName, systemPath, }: ExecResolveOptions): string;
