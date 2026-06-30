#!/usr/bin/env bash
#
# probe-fec-capability.sh — empirically settle whether the SRT packet-filter
# API (the prerequisite for Forward Error Correction, SRTO_PACKETFILTER) is
# COMPILED into the libsrt builds the cloud receiver path consumes.
#
# This exists to falsify a documentation claim. srt/AGENTS.md states FEC is
# "not compiled" without -DENABLE_PACKET_FILTER=ON — yet srtcore/filelist.maf
# lists fec.cpp + packetfilter.cpp UNCONDITIONALLY (no build flag gates them),
# and upstream libsrt has no ENABLE_PACKET_FILTER option at all. Rather than
# trust either side, this probe MEASURES each library two independent ways:
#
#   1. Symbol probe  — `nm -D <lib>` for the FEC/packet-filter symbols
#                      (FECFilterBuiltin, PacketFilter::ParseConfig, ...).
#                      Present => the code was compiled into the .so.
#   2. Runtime probe — a tiny C program creates an SRT socket and calls
#                      srt_setsockopt(SRTO_PACKETFILTER,"fec"). A return of 0
#                      means libsrt parsed the FEC filter config and the FEC
#                      builtin is registered => FEC is usable at runtime.
#
# A library is reported FEC-capable iff EITHER method confirms (they agree in
# practice; both are recorded so neither can be a hard-coded guess).
#
# Three libraries are probed, matching the build-libsrt-matrix.sh slot names
# plus the system loader's libsrt:
#
#   system_libsrt              the libsrt the runtime loader resolves (the lib
#                              srt-live-transmit / srt-sink actually link)
#   vanilla                    build-libsrt-matrix.sh --vanilla slot  (stock
#                              Haivision v1.5.5)
#   srt_patched_reorderfreeze  build-libsrt-matrix.sh --patched slot  (CERALIVE
#                              reorderfreeze-1.5.5)
#
# Output (repo-local, gitignored — Rule D, never escapes the srtla checkout):
#   test-results/fec-capability-probe.json
#     { system_libsrt: bool, srt_patched_reorderfreeze: bool, vanilla: bool,
#       method: "...", evidence: "..." }
#
# By default the two matrix slots are built on demand via build-libsrt-matrix.sh
# pinned to v1.5.5 / reorderfreeze-1.5.5 if they are not already present. Pass
# --no-build to probe only what already exists (missing slots record null, not
# a false "FEC absent" claim).
#
# Usage:
#   probe-fec-capability.sh [--no-build] [--matrix-dir DIR] [--system-lib PATH]
#                           [--jobs N] [-h|--help]
#
# Exit status: 0 on a completed probe (regardless of the booleans); non-zero
# only on a harness error (missing nm/jq, unwritable output).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd -P)"

OUT_DIR="${REPO_ROOT}/test-results"
RESULT_JSON="${OUT_DIR}/fec-capability-probe.json"
MATRIX_DIR="${OUT_DIR}/libsrt-matrix/install"
BUILDER="${SCRIPT_DIR}/build-libsrt-matrix.sh"

VANILLA_REF="v1.5.5"
# build-libsrt-matrix.sh's clone_at checks out --detach <ref>; a bare BRANCH
# name trips git's "--detach cannot be used with -b/-B" DWIM/tracking conflict,
# so the patched slot is pinned to the reorderfreeze-1.5.5 TIP SHA (the builder's
# own documented --patched-ref form). PATCHED_LABEL is the human-readable branch.
PATCHED_REF="66b3609cc004e6a4c485e0adc11149025e782083"
PATCHED_LABEL="reorderfreeze-1.5.5"
VANILLA_URL="https://github.com/Haivision/srt"
PATCHED_URL="https://github.com/CERALIVE/srt"

DO_BUILD=1
SYSTEM_LIB=""
JOBS="$(nproc 2>/dev/null || echo 4)"

# nm -D pattern from the task spec; the decisive signal is a non-zero count of
# FEC/packet-filter symbols (FECFilterBuiltin is unambiguous).
SYM_PATTERN='fec|FECFilterBuiltin|PacketFilter'

log() { printf '%s\n' "$*" >&2; }
die() { printf 'probe-fec-capability: %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)    DO_BUILD=0; shift ;;
    --matrix-dir)  MATRIX_DIR="${2:?--matrix-dir needs a value}"; shift 2 ;;
    --system-lib)  SYSTEM_LIB="${2:?--system-lib needs a value}"; shift 2 ;;
    --jobs)        JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help)     sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -uo/d'; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
done

for tool in nm jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

mkdir -p "${OUT_DIR}"

