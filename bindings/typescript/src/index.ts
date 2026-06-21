export * from "./sender/index.js";
export * from "./receiver/index.js";
export * from "./shared/ip-list.js";
export * from "./telemetry/index.js";

// Additive (v0.2.0): surface the ADR-001 telemetry path helper explicitly at the
// package root so consumers resolving the live stats path do not need the
// `./telemetry` subpath. Re-exported, not redefined — the binding stays frozen.
export { senderTelemetryPath } from "./telemetry/index.js";
