import { z } from "zod";
/**
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
/** Snapshot older than this (now - last_updated_ms) is dead. Fixed by ADR-001. */
export declare const SENDER_TELEMETRY_STALE_MS = 5000;
/**
 * Well-known path prefix, mirroring the producer's
 * `SENDER_TELEMETRY_PATH_PREFIX` and the receiver's `SRT_SOCKET_INFO_PREFIX`.
 * The live file is `<prefix><listen_port>.json`.
 */
export declare const SENDER_TELEMETRY_PATH_PREFIX = "/tmp/srtla-send-stats-";
/** Default live stats path for a listen port (the producer computes the same). */
export declare function senderTelemetryPath(listenPort: number): string;
/**
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
/** One snapshot object (never NDJSON — the file holds exactly one object). */
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
export type ConnectionTelemetry = z.output<typeof connectionTelemetrySchema>;
export type Telemetry = z.output<typeof telemetrySchema>;
/**
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
export interface WatchTelemetryOptions {
    /** Poll cadence in milliseconds. Default 1000ms (the producer write cadence). */
    intervalMs?: number;
}
export interface WatchTelemetryHandle {
    /** Stop polling. Idempotent; no callback fires after this resolves. */
    stop: () => void;
}
/**
 * Poll `path` on a fixed cadence, invoking `cb` with the current
 * {@link Telemetry} (or `null` on absent/unparseable/stale) each tick.
 *
 * Fires once immediately so a consumer gets current state without waiting a
 * full interval, then repeats every `intervalMs` (default 1000ms). Call
 * `stop()` to halt; a read already in flight will not invoke `cb` afterward.
 */
export declare function watchTelemetry(path: string, cb: (telemetry: Telemetry | null) => void, opts?: WatchTelemetryOptions): WatchTelemetryHandle;
