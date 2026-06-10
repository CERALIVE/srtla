import { z } from "zod";
export const srtlaSendOptionsSchema = z.object({
    listenPort: z.number().int().min(1).max(65535).default(5000),
    srtlaHost: z.string().min(1),
    srtlaPort: z.number().int().min(1).max(65535).default(5001),
    ipsFile: z.string().min(1).default("/tmp/srtla_ips"),
    verbose: z.boolean().optional(),
    // Opt-in per-connection telemetry stats file (ADR-001). Absent = telemetry off.
    statsFile: z.string().min(1).optional(),
    execPath: z.string().optional(),
});
