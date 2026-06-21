import { z } from "zod";
/** spdlog log levels accepted by `srtla_rec --log_level`. */
export declare const logLevelSchema: z.ZodEnum<{
    error: "error";
    trace: "trace";
    debug: "debug";
    info: "info";
    warn: "warn";
    critical: "critical";
}>;
export type LogLevel = z.infer<typeof logLevelSchema>;
/**
 * Zod schema for `srtla_rec` (receiver) CLI options. Parses and defaults the
 * `--srtla_port` / `--srt_hostname` / `--srt_port` arguments plus the optional
 * `--log_level` flag. Defaults mirror the C++ receiver implementation.
 */
export declare const srtlaRecOptionsSchema: z.ZodObject<{
    srtlaPort: z.ZodDefault<z.ZodNumber>;
    srtHostname: z.ZodDefault<z.ZodString>;
    srtPort: z.ZodDefault<z.ZodNumber>;
    logLevel: z.ZodOptional<z.ZodEnum<{
        error: "error";
        trace: "trace";
        debug: "debug";
        info: "info";
        warn: "warn";
        critical: "critical";
    }>>;
    execPath: z.ZodOptional<z.ZodString>;
}, z.core.$strip>;
export type SrtlaRecOptionsInput = z.input<typeof srtlaRecOptionsSchema>;
export type SrtlaRecOptions = z.output<typeof srtlaRecOptionsSchema>;
