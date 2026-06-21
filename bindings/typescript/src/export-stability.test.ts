import { describe, expect, test } from "bun:test";

import * as pkg from "./index.js";

// The TS bindings public surface is FROZEN (srtla AGENTS.md, "existing exports
// frozen"). This smoke test pins the full runtime export set so any accidental
// rename/removal fails loudly, and confirms the additive v0.2.0 telemetry-path
// helper is reachable from the package root.
const FROZEN_RUNTIME_EXPORTS = [
	// sender
	"srtlaSendOptionsSchema",
	"buildSrtlaSendArgs",
	"getSrtlaSendExec",
	"spawnSrtlaSend",
	"sendSrtlaSendHup",
	"sendSrtlaSendTerm",
	"isSrtlaSendRunning",
	"buildAndSpawnSrtlaSend",
	// receiver
	"logLevelSchema",
	"srtlaRecOptionsSchema",
	"buildSrtlaRecArgs",
	"getSrtlaRecExec",
	"spawnSrtlaRec",
	"sendSrtlaRecHup",
	"sendSrtlaRecTerm",
	"isSrtlaRecRunning",
	"buildAndSpawnSrtlaRec",
	// shared ip-list
	"ipListSchema",
	"writeIpList",
	// telemetry
	"SENDER_TELEMETRY_STALE_MS",
	"SENDER_TELEMETRY_PATH_PREFIX",
	"senderTelemetryPath",
	"connectionTelemetrySchema",
	"telemetrySchema",
	"readTelemetry",
	"watchTelemetry",
] as const;

describe("package root export stability", () => {
	for (const name of FROZEN_RUNTIME_EXPORTS) {
		test(`exports ${name}`, () => {
			expect(name in pkg).toBe(true);
			expect((pkg as Record<string, unknown>)[name]).toBeDefined();
		});
	}

	test("senderTelemetryPath (additive) is callable from the root and yields the ADR-001 path", () => {
		expect(typeof pkg.senderTelemetryPath).toBe("function");
		expect(pkg.senderTelemetryPath(5000)).toBe("/tmp/srtla-send-stats-5000.json");
	});
});
