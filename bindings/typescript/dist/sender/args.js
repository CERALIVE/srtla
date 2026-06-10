import { srtlaSendOptionsSchema } from "./types.js";
/**
 * Build CLI args for srtla_send.
 * Shape: <listen_port> <srtla_host> <srtla_port> <ips_file> [--verbose] [--stats-file <path>]
 */
export function buildSrtlaSendArgs(input) {
    const options = srtlaSendOptionsSchema.parse(input);
    const args = [
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
