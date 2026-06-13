import { z } from "zod";

/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
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

/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export type SrtlaSendOptionsInput = z.input<typeof srtlaSendOptionsSchema>;
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export type SrtlaSendOptions = z.output<typeof srtlaSendOptionsSchema>;
