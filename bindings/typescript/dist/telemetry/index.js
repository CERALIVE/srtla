import { z } from "zod";
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Sender telemetry reader (ADR-001, Option A — JSON stats file).
 *
 * `srtla_send` publishes a per-uplink snapshot to a stats file via atomic
 * `rename(2)` (see src/sender_telemetry.h). This module is the additive,
 * Bun-native consumer side: it reads that file with `Bun.file()` and applies
 * the ADR's staleness/absence semantics. No Node filesystem or process plumbing.
 *
 * The schema, units, and staleness threshold mirror ADR-001 exactly so the C
 * producer and this TS consumer never drift.
 */
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Snapshot older than this (now - last_updated_ms) is dead. Fixed by ADR-001.
 */
export const SENDER_TELEMETRY_STALE_MS = 5000;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Well-known path prefix, mirroring the producer's
 * `SENDER_TELEMETRY_PATH_PREFIX` and the receiver's `SRT_SOCKET_INFO_PREFIX`.
 * The live file is `<prefix><listen_port>.json`.
 */
export const SENDER_TELEMETRY_PATH_PREFIX = "/tmp/srtla-send-stats-";
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Default live stats path for a listen port (the producer computes the same).
 */
export function senderTelemetryPath(listenPort) {
    return `${SENDER_TELEMETRY_PATH_PREFIX}${listenPort}.json`;
}
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * One per-connection record. Field names/units mirror `connection_info_t`
 * (src/common.h) plus `weight_percent`. `bitrate_bps` is bits/s (the wire
 * field is bytes/s; the producer applies the mandated x8 conversion).
 */
export const connectionTelemetrySchema = z.object({
    conn_id: z.string(),
    rtt_ms: z.number().int().min(0),
    nak_count: z.number().int().min(0),
    weight_percent: z.number().int().min(0).max(100),
    window: z.number().int(),
    in_flight: z.number().int(),
    bitrate_bps: z.number().int().min(0),
});
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * One snapshot object (never NDJSON — the file holds exactly one object).
 */
export const telemetrySchema = z.object({
    last_updated_ms: z.number().int().min(0),
    connections: z.array(connectionTelemetrySchema),
});
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Read and validate the sender telemetry snapshot at `path`.
 *
 * Returns `null` (never throws) when the file is absent, unparseable, fails
 * schema validation, or is stale (`now - last_updated_ms > 5000`). A fresh,
 * schema-valid snapshot — including the "running but idle" `connections: []`
 * case — is returned as a typed {@link Telemetry} object.
 *
 * All I/O is Bun-native (`Bun.file`); no Node filesystem or process plumbing.
 */
export async function readTelemetry(path) {
    try {
        const file = Bun.file(path);
        if (!(await file.exists())) {
            return null;
        }
        const parsed = telemetrySchema.safeParse(JSON.parse(await file.text()));
        if (!parsed.success) {
            return null;
        }
        if (Date.now() - parsed.data.last_updated_ms > SENDER_TELEMETRY_STALE_MS) {
            return null;
        }
        return parsed.data;
    }
    catch {
        // Malformed/truncated read (atomic rename should prevent it, but guard
        // defensively) — telemetry is best-effort, never fatal.
        return null;
    }
}
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Poll `path` on a fixed cadence, invoking `cb` with the current
 * {@link Telemetry} (or `null` on absent/unparseable/stale) each tick.
 *
 * Fires once immediately so a consumer gets current state without waiting a
 * full interval, then repeats every `intervalMs` (default 1000ms). Call
 * `stop()` to halt; a read already in flight will not invoke `cb` afterward.
 */
export function watchTelemetry(path, cb, opts = {}) {
    const intervalMs = opts.intervalMs ?? 1000;
    let stopped = false;
    const tick = async () => {
        const telemetry = await readTelemetry(path);
        if (!stopped) {
            cb(telemetry);
        }
    };
    void tick();
    const timer = setInterval(() => {
        void tick();
    }, intervalMs);
    return {
        stop: () => {
            stopped = true;
            clearInterval(timer);
        },
    };
}
