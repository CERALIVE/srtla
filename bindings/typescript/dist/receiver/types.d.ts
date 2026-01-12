import { z } from "zod";
export declare const srtlaRecOptionsSchema: z.ZodObject<{
    srtlaPort: z.ZodDefault<z.ZodNumber>;
    srtHostname: z.ZodDefault<z.ZodString>;
    srtPort: z.ZodDefault<z.ZodNumber>;
    verbose: z.ZodOptional<z.ZodBoolean>;
    execPath: z.ZodOptional<z.ZodString>;
}, z.core.$strip>;
export type SrtlaRecOptionsInput = z.input<typeof srtlaRecOptionsSchema>;
export type SrtlaRecOptions = z.output<typeof srtlaRecOptionsSchema>;
