import { z } from "zod";
export declare const logLevelSchema: z.ZodEnum<{
    error: "error";
    trace: "trace";
    debug: "debug";
    info: "info";
    warn: "warn";
    critical: "critical";
}>;
export type LogLevel = z.infer<typeof logLevelSchema>;
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
