import { srtlaSendOptionsSchema, type SrtlaSendOptionsInput } from "./types.js";
export interface SrtlaSendArgsResult {
    args: Array<string>;
    options: ReturnType<typeof srtlaSendOptionsSchema.parse>;
}
/**
 * Build CLI args for srtla_send.
 * Shape: <listen_port> <srtla_host> <srtla_port> <ips_file> [--verbose]
 */
export declare function buildSrtlaSendArgs(input: SrtlaSendOptionsInput): SrtlaSendArgsResult;
