import fs from "node:fs";
import { z } from "zod";
// Simple IPv4 validator (0-255 per octet)
const ipv4Regex = /^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.)){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/;
export const ipListSchema = z.array(z
    .string()
    .trim()
    .regex(ipv4Regex, "Invalid IPv4 address")
    .describe("IPv4 address"));
/**
 * Validate and write an IP list file (one address per line).
 */
export function writeIpList(addresses, filePath) {
    const ips = ipListSchema.parse(addresses);
    fs.writeFileSync(filePath, `${ips.join("\n")}`);
    return ips;
}
