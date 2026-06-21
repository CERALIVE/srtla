import { z } from "zod";
/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Zod schema for `srtla_send` CLI options. Parses and defaults the four
 * positional arguments (`<listen_port> <srtla_host> <srtla_port> <ips_file>`)
 * plus the optional `--verbose` / `--stats-file` flags. Defaults mirror the C++
 * implementation, so a bare `{ srtlaHost }` yields the documented invocation.
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
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export type SrtlaSendOptionsInput = z.input<typeof srtlaSendOptionsSchema>;
/**
 * @deprecated Use `@ceralive/srtla-send` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export type SrtlaSendOptions = z.output<typeof srtlaSendOptionsSchema>;
