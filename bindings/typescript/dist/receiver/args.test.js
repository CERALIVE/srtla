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
            "5001",
        ]);
        expect(options.srtlaPort).toBe(5000);
        expect(options.srtHostname).toBe("127.0.0.1");
        expect(options.srtPort).toBe(5001);
    });
    test("includes verbose flag when set", () => {
        const { args } = buildSrtlaRecArgs({
            srtlaPort: 6000,
            srtHostname: "0.0.0.0",
            srtPort: 6001,
            verbose: true,
        });
        expect(args.slice(0, 6)).toEqual([
            "--srtla_port",
            "6000",
            "--srt_hostname",
            "0.0.0.0",
            "--srt_port",
            "6001",
        ]);
        expect(args[args.length - 1]).toBe("--verbose");
    });
});
