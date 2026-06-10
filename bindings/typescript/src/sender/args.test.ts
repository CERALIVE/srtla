import { describe, expect, test } from "bun:test";

import { buildSrtlaSendArgs } from "./args.js";

describe("buildSrtlaSendArgs", () => {
	test("applies defaults and orders args", () => {
		const { args, options } = buildSrtlaSendArgs({
			srtlaHost: "relay.example.com",
			srtlaPort: 8890,
		});

		expect(args).toEqual([
			"5000",
			"relay.example.com",
			"8890",
			"/tmp/srtla_ips",
		]);
		expect(options.listenPort).toBe(5000);
		expect(options.ipsFile).toBe("/tmp/srtla_ips");
	});

	test("includes verbose flag when set", () => {
		const { args } = buildSrtlaSendArgs({
			listenPort: 9000,
			srtlaHost: "relay.example.com",
			srtlaPort: 8890,
			ipsFile: "/tmp/custom_ips",
			verbose: true,
		});

		expect(args[args.length - 1]).toBe("--verbose");
		expect(args.slice(0, 4)).toEqual([
			"9000",
			"relay.example.com",
			"8890",
			"/tmp/custom_ips",
		]);
	});

	test("includes stats-file flag with path when set", () => {
		const { args } = buildSrtlaSendArgs({
			srtlaHost: "relay.example.com",
			srtlaPort: 8890,
			statsFile: "/tmp/srtla-send-stats-5000.json",
		});

		const idx = args.indexOf("--stats-file");
		expect(idx).toBeGreaterThanOrEqual(0);
		expect(args[idx + 1]).toBe("/tmp/srtla-send-stats-5000.json");
	});

	test("omits stats-file flag when unset", () => {
		const { args } = buildSrtlaSendArgs({
			srtlaHost: "relay.example.com",
			srtlaPort: 8890,
		});

		expect(args).not.toContain("--stats-file");
	});
});
