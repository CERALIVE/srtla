import { describe, expect, test } from "bun:test";

import { buildSrtlaRecArgs } from "./args.js";

describe("buildSrtlaRecArgs", () => {
	test("applies defaults", () => {
		const { args, options } = buildSrtlaRecArgs({});

		expect(args).toEqual([
			"--srtla_port",
			"5000",
			"--srt_hostname",
			"127.0.0.1",
			"--srt_port",
			"4001",
		]);
		expect(options.srtlaPort).toBe(5000);
		expect(options.srtHostname).toBe("127.0.0.1");
		expect(options.srtPort).toBe(4001);
	});

	test("includes log_level when set", () => {
		const { args } = buildSrtlaRecArgs({
			srtlaPort: 6000,
			srtHostname: "0.0.0.0",
			srtPort: 6001,
			logLevel: "debug",
		});

		expect(args.slice(0, 6)).toEqual([
			"--srtla_port",
			"6000",
			"--srt_hostname",
			"0.0.0.0",
			"--srt_port",
			"6001",
		]);
		expect(args).toContain("--log_level");
		expect(args).toContain("debug");
	});

	test("omits log_level when not set", () => {
		const { args } = buildSrtlaRecArgs({
			srtlaPort: 5000,
		});

		expect(args).not.toContain("--log_level");
	});
});
