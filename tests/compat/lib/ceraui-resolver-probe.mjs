// Import the application, including its real DNS cache; never copy the helper.
import { spawn } from "node:child_process";
import { once } from "node:events";
import { pathToFileURL } from "node:url";

const [modulePath, sender, localPort, hostname, receiverPort, ipsFile] =
	process.argv.slice(2);
if (!modulePath || !sender || !localPort || !hostname || !receiverPort || !ipsFile) {
	throw new Error("missing_application_probe_arguments");
}
let application;
try {
	application = await import(pathToFileURL(modulePath).href);
} catch (error) {
	console.error(JSON.stringify({
		prerequisite: "ceraui_application_import",
		reason: String(error),
	}));
	process.exit(77);
}
if (typeof application.resolveSrtla !== "function") {
	throw new Error("missing_resolveSrtla_export");
}
const cold = await application.resolveSrtla(hostname);
console.log(JSON.stringify({ phase: "cold", selected: cold }));
const warm = await application.resolveSrtla(hostname);
console.log(JSON.stringify({ phase: "warm", selected: warm }));
if (typeof cold !== "string" || typeof warm !== "string") {
	throw new Error("invalid_resolveSrtla_return");
}
// The warm call observes the same application cache. Only the cold launch is
// dialed, by ONE sender with BOTH uplinks; there is no sender per interface.
const child = spawn(sender, [localPort, cold, receiverPort, ipsFile], {
	stdio: "inherit",
});
const [exitCode, exitSignal] = await once(child, "exit");
if (exitSignal) throw new Error(`sender_signal:${exitSignal}`);
process.exitCode = exitCode ?? 1;