# --------------------------------------------------------------------------- #
# Resolve the system libsrt the runtime loader actually uses.                 #
# --------------------------------------------------------------------------- #
resolve_system_lib() {
  [[ -n "$SYSTEM_LIB" ]] && { printf '%s' "$SYSTEM_LIB"; return 0; }
  # Prefer what an SRT tool links; fall back to ldconfig, then well-known paths.
  local p
  if command -v srt-live-transmit >/dev/null 2>&1; then
    p="$(ldd "$(command -v srt-live-transmit)" 2>/dev/null \
         | awk '/libsrt\.so/ {print $3; exit}')"
    [[ -n "$p" && -e "$p" ]] && { printf '%s' "$p"; return 0; }
  fi
  p="$(ldconfig -p 2>/dev/null | awk '/libsrt\.so\.[0-9]/ {print $NF; exit}')"
  [[ -n "$p" && -e "$p" ]] && { printf '%s' "$p"; return 0; }
  for p in /usr/local/lib/libsrt.so.1.5 /usr/lib/libsrt.so.1.5 \
           /usr/lib/x86_64-linux-gnu/libsrt.so.1.5; do
    [[ -e "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Real (non-symlink) shared object inside an install prefix.
find_so() {
  local prefix="$1"
  find "$prefix" -name 'libsrt.so.*' -type f 2>/dev/null | sort | head -1
}

# --------------------------------------------------------------------------- #
# Compile the runtime probe once. Empty RUNTIME_BIN => runtime method skipped. #
# --------------------------------------------------------------------------- #
RUNTIME_BIN=""
TMP_PROBE="$(mktemp -d "${TMPDIR:-/tmp}/fecprobe.XXXXXX")"
cleanup() { rm -rf "${TMP_PROBE}"; }
trap cleanup EXIT INT TERM

compile_runtime_probe() {
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || return 1
  local cc; cc="$(command -v cc || command -v gcc)"
  [[ -e /usr/include/srt/srt.h ]] || return 1
  cat > "${TMP_PROBE}/fecprobe.c" <<'PROBE_C'
/* Returns 0 iff srt_setsockopt(SRTO_PACKETFILTER,"fec") is accepted by the
 * linked libsrt — i.e. the packet-filter API + FEC builtin are compiled in. */
#include <srt/srt.h>
#include <stdio.h>
int main(void) {
    srt_startup();
    SRTSOCKET s = srt_create_socket();
    if (s == SRT_INVALID_SOCK) { srt_cleanup(); return 2; }
    int rc = srt_setsockopt(s, 0, SRTO_PACKETFILTER, "fec", 3);
    if (rc != 0) fprintf(stderr, "%s\n", srt_getlasterror_str());
    srt_close(s);
    srt_cleanup();
    return rc == 0 ? 0 : 1;
}
PROBE_C
  "$cc" "${TMP_PROBE}/fecprobe.c" -o "${TMP_PROBE}/fecprobe_bin" -lsrt 2>/dev/null \
    || return 1
  RUNTIME_BIN="${TMP_PROBE}/fecprobe_bin"
  return 0
}

# symbol_count <lib> -> echoes count of matching FEC/packet-filter symbols
symbol_count() {
  local lib="$1"
  [[ -e "$lib" ]] || { echo 0; return; }
  nm -D "$lib" 2>/dev/null | grep -icE "$SYM_PATTERN" || true
}

# runtime_ok <ld_dir> -> 0 if the probe links the lib in <ld_dir> and FEC sets.
# Empty <ld_dir> uses the default loader (system lib).
runtime_ok() {
  local ld_dir="$1"
  [[ -n "$RUNTIME_BIN" ]] || return 2   # 2 = method unavailable
  if [[ -n "$ld_dir" ]]; then
    LD_LIBRARY_PATH="$ld_dir" "$RUNTIME_BIN" >/dev/null 2>&1
  else
    "$RUNTIME_BIN" >/dev/null 2>&1
  fi
}

# --------------------------------------------------------------------------- #
# Optionally build the two matrix slots pinned to the evaluated refs.         #
# --------------------------------------------------------------------------- #
VANILLA_SO="$(find_so "${MATRIX_DIR}/vanilla")"
PATCHED_SO="$(find_so "${MATRIX_DIR}/patched")"

if [[ "$DO_BUILD" -eq 1 && ( -z "$VANILLA_SO" || -z "$PATCHED_SO" ) ]]; then
  if [[ -x "$BUILDER" ]]; then
    log "==> matrix libs absent; building vanilla=${VANILLA_REF} patched=${PATCHED_LABEL}(${PATCHED_REF})"
    if bash "$BUILDER" \
         --vanilla-url "$VANILLA_URL" --vanilla-ref "$VANILLA_REF" \
         --patched-url "$PATCHED_URL" --patched-ref "$PATCHED_REF" \
         --jobs "$JOBS" >&2; then
      VANILLA_SO="$(find_so "${MATRIX_DIR}/vanilla")"
      PATCHED_SO="$(find_so "${MATRIX_DIR}/patched")"
    else
      log "==> WARN: build-libsrt-matrix.sh failed; probing what exists only"
    fi
  else
    log "==> WARN: builder not executable at ${BUILDER}; skipping build"
  fi
fi

SYSTEM_LIB="$(resolve_system_lib || true)"

compile_runtime_probe && RUNTIME_AVAIL=1 || RUNTIME_AVAIL=0

# --------------------------------------------------------------------------- #
# Probe each library. Sets <slot>_BOOL (true|false|null) + appends evidence.  #
# --------------------------------------------------------------------------- #
EVIDENCE=""
add_ev() { EVIDENCE="${EVIDENCE}${EVIDENCE:+ | }$*"; }

# probe_one <label> <lib_so> <ld_dir>  -> sets PROBE_BOOL (true|false|null) and
# appends per-lib detail to EVIDENCE. Runs in the current shell (no command
# substitution) so the EVIDENCE accumulation survives.
probe_one() {
  local label="$1" lib="$2" ld_dir="$3"
  if [[ -z "$lib" || ! -e "$lib" ]]; then
    add_ev "${label}: lib not available (not probed)"
    PROBE_BOOL="null"; return
  fi
  local sym; sym="$(symbol_count "$lib")"
  local sym_present="false"; [[ "$sym" -gt 0 ]] && sym_present="true"

  local run_str="n/a"
  local run_present="false"
  if [[ "$RUNTIME_AVAIL" -eq 1 ]]; then
    if runtime_ok "$ld_dir"; then run_present="true"; run_str="ok"
    else run_present="false"; run_str="fail"; fi
  fi

  local capable="false"
  [[ "$sym_present" == "true" || "$run_present" == "true" ]] && capable="true"

  add_ev "${label}: ${lib#"${REPO_ROOT}"/} symbols=${sym}(${sym_present}) runtime_setsockopt=${run_str} -> ${capable}"
  PROBE_BOOL="$capable"
}

log "==> probing FEC packet-filter compilation"
probe_one system_libsrt "$SYSTEM_LIB" "$(dirname "${SYSTEM_LIB:-/nonexistent}")"; SYSTEM_BOOL="$PROBE_BOOL"
probe_one vanilla "$VANILLA_SO" "$(dirname "${VANILLA_SO:-/nonexistent}")"; VANILLA_BOOL="$PROBE_BOOL"
probe_one srt_patched_reorderfreeze "$PATCHED_SO" "$(dirname "${PATCHED_SO:-/nonexistent}")"; PATCHED_BOOL="$PROBE_BOOL"

# Fold the resolved build SHAs into the evidence when the manifest is present.
MANIFEST="${OUT_DIR}/libsrt-matrix/manifest.txt"
if [[ -e "$MANIFEST" ]]; then
  v_sha="$(awk '/^\[vanilla\]/{f=1} f&&/^sha /{print $3; exit}' "$MANIFEST" 2>/dev/null)"
  p_sha="$(awk '/^\[patched\]/{f=1} f&&/^sha /{print $3; exit}' "$MANIFEST" 2>/dev/null)"
  add_ev "refs: vanilla=${VANILLA_REF}(${v_sha:-?}) patched=${PATCHED_LABEL}(${p_sha:-?})"
fi

METHOD="nm -D symbol scan (${SYM_PATTERN}) + runtime srt_setsockopt(SRTO_PACKETFILTER,\"fec\")==0"
[[ "$RUNTIME_AVAIL" -eq 0 ]] && METHOD="${METHOD} [runtime probe unavailable: symbol-only]"

# --------------------------------------------------------------------------- #
# Emit JSON. Booleans are passed as raw JSON (true|false|null) — never quoted. #
# --------------------------------------------------------------------------- #
jq -n \
  --argjson system_libsrt "$SYSTEM_BOOL" \
  --argjson srt_patched_reorderfreeze "$PATCHED_BOOL" \
  --argjson vanilla "$VANILLA_BOOL" \
  --arg method "$METHOD" \
  --arg evidence "$EVIDENCE" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     system_libsrt: $system_libsrt,
     srt_patched_reorderfreeze: $srt_patched_reorderfreeze,
     vanilla: $vanilla,
     method: $method,
     evidence: $evidence,
     timestamp: $ts
   }' > "$RESULT_JSON" || die "failed to write ${RESULT_JSON}"

log ""
log "================ fec-capability-probe summary ================"
log "  system_libsrt             : ${SYSTEM_BOOL}"
log "  vanilla (v1.5.5)          : ${VANILLA_BOOL}"
log "  srt_patched_reorderfreeze : ${PATCHED_BOOL}"
log "  method  : ${METHOD}"
log "  result  : ${RESULT_JSON#"${REPO_ROOT}"/}"
log "============================================================="
cat "$RESULT_JSON"
exit 0
