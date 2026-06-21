import { z } from "zod";
/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Zod schema for `srtla_send` CLI options. Parses and defaults the four
 * positional arguments (`<listen_port> <srtla_host> <srtla_port> <ips_file>`)
 * plus the optional `--verbose` / `--stats-file` flags. Defaults mirror the C++
 * implementation, so a bare `{ srtlaHost }` yields the documented invocation.
 */
export const srtlaSendOptionsSchema = z.object({
    listenPort: z
        .number()
        .int()
        .min(1)
        .max(65535)
        .default(5000)
        .describe("Local UDP port the SRT encoder connects to (1-65535)."),
    srtlaHost: z.string().min(1).describe("Remote srtla_rec receiver hostname or IP."),
    srtlaPort: z
        .number()
        .int()
        .min(1)
        .max(65535)
        .default(5001)
        .describe("Remote srtla_rec receiver UDP port (1-65535)."),
    ipsFile: z
        .string()
        .min(1)
        .default("/tmp/srtla_ips")
        .describe("Path to the source-IP list file (one IPv4 per line)."),
    verbose: z.boolean().optional().describe("Enable debug logging (--verbose)."),
    // Opt-in per-connection telemetry stats file (ADR-001). Absent = telemetry off.
    statsFile: z
        .string()
        .min(1)
        .optional()
        .describe("Opt-in telemetry stats-file path (--stats-file); ADR-001."),
    execPath: z.string().optional().describe("Override directory or path for the srtla_send binary."),
});
