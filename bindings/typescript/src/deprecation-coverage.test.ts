import { describe, expect, test } from "bun:test";

// Per-symbol @deprecated invariant for the retired C `srtla_send` surface
// (ADR-003). Every export in these definition files must carry an `@deprecated`
// JSDoc tag steering consumers to `@ceralive/srtla-send`. This is a SYMBOL-level
// check (parses each export and inspects the JSDoc block directly above it), not
// a whole-file `grep -L`: dropping the tag from a single export fails the test
// and names that export. The receiver surface is intentionally excluded — it is
// the shipped binary and is not deprecated.

const MARKER = "/bindings/typescript";
const PKG_ROOT = import.meta.dir.slice(0, import.meta.dir.indexOf(MARKER) + MARKER.length);
const SRC_DIR = `${PKG_ROOT}/src`;

const C_SENDER_FILES = [
	"sender/types.ts",
	"sender/args.ts",
	"sender/process.ts",
	"sender/index.ts",
	"telemetry/index.ts",
] as const;

function exportLabel(trimmed: string): string {
	const decl = /^export\s+(?:const|function|interface|type|class)\s+([A-Za-z0-9_]+)/.exec(trimmed);
	if (decl?.[1]) return decl[1];
	const reexport = /^export\s+(?:\*|\{[^}]*\})\s+from\s+["']([^"']+)["']/.exec(trimmed);
	if (reexport?.[1]) return `re-export ${reexport[1]}`;
	return trimmed;
}

/** Returns the immediately-preceding `/** ... *\/` block for the export at `i`, or null. */
function precedingBlock(lines: ReadonlyArray<string>, i: number): string | null {
	let end = i - 1;
	while (end >= 0 && lines[end]!.trim() === "") end--;
	if (end < 0 || lines[end]!.trim() !== "*/") return null;
	let start = end;
	while (start >= 0 && !lines[start]!.trim().startsWith("/**")) start--;
	if (start < 0) return null;
	return lines.slice(start, end + 1).join("\n");
}

function exportsMissingDeprecated(source: string): Array<string> {
	const lines = source.split("\n");
	const missing: Array<string> = [];
	for (let i = 0; i < lines.length; i++) {
		const trimmed = lines[i]!.trim();
		if (!trimmed.startsWith("export ")) continue;
		const block = precedingBlock(lines, i);
		if (block === null || !block.includes("@deprecated")) {
			missing.push(`${exportLabel(trimmed)} (line ${i + 1})`);
		}
	}
	return missing;
}

describe("C-sender export @deprecated coverage (ADR-003)", () => {
	for (const rel of C_SENDER_FILES) {
		test(`every export in ${rel} carries @deprecated`, async () => {
			const source = await Bun.file(`${SRC_DIR}/${rel}`).text();
			const missing = exportsMissingDeprecated(source);
			expect(missing, `${rel} exports missing @deprecated: ${missing.join(", ")}`).toEqual([]);
		});
	}

	test("the scan actually finds exports (guards against a no-op matcher)", async () => {
		let total = 0;
		for (const rel of C_SENDER_FILES) {
			const source = await Bun.file(`${SRC_DIR}/${rel}`).text();
			total += source.split("\n").filter((l) => l.trim().startsWith("export ")).length;
		}
		expect(total).toBeGreaterThanOrEqual(15);
	});
});
