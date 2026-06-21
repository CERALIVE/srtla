import { afterEach, describe, expect, spyOn, test } from "bun:test";

import { readTelemetry } from "./index.js";

// The 5000 ms staleness window is asserted with HARDCODED snapshot ages — never
// derived from SENDER_TELEMETRY_STALE_MS — so this test is falsifiable: lowering
// the constant must turn the edge snapshot stale and fail the test (proving it
// pins the boundary rather than tautologically tracking it). Reader semantics:
// stale iff `now - last_updated_ms > 5000`, so age 5000 is inclusive-fresh.
const FIXED_NOW = 1_800_000_000_000;
const created: Array<string> = [];

async function snapshotAged(ageMs: number): Promise<string> {
	const p = `/tmp/srtla-stale-bound-${Date.now()}-${Math.random().toString(36).slice(2)}.json`;
	created.push(p);
	await Bun.write(p, JSON.stringify({ last_updated_ms: FIXED_NOW - ageMs, connections: [] }));
	return p;
}

afterEach(async () => {
	for (const p of created.splice(0)) {
		try {
			await Bun.file(p).delete?.();
		} catch {
			// best-effort cleanup
		}
	}
});

describe("readTelemetry staleness boundary (Todo 18)", () => {
	test("snapshot 4999 ms old is fresh", async () => {
		const nowSpy = spyOn(Date, "now").mockReturnValue(FIXED_NOW);
		try {
			expect(await readTelemetry(await snapshotAged(4999))).not.toBeNull();
		} finally {
			nowSpy.mockRestore();
		}
	});

	test("snapshot 5000 ms old is fresh, 5001 ms old is stale (falsifies the 5000 ms threshold)", async () => {
		const nowSpy = spyOn(Date, "now").mockReturnValue(FIXED_NOW);
		try {
			expect(await readTelemetry(await snapshotAged(5000))).not.toBeNull();
			expect(await readTelemetry(await snapshotAged(5001))).toBeNull();
		} finally {
			nowSpy.mockRestore();
		}
	});
});
