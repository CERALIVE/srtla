import { z } from "zod";
export declare const ipListSchema: z.ZodArray<z.ZodString>;
export type IpList = z.output<typeof ipListSchema>;
export type IpListInput = z.input<typeof ipListSchema>;
/**
 * Validate and write an IP list file (one address per line).
 */
export declare function writeIpList(addresses: IpListInput, filePath: string): IpList;
