import { srtlaRecOptionsSchema } from "./types.js";
/**
 * Build CLI args for srtla_rec.
 * Shape: --srtla_port <port> --srt_hostname <host> --srt_port <port> [--log_level <level>]
 */
export function buildSrtlaRecArgs(input) {
    const options = srtlaRecOptionsSchema.parse(input);
    const args = [
        "--srtla_port",
        String(options.srtlaPort),
        "--srt_hostname",
        options.srtHostname,
        "--srt_port",
        String(options.srtPort),
    ];
    if (options.logLevel) {
        args.push("--log_level", options.logLevel);
    }
    return { args, options };
}
