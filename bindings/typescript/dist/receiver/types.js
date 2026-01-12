import { z } from "zod";
export const srtlaRecOptionsSchema = z.object({
    srtlaPort: z.number().int().min(1).max(65535).default(5000),
    srtHostname: z.string().min(1).default("127.0.0.1"),
    srtPort: z.number().int().min(1).max(65535).default(5001),
    verbose: z.boolean().optional(),
    execPath: z.string().optional(),
});
