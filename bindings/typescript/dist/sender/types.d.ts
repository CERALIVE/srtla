import { z } from "zod";
/**
 * @deprecated Use `@ceralive/srtla-send/sender` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export declare const srtlaSendOptionsSchema: z.ZodObject<{
    listenPort: z.ZodDefault<z.ZodNumber>;
    srtlaHost: z.ZodString;
    srtlaPort: z.ZodDefault<z.ZodNumber>;
    ipsFile: z.ZodDefault<z.ZodString>;
    verbose: z.ZodOptional<z.ZodBoolean>;
    statsFile: z.ZodOptional<z.ZodString>;
    execPath: z.ZodOptional<z.ZodString>;
}, z.core.$strip>;
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
