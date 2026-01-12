import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { writeIpList, ipListSchema } from "./ip-list.js";
describe("ipList", () => {
    test("validates and writes IP list", () => {
        const tmp = path.join(os.tmpdir(), `srtla_ips_${Date.now()}`);
        const ips = writeIpList(["10.0.0.1", "10.0.0.2"], tmp);
        expect(ips).toEqual(["10.0.0.1", "10.0.0.2"]);
        const content = fs.readFileSync(tmp, "utf8");
        expect(content.trim()).toBe("10.0.0.1\n10.0.0.2");
        fs.unlinkSync(tmp);
    });
    test("rejects invalid IP", () => {
        expect(() => ipListSchema.parse(["not-an-ip"])).toThrow();
    });
});
