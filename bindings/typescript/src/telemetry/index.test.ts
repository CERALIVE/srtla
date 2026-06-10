import { afterEach, describe, expect, spyOn, test } from "bun:test";

import {
	SENDER_TELEMETRY_PATH_PREFIX,
	SENDER_TELEMETRY_STALE_MS,
	readTelemetry,
	senderTelemetryPath,
	telemetrySchema,
	watchTelemetry,
} from "./index.js";

// Task 18's exact emitted snapshot (srtla/tests/golden/telemetry_full.json),
// inlined so this package's tests stay self-contained — they never read a path
// above the binding's own root. This is the byte-for-byte producer output the
// reader must round-trip.
const GOLDEN_FULL_JSON = `{
  "last_updated_ms": 1749556546000,
  "connections": [
    {
      "conn_id": "0",
      "rtt_ms": 42,
      "nak_count": 3,
      "weight_percent": 85,
      "window": 8192,
      "in_flight": 100,
      "bitrate_bps": 2500000
    },
    {
      "conn_id": "1",
      "rtt_ms": 73,
      "nak_count": 11,
      "weight_percent": 55,
      "window": 4096,
      "in_flight": 240,
      "bitrate_bps": 1200000
    }
  ]
}
`;

// Bun-native temp file helpers (Bun.write/Bun.file only; this dir is grep-clean per ADR-001).
const created: Array<string> = [];

function tmpPath(): string {
	const p = `/tmp/srtla-tel-test-${Date.now()}-${Math.random().toString(36).slice(2)}.json`;
	created.push(p);
	return p;
}

async function writeSnapshot(content: string): Promise<string> {
	const p = tmpPath();
	await Bun.write(p, content);
	return p;
}

afterEach(async () => {
	for (const p of created.splice(0)) {
		try {
			// Optional-chained: tolerates Bun runtimes without BunFile.delete.
			await Bun.file(p).delete?.();
		} catch {
			// best-effort cleanup
		}
	}
});

