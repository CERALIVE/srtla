import { srtlaRecOptionsSchema, type SrtlaRecOptionsInput } from "./types.js";
export interface SrtlaRecArgsResult {
    args: Array<string>;
    options: ReturnType<typeof srtlaRecOptionsSchema.parse>;
}
/**
 * Build CLI args for srtla_rec.
 * Shape: --srtla_port <port> --srt_hostname <host> --srt_port <port> [--verbose]
 */
export declare function buildSrtlaRecArgs(input: SrtlaRecOptionsInput): SrtlaRecArgsResult;
