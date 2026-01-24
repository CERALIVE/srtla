import { z } from "zod";
export declare const srtlaSendOptionsSchema: z.ZodObject<{
    listenPort: z.ZodDefault<z.ZodNumber>;
    srtlaHost: z.ZodString;
    srtlaPort: z.ZodDefault<z.ZodNumber>;
    ipsFile: z.ZodDefault<z.ZodString>;
    verbose: z.ZodOptional<z.ZodBoolean>;
    execPath: z.ZodOptional<z.ZodString>;
}, z.core.$strip>;
export type SrtlaSendOptionsInput = z.input<typeof srtlaSendOptionsSchema>;
export type SrtlaSendOptions = z.output<typeof srtlaSendOptionsSchema>;