function freshFull(): string {
	return JSON.stringify({
		last_updated_ms: Date.now(),
		connections: [
			{
				conn_id: "0",
				rtt_ms: 42,
				nak_count: 3,
				weight_percent: 85,
				window: 8192,
				in_flight: 100,
				bitrate_bps: 2500000,
			},
		],
	});
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

describe("telemetrySchema", () => {
	test("parses Task 18 golden bytes exactly (producer/consumer structure conformance)", () => {
		const parsed = telemetrySchema.safeParse(JSON.parse(GOLDEN_FULL_JSON));
		expect(parsed.success).toBe(true);
		if (!parsed.success) return;
		expect(parsed.data.connections).toHaveLength(2);
		expect(parsed.data.connections[0]).toEqual({
			conn_id: "0",
			rtt_ms: 42,
			nak_count: 3,
			weight_percent: 85,
			window: 8192,
			in_flight: 100,
			bitrate_bps: 2500000,
		});
	});

	test("rejects wrong field types (conn_id must be string, not number)", () => {
		const bad = {
			last_updated_ms: Date.now(),
			connections: [{ conn_id: 0, rtt_ms: 1, nak_count: 0, weight_percent: 100, window: 0, in_flight: 0, bitrate_bps: 0 }],
		};
		expect(telemetrySchema.safeParse(bad).success).toBe(false);
	});
});

describe("readTelemetry", () => {
	test("fresh valid snapshot parses to a correctly typed Telemetry object", async () => {
		const p = await writeSnapshot(freshFull());
		const t = await readTelemetry(p);

		expect(t).not.toBeNull();
		if (t === null) return;
		expect(typeof t.last_updated_ms).toBe("number");
		expect(Array.isArray(t.connections)).toBe(true);
		const c = t.connections[0]!;
		expect(typeof c.conn_id).toBe("string");
		expect(typeof c.rtt_ms).toBe("number");
		expect(typeof c.nak_count).toBe("number");
		expect(typeof c.weight_percent).toBe("number");
		expect(typeof c.window).toBe("number");
		expect(typeof c.in_flight).toBe("number");
		expect(typeof c.bitrate_bps).toBe("number");
		expect(c.conn_id).toBe("0");
		expect(c.bitrate_bps).toBe(2500000);
	});

	test("fresh empty snapshot returns the idle object (connections: []), not null", async () => {
		const p = await writeSnapshot(JSON.stringify({ last_updated_ms: Date.now(), connections: [] }));
		const t = await readTelemetry(p);
		expect(t).not.toBeNull();
		expect(t?.connections).toEqual([]);
	});

	test("invalid JSON returns null (no throw)", async () => {
		const p = await writeSnapshot("{ this is not json");
		expect(await readTelemetry(p)).toBeNull();
	});

	test("schema-invalid JSON (missing connections) returns null (no throw)", async () => {
		const p = await writeSnapshot(JSON.stringify({ last_updated_ms: Date.now() }));
		expect(await readTelemetry(p)).toBeNull();
	});

	test("absent file returns null (no throw)", async () => {
		const p = `/tmp/srtla-tel-absent-${Date.now()}-${Math.random().toString(36).slice(2)}.json`;
		expect(await readTelemetry(p)).toBeNull();
	});

	test("stale snapshot (last_updated_ms = now - 6000) returns null", async () => {
		const p = await writeSnapshot(
			JSON.stringify({ last_updated_ms: Date.now() - 6000, connections: [] }),
		);
		expect(await readTelemetry(p)).toBeNull();
	});

	test("staleness boundary: exactly 5000ms old is fresh, 5001ms old is stale", async () => {
		const FIXED = 1_800_000_000_000;
		const nowSpy = spyOn(Date, "now").mockReturnValue(FIXED);
		try {
			const atBoundary = await writeSnapshot(
				JSON.stringify({ last_updated_ms: FIXED - SENDER_TELEMETRY_STALE_MS, connections: [] }),
			);
			expect(await readTelemetry(atBoundary)).not.toBeNull();

			const justOver = await writeSnapshot(
				JSON.stringify({ last_updated_ms: FIXED - SENDER_TELEMETRY_STALE_MS - 1, connections: [] }),
			);
			expect(await readTelemetry(justOver)).toBeNull();
		} finally {
			nowSpy.mockRestore();
		}
	});

	test("round-trip: Task 18 emitted snapshot parses through readTelemetry with correct types", async () => {
		// Reuse the real producer output, refreshing only the timestamp so the
		// (otherwise byte-identical) connection records pass the staleness gate.
		const golden = JSON.parse(GOLDEN_FULL_JSON) as Record<string, unknown>;
		golden.last_updated_ms = Date.now();
		const p = await writeSnapshot(JSON.stringify(golden));

		const t = await readTelemetry(p);
		expect(t).not.toBeNull();
		if (t === null) return;
		expect(t.connections).toEqual([
			{ conn_id: "0", rtt_ms: 42, nak_count: 3, weight_percent: 85, window: 8192, in_flight: 100, bitrate_bps: 2500000 },
			{ conn_id: "1", rtt_ms: 73, nak_count: 11, weight_percent: 55, window: 4096, in_flight: 240, bitrate_bps: 1200000 },
		]);
	});
});

describe("watchTelemetry", () => {
	test("invokes cb on each poll", async () => {
		const p = await writeSnapshot(freshFull());
		let calls = 0;
		const handle = watchTelemetry(p, () => { calls++; }, { intervalMs: 20 });
		await sleep(90);
		handle.stop();
		// immediate fire + several interval ticks over ~90ms
		expect(calls).toBeGreaterThanOrEqual(3);
	});

	test("stop() halts further callbacks", async () => {
		const p = await writeSnapshot(freshFull());
		let calls = 0;
		const handle = watchTelemetry(p, () => { calls++; }, { intervalMs: 20 });
		await sleep(50);
		handle.stop();
		const afterStop = calls;
		await sleep(80);
		expect(calls).toBe(afterStop);
	});

	test("calls cb with null for an absent file", async () => {
		const p = `/tmp/srtla-tel-watch-absent-${Date.now()}-${Math.random().toString(36).slice(2)}.json`;
		const results: Array<unknown> = [];
		const handle = watchTelemetry(p, (t) => { results.push(t); }, { intervalMs: 20 });
		await sleep(50);
		handle.stop();
		expect(results.length).toBeGreaterThanOrEqual(1);
		expect(results.every((r) => r === null)).toBe(true);
	});
});

describe("senderTelemetryPath", () => {
	test("builds the ADR-001 well-known path for a listen port", () => {
		expect(senderTelemetryPath(5000)).toBe(`${SENDER_TELEMETRY_PATH_PREFIX}5000.json`);
		expect(senderTelemetryPath(9000)).toBe("/tmp/srtla-send-stats-9000.json");
	});
});
