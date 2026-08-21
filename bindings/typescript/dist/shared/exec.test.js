import { describe, expect, test } from 'bun:test';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { resolveExec } from './exec.js';
import { spawnSrtla } from './process.js';
// `findInPath` moved from `execSync('which …')` to `Bun.which` (2026-08 adjudication
// of the node:child_process debt). `resolveExec` is on the hot path of every public
// spawn helper, so these tests pin the resolution ladder and the not-found fallthrough
// that the previous implementation produced.
const MISSING = 'srtla_binary_that_does_not_exist_xyz';
describe('resolveExec PATH lookup', () => {
    test('resolves a PATH binary to the same absolute path which(1) reports', () => {
        const viaWhich = execSync('which sh', {
            encoding: 'utf-8',
            stdio: ['pipe', 'pipe', 'pipe'],
        })
            .trim()
            .split('\n')[0]
            ?.trim();
        expect(resolveExec({ binaryName: 'sh' })).toBe(viaWhich);
    });
    test('a binary missing from PATH falls through to the bare name without throwing', () => {
        // Pre-migration contract: execSync threw on a `which` miss, the catch swallowed
        // it, and resolveExec returned the bare name so PATH decides at spawn time.
        // Bun.which returns null on the same input, which must fall through identically.
        expect(() => resolveExec({ binaryName: MISSING })).not.toThrow();
        expect(resolveExec({ binaryName: MISSING })).toBe(MISSING);
    });
    test('systemPath is preferred over the bare-name fallback when it exists', () => {
        expect(resolveExec({ binaryName: MISSING, systemPath: '/bin/sh' })).toBe('/bin/sh');
    });
    test('a systemPath that does not exist still falls through to the bare name', () => {
        expect(resolveExec({ binaryName: MISSING, systemPath: `/nonexistent/${MISSING}` })).toBe(MISSING);
    });
    test('an argument carrying shell metacharacters is never shell-executed', () => {
        // The old execSync path ran through `/bin/sh -c`, so `sh; touch <marker>` both
        // resolved AND executed the trailing command. Bun.which takes no shell, so the
        // name is looked up literally: no match, no side effect.
        const marker = path.join(os.tmpdir(), `srtla_exec_injection_${process.pid}_${Date.now()}`);
        expect(resolveExec({ binaryName: `sh; touch ${marker}` })).toBe(`sh; touch ${marker}`);
        expect(fs.existsSync(marker)).toBe(false);
    });
});
describe('resolveExec execPath override', () => {
    test('an execPath pointing at a file is used verbatim and PATH is never consulted', () => {
        expect(resolveExec({ execPath: '/bin/sh', binaryName: MISSING })).toBe('/bin/sh');
    });
    test('an execPath pointing at a directory is joined with the binary name', () => {
        expect(resolveExec({ execPath: '/usr/bin', binaryName: MISSING })).toBe(path.join('/usr/bin', MISSING));
    });
});
describe('spawn error path for an unresolvable binary', () => {
    test('emits a Node ENOENT Error, unchanged by the PATH-lookup migration', async () => {
        // resolveExec hands spawn the bare name (see fallthrough test above), so the
        // spawn failure surfaces through node:child_process exactly as it did before.
        const child = spawnSrtla({ binaryName: MISSING, args: [], spawnOptions: { stdio: 'ignore' } });
        const error = await new Promise((resolve) => {
            child.on('error', resolve);
        });
        expect(error).toBeInstanceOf(Error);
        expect(error.code).toBe('ENOENT');
        expect(error.syscall).toBe(`spawn ${MISSING}`);
    });
});
