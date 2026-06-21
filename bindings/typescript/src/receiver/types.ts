import { z } from "zod";

/** spdlog log levels accepted by `srtla_rec --log_level`. */
export const logLevelSchema = z.enum([
	"trace",
	"debug",
	"info",
	"warn",
	"error",
	"critical",
]);

export type LogLevel = z.infer<typeof logLevelSchema>;

/**
 * Zod schema for `srtla_rec` (receiver) CLI options. Parses and defaults the
 * `--srtla_port` / `--srt_hostname` / `--srt_port` arguments plus the optional
 * `--log_level` flag. Defaults mirror the C++ receiver implementation.
 */
export const srtlaRecOptionsSchema = z.object({
	srtlaPort: z
		.number()
		.int()
		.min(1)
		.max(65535)
		.default(5000)
		.describe("UDP listen port for inbound SRTLA connections (1-65535)."),
	srtHostname: z
		.string()
		.min(1)
		.default("127.0.0.1")
		.describe("Downstream SRT server hostname or IP."),
	srtPort: z
		.number()
		.int()
		.min(1)
		.max(65535)
		.default(4001)
		.describe("Downstream SRT server port (1-65535)."),
	logLevel: logLevelSchema.optional().describe("spdlog verbosity (--log_level)."),
	execPath: z.string().optional().describe("Override directory or path for the srtla_rec binary."),
});

export type SrtlaRecOptionsInput = z.input<typeof srtlaRecOptionsSchema>;
export type SrtlaRecOptions = z.output<typeof srtlaRecOptionsSchema>;
