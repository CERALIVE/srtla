import { describe, expect, test } from "bun:test";
import { senderTelemetryPath } from "../telemetry/index.js";
import { buildSrtlaSendArgs } from "./args.js";
describe("buildSrtlaSendArgs --stats-file emission (Todo 18)", () => {
    test("emits --stats-file with the ADR-001 path derived for the listen port", () => {
        const listenPort = 9000;
        const { args } = buildSrtlaSendArgs({
            listenPort,
            srtlaHost: "relay.example.com",
            srtlaPort: 8890,
            statsFile: senderTelemetryPath(listenPort),
        });
        const idx = args.indexOf("--stats-file");
        expect(idx).toBeGreaterThanOrEqual(0);
        expect(args[idx + 1]).toBe("/tmp/srtla-send-stats-9000.json");
        expect(args.slice(0, 4)).toEqual(["9000", "relay.example.com", "8890", "/tmp/srtla_ips"]);
    });
    test("omits --stats-file when statsFile is not provided", () => {
        const { args } = buildSrtlaSendArgs({ srtlaHost: "relay.example.com", srtlaPort: 8890 });
        expect(args).not.toContain("--stats-file");
    });
});
