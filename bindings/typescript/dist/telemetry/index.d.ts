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
export declare const SENDER_TELEMETRY_STALE_MS = 5000;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Well-known path prefix, mirroring the producer's
 * `SENDER_TELEMETRY_PATH_PREFIX` and the receiver's `SRT_SOCKET_INFO_PREFIX`.
 * The live file is `<prefix><listen_port>.json`.
 */
export declare const SENDER_TELEMETRY_PATH_PREFIX = "/tmp/srtla-send-stats-";
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * Default live stats path for a listen port (the producer computes the same).
 */
export declare function senderTelemetryPath(listenPort: number): string;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * One per-connection record. Field names/units mirror `connection_info_t`
 * (src/common.h) plus `weight_percent`. `bitrate_bps` is bits/s (the wire
 * field is bytes/s; the producer applies the mandated x8 conversion).
 */
export declare const connectionTelemetrySchema: z.ZodObject<{
    conn_id: z.ZodString;
    rtt_ms: z.ZodNumber;
    nak_count: z.ZodNumber;
    weight_percent: z.ZodNumber;
    window: z.ZodNumber;
    in_flight: z.ZodNumber;
    bitrate_bps: z.ZodNumber;
}, z.core.$strip>;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 *
 * One snapshot object (never NDJSON — the file holds exactly one object).
 */
export declare const telemetrySchema: z.ZodObject<{
    last_updated_ms: z.ZodNumber;
    connections: z.ZodArray<z.ZodObject<{
        conn_id: z.ZodString;
        rtt_ms: z.ZodNumber;
        nak_count: z.ZodNumber;
        weight_percent: z.ZodNumber;
        window: z.ZodNumber;
        in_flight: z.ZodNumber;
        bitrate_bps: z.ZodNumber;
    }, z.core.$strip>>;
}, z.core.$strip>;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export type ConnectionTelemetry = z.output<typeof connectionTelemetrySchema>;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export type Telemetry = z.output<typeof telemetrySchema>;
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
export declare function readTelemetry(path: string): Promise<Telemetry | null>;
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export interface WatchTelemetryOptions {
    /** Poll cadence in milliseconds. Default 1000ms (the producer write cadence). */
    intervalMs?: number;
}
/**
 * @deprecated Use `@ceralive/srtla-send/telemetry` instead.
 * The C `srtla_send` is deprecated; use the Rust fork (srtla-send-rs) for new code.
 */
export interface WatchTelemetryHandle {
    /** Stop polling. Idempotent; no callback fires after this resolves. */
    stop: () => void;
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
export declare function watchTelemetry(path: string, cb: (telemetry: Telemetry | null) => void, opts?: WatchTelemetryOptions): WatchTelemetryHandle;
