import { describe, expect, test } from "bun:test";

import { buildSrtlaSendArgs } from "../sender/args.js";
import type { SrtlaSendOptionsInput } from "../sender/types.js";

/**
 * Additivity freeze for the ADR-001 sender changes.
 *
 * The telemetry work added `statsFile` / `--stats-file` to the sender option
 * schema and arg builder. This snapshot pins the arg output for five
 * representative *legacy* configs (none using `statsFile`) so any change that
 * perturbs the existing arg shape — order, defaults, flag emission — fails
 * loudly. Pre-change output must equal post-change output for these configs.
 */
const LEGACY_CONFIGS: ReadonlyArray<{ name: string; input: SrtlaSendOptionsInput; expected: Array<string> }> = [
	{
		name: "minimal (host+port, all defaults)",
		input: { srtlaHost: "relay.example.com", srtlaPort: 8890 },
		expected: ["5000", "relay.example.com", "8890", "/tmp/srtla_ips"],
	},
	{
		name: "custom listen port + ips file",
		input: { listenPort: 9000, srtlaHost: "relay.example.com", srtlaPort: 8890, ipsFile: "/tmp/custom_ips" },
		expected: ["9000", "relay.example.com", "8890", "/tmp/custom_ips"],
	},
	{
		name: "verbose enabled",
		input: { listenPort: 7000, srtlaHost: "10.0.0.5", srtlaPort: 5001, ipsFile: "/tmp/srtla_ips", verbose: true },
		expected: ["7000", "10.0.0.5", "5001", "/tmp/srtla_ips", "--verbose"],
	},
	{
		name: "verbose explicitly false (no flag)",
		input: { listenPort: 5500, srtlaHost: "host.local", srtlaPort: 6000, verbose: false },
		expected: ["5500", "host.local", "6000", "/tmp/srtla_ips"],
	},
	{
		name: "high ports + IP host",
		input: { listenPort: 65000, srtlaHost: "192.168.1.50", srtlaPort: 65001, ipsFile: "/etc/srtla/ips" },
		expected: ["65000", "192.168.1.50", "65001", "/etc/srtla/ips"],
	},
];

describe("sender args additivity freeze (legacy configs, no statsFile)", () => {
	for (const { name, input, expected } of LEGACY_CONFIGS) {
		test(`byte-identical args: ${name}`, () => {
			const { args } = buildSrtlaSendArgs(input);
			expect(args).toEqual(expected);
			// No legacy config emits the new telemetry flag.
			expect(args).not.toContain("--stats-file");
		});
	}

	test("frozen snapshot of all legacy arg vectors", () => {
		const snapshot = LEGACY_CONFIGS.map(({ input }) => buildSrtlaSendArgs(input).args);
		expect(snapshot).toEqual([
			["5000", "relay.example.com", "8890", "/tmp/srtla_ips"],
			["9000", "relay.example.com", "8890", "/tmp/custom_ips"],
			["7000", "10.0.0.5", "5001", "/tmp/srtla_ips", "--verbose"],
			["5500", "host.local", "6000", "/tmp/srtla_ips"],
			["65000", "192.168.1.50", "65001", "/etc/srtla/ips"],
		]);
	});
});

describe("sender args with new statsFile option (additive emission)", () => {
	test("emits --stats-file <path> only when statsFile is set, appended after existing args", () => {
		const { args } = buildSrtlaSendArgs({
			listenPort: 5000,
			srtlaHost: "relay.example.com",
			srtlaPort: 8890,
			statsFile: "/tmp/srtla-send-stats-5000.json",
		});
		expect(args).toEqual([
			"5000",
			"relay.example.com",
			"8890",
			"/tmp/srtla_ips",
			"--stats-file",
			"/tmp/srtla-send-stats-5000.json",
		]);
	});

	test("statsFile combines with verbose without disturbing positional args", () => {
		const { args } = buildSrtlaSendArgs({
			listenPort: 9000,
			srtlaHost: "10.0.0.5",
			srtlaPort: 5001,
			verbose: true,
			statsFile: "/tmp/srtla-send-stats-9000.json",
		});
		expect(args).toEqual([
			"9000",
			"10.0.0.5",
			"5001",
			"/tmp/srtla_ips",
			"--verbose",
			"--stats-file",
			"/tmp/srtla-send-stats-9000.json",
		]);
	});
});
