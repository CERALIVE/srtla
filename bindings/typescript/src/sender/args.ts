import { srtlaSendOptionsSchema, type SrtlaSendOptionsInput } from "./types.js";

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export interface SrtlaSendArgsResult {
	args: Array<string>;
	options: ReturnType<typeof srtlaSendOptionsSchema.parse>;
}

/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Build CLI args for srtla_send.
 * Shape: <listen_port> <srtla_host> <srtla_port> <ips_file> [--verbose] [--stats-file <path>]
 */
export function buildSrtlaSendArgs(input: SrtlaSendOptionsInput): SrtlaSendArgsResult {
	const options = srtlaSendOptionsSchema.parse(input);
	const args: Array<string> = [
		String(options.listenPort),
		options.srtlaHost,
		String(options.srtlaPort),
		options.ipsFile,
	];
	if (options.verbose) {
		args.push("--verbose");
	}
	if (options.statsFile) {
		args.push("--stats-file", options.statsFile);
	}
	return { args, options };
}
