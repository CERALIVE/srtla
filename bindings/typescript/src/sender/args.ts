import { srtlaSendOptionsSchema, type SrtlaSendOptionsInput } from "./types.js";

export interface SrtlaSendArgsResult {
	args: Array<string>;
	options: ReturnType<typeof srtlaSendOptionsSchema.parse>;
}

/**
 * Build CLI args for srtla_send.
 * Shape: <listen_port> <srtla_host> <srtla_port> <ips_file> [--verbose]
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
	return { args, options };
}
