#!/usr/bin/env bash
#
# profile-validation-matrix.sh — A/B validation matrix for the SRT receive
# profiles: the 4 non-FEC profiles (Balanced / Low-Latency / Resilient /
# Classic) measured against the patched-libsrt baseline under production-
# realistic cross-link reorder stress, with an "equal" pass gate built on the
# srt-sink TS-continuity metrics (Task 5), NOT on a bytes-only proxy.
#
# WHY this exists: the receiver cutover replaces the unconditional BELABOX
# libsrt patch (decay-off + periodic-NAK-off, baked in at compile time) with the
# opt-in SRTO_REORDERFREEZE option (reorderfreeze-1.5.5 branch) plus standard
# SRTO_NAKREPORT / SRTO_LOSSMAXTTL flags. This script proves each non-FEC profile
# recipe is statistically EQUAL to the patch baseline before that cutover lands.
#
# It is the production-realistic successor to the ADR-002 A/B/C study: same
# instrument (scenarios/reorder-stress.sh), but parameterised across bitrate,
# receive-latency and LOSSMAXTTL, run paired/alternating with a fixed netem seed,
# and judged on transport-stream continuity rather than delivered byte count.
#
# THE TWO libsrt ARTIFACTS (swapped under srt-sink, never the system libsrt):
#   baseline  CERALIVE/srt @ 52057f6 — the 6-line unconditional BELABOX merge
#             (libsrt.so.1.5.4). Behaviours (b) decay-off + (c) NAK-off are baked
#             in; no socket flag is needed (and SRTO_SRTLAPATCHES is NOT defined
#             on this fork — see ADR-002 §1).
#   freeze    CERALIVE/srt @ reorderfreeze-1.5.5 — vanilla 1.5.5 + opt-in
#             SRTO_REORDERFREEZE (libsrt.so.1.5.5). The profile recipes drive it
#             via srt-sink's --reorderfreeze / --nakreport / --lossmaxttl.
#   Both are provided as loader prefixes (BASELINE_LIBSRT / FREEZE_LIBSRT). If a
#   prefix is absent the script builds it via lib/build-libsrt-matrix.sh from
#   SRT_REPO_URL @ {BASELINE_REF,FREEZE_REF} (mapping its patched slot -> baseline,
#   its vanilla slot -> freeze). FEC SCOPE: this gate covers the 4 NON-FEC
#   profiles only; the Low-Latency+FEC row is gated separately.
#
# THE 4 NON-FEC PROFILE RECIPES (device latency differs; receiver recipe shown):
#   Balanced    freeze+NAK     REORDERFREEZE=1 NAKREPORT=1   @ 1500ms
#   Low-Latency freeze+NAK     REORDERFREEZE=1 NAKREPORT=1   @  250ms
#   Resilient   freeze+NAK     REORDERFREEZE=1 NAKREPORT=1   @ 3500ms
#   Classic     freeze+NAK-off REORDERFREEZE=1 NAKREPORT=0   @  800ms
#   (control)   stock-decay    REORDERFREEZE=0 NAKREPORT=1   — falsifiability arm
#
# THE "EQUAL" GATE (profile vs its paired baseline, per cell):
#   1. disconnects == 0 (both arms)         4. median goodput >= 99% baseline
#   2. ts_sync_errors == 0 (profile)        5. p95 late-drop (pkt_rcv_drop) <= baseline
#   3. ts_cc_errors <= baseline (median)    6. wire-amplification <= 1.10x baseline
#
# REGRESSION-VALIDATION CELL: Balanced (freeze, NAK-on) vs baseline at receive
# latencies {500,1500,3500}ms — the dedicated NAK-on comparison, TS-continuity as
# the signal. LOSSMAXTTL SWEEP: Balanced vs baseline at {30,200,1000} (a separate
# axis to pick the cap). The blocking verdict = all 4 non-FEC profiles PASS AND
# the regression cell PASSes; the sweep + control are informational.
#
# PRIVILEGE: needs CAP_NET_ADMIN (real root / passwordless sudo, OR mapped-root
# in a user+net namespace), gated via lib/netem.sh `require`; without it the
# script prints SKIP-PRIVILEGED and exits 77, creating no state.
#   CI / local:  sudo tests/compat/scenarios/profile-validation-matrix.sh
#   smoke:       sudo tests/compat/scenarios/profile-validation-matrix.sh --smoke
#
# Usage:
#   profile-validation-matrix.sh [--build-dir DIR] [--reps N] [--duration SEC]
#                                [--smoke] [--keep-logs] [-h]
#     --reps N       paired reps per arm per cell (default 10).
#     --duration SEC per-phase seconds for reorder-stress (default 58 => ~121s/rep).
#     --smoke        fast self-test: --reps 2 --duration 12 (~29s/rep).
#
# Evidence table -> test-results/srt-receive-profiles/task-6-srt-receive-profiles.json
# Per-run artifacts -> tests/compat/results/profile-validation-matrix/ (gitignored).
# Rule D: writes nothing above the srtla repo root.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/profile-validation-matrix"
REORDER="${SCRIPT_DIR}/reorder-stress.sh"
NETEM_LIB="${SCRIPT_DIR}/../lib/netem.sh"
BUILD_MATRIX="${SCRIPT_DIR}/../lib/build-libsrt-matrix.sh"
LIBSRT_MATRIX="${REPO_ROOT}/test-results/libsrt-matrix"
EVIDENCE_DIR="${REPO_ROOT}/test-results/srt-receive-profiles"
EVIDENCE_JSON="${EVIDENCE_DIR}/task-6-srt-receive-profiles.json"
REORDER_RESULT="${SCRIPT_DIR}/../results/reorder-stress/result.json"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'profile-validation-matrix: %s\n' "$*" >&2; exit 2; }

# --------------------------------------------------------------------------- #
# CLI / env                                                                   #
# --------------------------------------------------------------------------- #
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
REPS="${REPS:-10}"
PHASE_SEC="${PHASE_SEC:-58}"
BITRATE_KBPS="${BITRATE_KBPS:-8000}"
NETEM_SEED_BASE="${NETEM_SEED_BASE:-1000}"
KEEP_LOGS=0
BASELINE_LIBSRT="${BASELINE_LIBSRT:-${LIBSRT_MATRIX}/install/patched/lib}"
FREEZE_LIBSRT="${FREEZE_LIBSRT:-${LIBSRT_MATRIX}/install/freeze/lib}"
SRT_REPO_URL="${SRT_REPO_URL:-https://github.com/CERALIVE/srt}"
BASELINE_REF="${BASELINE_REF:-52057f6846c66d4ecf5d47c9c0a2cecd281d77d6}"
FREEZE_REF="${FREEZE_REF:-reorderfreeze-1.5.5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --reps)      REPS="${2:?--reps needs a value}"; shift 2 ;;
    --duration)  PHASE_SEC="${2:?--duration needs a value}"; shift 2 ;;
    --smoke)     REPS=2; PHASE_SEC=12; shift ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done
[[ "$REPS" =~ ^[0-9]+$ && "$REPS" -ge 1 ]] || die "--reps must be a positive integer"
[[ "$PHASE_SEC" =~ ^[0-9]+$ && "$PHASE_SEC" -ge 1 ]] || die "--duration must be a positive integer"

for tool in ffmpeg jq python3 ip tc; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done
[[ -x "$REORDER" ]] || die "reorder-stress.sh not found/executable at $REORDER"

# Capability gate via netem.sh's CLI `require` (77 == SKIP-PRIVILEGED). Run as a
# subprocess so we do not entangle netem.sh's EXIT trap with this driver.
if ! bash "$NETEM_LIB" require >/dev/null 2>&1; then
  log "SKIP profile-validation-matrix: netem unavailable (need CAP_NET_ADMIN: root, sudo, or mapped-root userns)"
  mkdir -p "$EVIDENCE_DIR"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task:"task-6-srt-receive-profiles", skipped:true,
      reason:"no CAP_NET_ADMIN / netem", timestamp:$ts}' > "$EVIDENCE_JSON"
  exit 77
fi

# --------------------------------------------------------------------------- #
# Resolve the srtla build dir (srtla_rec / srtla_send / srt-sink).            #
# --------------------------------------------------------------------------- #
resolve_build_dir() {
  local candidates=() d
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  for d in "${candidates[@]}"; do
    if [[ -x "${d}/srtla_rec" && -x "${d}/srtla_send" \
       && -x "${d}/tests/compat/srt-sink/srt-sink" ]]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}
BUILD_DIR="$(resolve_build_dir)" || die \
  "no usable build dir (need srtla_rec, srtla_send, srt-sink). Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j"

# --------------------------------------------------------------------------- #
# Provision the two libsrt loader prefixes. If a prefix already holds a        #
# libsrt.so it is used as-is (operator pre-built); otherwise both are built    #
# from SRT_REPO_URL via build-libsrt-matrix.sh (its patched slot is our        #
# baseline, its vanilla slot is our freeze build).                            #
# --------------------------------------------------------------------------- #
has_libsrt() { compgen -G "${1}/libsrt.so.*" >/dev/null 2>&1; }

provision_libsrt() {
  if has_libsrt "$BASELINE_LIBSRT" && has_libsrt "$FREEZE_LIBSRT"; then
    log "==> libsrt: using pre-built prefixes"
    return 0
  fi
  [[ -x "$BUILD_MATRIX" ]] || die "missing libsrt prefixes and no builder at $BUILD_MATRIX"
  log "==> libsrt: building baseline ($BASELINE_REF) + freeze ($FREEZE_REF) from $SRT_REPO_URL"
  bash "$BUILD_MATRIX" \
    --patched-url "$SRT_REPO_URL" --patched-ref "$BASELINE_REF" \
    --vanilla-url "$SRT_REPO_URL" --vanilla-ref "$FREEZE_REF" >&2 \
    || die "build-libsrt-matrix.sh failed"
  BASELINE_LIBSRT="${LIBSRT_MATRIX}/install/patched/lib"
  FREEZE_LIBSRT="${LIBSRT_MATRIX}/install/vanilla/lib"
  has_libsrt "$BASELINE_LIBSRT" || die "baseline libsrt missing after build"
  has_libsrt "$FREEZE_LIBSRT"   || die "freeze libsrt missing after build"
}
provision_libsrt
BASELINE_LIBSRT="$(cd -- "$BASELINE_LIBSRT" && pwd -P)"
FREEZE_LIBSRT="$(cd -- "$FREEZE_LIBSRT" && pwd -P)"

log "================ profile-validation-matrix ================"
log "  build dir   : ${BUILD_DIR}"
log "  baseline lib: ${BASELINE_LIBSRT}"
log "  freeze lib  : ${FREEZE_LIBSRT}"
log "  reps=${REPS} phase=${PHASE_SEC}s (~$((5 + 2*PHASE_SEC))s/rep) bitrate=${BITRATE_KBPS}k seed_base=${NETEM_SEED_BASE}"
log "==========================================================="

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"

# --------------------------------------------------------------------------- #
# One reorder-stress rep -> copy its result.json to <out>.                     #
# Args: out lib latency bitrate lossmaxttl nakreport reorderfreeze label seed  #
# Empty lossmaxttl/nakreport/reorderfreeze => that knob is left at libsrt       #
# default (the baseline arm passes all three empty: the patch is unconditional).#
# --------------------------------------------------------------------------- #
run_rep() {
  local out="$1" lib="$2" lat="$3" br="$4" ttl="$5" nak="$6" frz="$7" label="$8" seed="$9"
  local -a env_kv=(
    "SRTLA_BUILD_DIR=${BUILD_DIR}" "SINK_LD_LIBRARY_PATH=${lib}"
    "RX_LATENCY_MS=${lat}" "BITRATE_KBPS=${br}" "PROFILE_LABEL=${label}"
    "NETEM_SEED=${seed}"
  )
  [[ -n "$ttl" ]] && env_kv+=("LOSSMAXTTL=${ttl}")
  [[ -n "$nak" ]] && env_kv+=("NAKREPORT=${nak}")
  [[ -n "$frz" ]] && env_kv+=("REORDERFREEZE=${frz}")
  rm -f "$REORDER_RESULT"
  env "${env_kv[@]}" bash "$REORDER" --duration "$PHASE_SEC" >/dev/null 2>&1 || true
  if [[ -f "$REORDER_RESULT" ]]; then cp "$REORDER_RESULT" "$out"; else printf '{}\n' > "$out"; fi
}

# A paired cell: baseline arm + profile arm, ALTERNATED per rep with a shared
# per-rep seed so both arms meet the same netem reorder draw (paired comparison).
# Args: cell_dir latency lossmaxttl prof_nak prof_frz prof_label
run_cell() {
  local dir="$1" lat="$2" ttl="$3" pnak="$4" pfrz="$5" plabel="$6"
  mkdir -p "${dir}/baseline" "${dir}/profile"
  local r seed
  for (( r=1; r<=REPS; r++ )); do
    seed=$(( NETEM_SEED_BASE + r ))
    log "    [$(basename "$(dirname "$dir")")/$(basename "$dir")] rep ${r}/${REPS} (seed ${seed})"
    run_rep "${dir}/baseline/rep-${r}.json" "$BASELINE_LIBSRT" "$lat" "$BITRATE_KBPS" "" "" "" "baseline-patched" "$seed"
    run_rep "${dir}/profile/rep-${r}.json"  "$FREEZE_LIBSRT"   "$lat" "$BITRATE_KBPS" "$ttl" "$pnak" "$pfrz" "$plabel" "$seed"
  done
}

# --------------------------------------------------------------------------- #
# Main matrix — the 4 non-FEC profiles, each vs the paired baseline.          #
# --------------------------------------------------------------------------- #
log "==> main matrix: 4 non-FEC profiles vs baseline"
run_cell "${RESULTS_DIR}/main/balanced"    1500 30 1 1 "balanced-freeze+nak"
run_cell "${RESULTS_DIR}/main/lowlatency"   250 30 1 1 "lowlatency-freeze+nak"
run_cell "${RESULTS_DIR}/main/resilient"   3500 30 1 1 "resilient-freeze+nak"
run_cell "${RESULTS_DIR}/main/classic"      800 30 0 1 "classic-freeze+nak-off"

# --------------------------------------------------------------------------- #
# Regression-validation cell — Balanced (freeze, NAK-on) vs baseline at the    #
# three receive latencies, the dedicated NAK-on comparison.                    #
# --------------------------------------------------------------------------- #
log "==> regression-validation cell: balanced freeze+NAK vs baseline @ {500,1500,3500}ms"
for lat in 500 1500 3500; do
  run_cell "${RESULTS_DIR}/regression/lat-${lat}" "$lat" 30 1 1 "balanced-freeze+nak"
done

# --------------------------------------------------------------------------- #
# LOSSMAXTTL sweep — a separate axis to pick the cap (Balanced @ 1500ms).      #
# --------------------------------------------------------------------------- #
log "==> LOSSMAXTTL sweep: {30,200,1000} @ 1500ms"
for ttl in 30 200 1000; do
  run_cell "${RESULTS_DIR}/lossmaxttl/ttl-${ttl}" 1500 "$ttl" 1 1 "balanced-freeze+nak"
done

# --------------------------------------------------------------------------- #
# Control — stock-decay (REORDERFREEZE=0) vs baseline @ 1500ms. Falsifiability: #
# the gate must be able to SEE the freeze matter (this arm may legitimately     #
# diverge); it is reported, not part of the blocking verdict.                  #
# --------------------------------------------------------------------------- #
log "==> control (falsifiability): stock-decay+NAK vs baseline @ 1500ms"
run_cell "${RESULTS_DIR}/control/stock-decay" 1500 30 1 0 "stock-decay+nak"

# --------------------------------------------------------------------------- #
# Aggregate every cell, apply the equal gate, write the evidence table.        #
# --------------------------------------------------------------------------- #
mkdir -p "$EVIDENCE_DIR"
log "==> aggregating + applying the equal gate -> ${EVIDENCE_JSON}"

python3 - "$RESULTS_DIR" "$EVIDENCE_JSON" "$BASELINE_LIBSRT" "$FREEZE_LIBSRT" \
          "$REPS" "$PHASE_SEC" "$BITRATE_KBPS" "$NETEM_SEED_BASE" "$LIBSRT_MATRIX" <<'PY'
import json, math, os, sys, glob, datetime

(results_dir, evidence_json, baseline_lib, freeze_lib,
 reps, phase_sec, bitrate, seed_base, libsrt_matrix) = sys.argv[1:10]
reps = int(reps); phase_sec = int(phase_sec); bitrate = int(bitrate)

GOODPUT_FLOOR = 0.99      # clause 4: median goodput >= 99% baseline
WIRE_AMP_CEIL = 1.10      # clause 6: wire-amp <= 1.10x baseline

def load_arm(arm_dir):
    rows = []
    for f in sorted(glob.glob(os.path.join(arm_dir, "rep-*.json"))):
        try:
            with open(f) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            d = {}
        m = d.get("metrics", {}) or {}
        s = d.get("sink", {}) or {}
        rows.append({
            "goodput_bps": float(m.get("goodput_bps", 0) or 0),
            "wire_amp":    float(m.get("wire_amp", 0) or 0),
            "ts_sync":     int(m.get("ts_sync_errors", -1)),
            "ts_cc":       int(m.get("ts_cc_errors", -1)),
            "pkt_drop":    int(m.get("pkt_rcv_drop", 0) or 0),
            "pkt_retrans": int(m.get("pkt_retrans", 0) or 0),
            "bytes":       int(s.get("bytes_received", 0) or 0),
            "disc":        int(s.get("disconnects", -1)),
        })
    return rows

def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return 0.0
    mid = n // 2
    return float(xs[mid]) if n % 2 else (xs[mid - 1] + xs[mid]) / 2.0

def p95(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return 0.0
    idx = min(n - 1, max(0, math.ceil(0.95 * n) - 1))
    return float(xs[idx])

def agg(rows):
    if not rows:
        return {"n": 0, "goodput_median": 0.0, "wire_amp_median": 0.0,
                "ts_cc_median": 0.0, "ts_cc_max": 0, "ts_sync_max": -1,
                "pkt_drop_p95": 0.0, "disc_max": -1, "pkt_retrans_median": 0.0,
                "bytes_median": 0.0}
    return {
        "n": len(rows),
        "goodput_median": median([r["goodput_bps"] for r in rows]),
        "wire_amp_median": median([r["wire_amp"] for r in rows]),
        "ts_cc_median": median([r["ts_cc"] for r in rows]),
        "ts_cc_max": max(r["ts_cc"] for r in rows),
        "ts_sync_max": max(r["ts_sync"] for r in rows),
        "pkt_drop_p95": p95([r["pkt_drop"] for r in rows]),
        "pkt_retrans_median": median([r["pkt_retrans"] for r in rows]),
        "disc_max": max(r["disc"] for r in rows),
        "bytes_median": median([r["bytes"] for r in rows]),
    }

def equal_gate(prof, base):
    c1 = prof["disc_max"] == 0 and base["disc_max"] == 0
    c2 = prof["ts_sync_max"] == 0
    c3 = prof["ts_cc_median"] <= base["ts_cc_median"]
    c4 = prof["goodput_median"] >= GOODPUT_FLOOR * base["goodput_median"]
    c5 = prof["pkt_drop_p95"] <= base["pkt_drop_p95"]
    c6 = (prof["wire_amp_median"] <= WIRE_AMP_CEIL * base["wire_amp_median"]) \
         if base["wire_amp_median"] > 0 else (prof["wire_amp_median"] == 0)
    clauses = {
        "disconnects_zero": c1, "ts_sync_zero": c2, "ts_cc_le_baseline": c3,
        "goodput_ge_99pct": c4, "p95_late_drop_le_baseline": c5,
        "wire_amp_le_110pct": c6,
    }
    return all(clauses.values()), clauses

def cell(cell_dir):
    base = agg(load_arm(os.path.join(cell_dir, "baseline")))
    prof = agg(load_arm(os.path.join(cell_dir, "profile")))
    passed, clauses = equal_gate(prof, base)
    return {"baseline": base, "profile": prof, "pass": passed, "clauses": clauses}

def cells_in(group):
    base = os.path.join(results_dir, group)
    if not os.path.isdir(base):
        return {}
    out = {}
    for name in sorted(os.listdir(base)):
        d = os.path.join(base, name)
        if os.path.isdir(d):
            out[name] = cell(d)
    return out

main = cells_in("main")
regression = cells_in("regression")
lossmaxttl = cells_in("lossmaxttl")
control = cells_in("control")

main_pass = bool(main) and all(c["pass"] for c in main.values())
regression_pass = bool(regression) and all(c["pass"] for c in regression.values())
blocking_pass = main_pass and regression_pass

# LOSSMAXTTL recommendation: smallest cap whose cell still passes the equal gate.
def ttl_val(name):
    try:
        return int(name.split("-", 1)[1])
    except (IndexError, ValueError):
        return 1 << 30
passing_ttls = sorted(int(n.split("-", 1)[1]) for n, c in lossmaxttl.items()
                      if c["pass"] and n.startswith("ttl-"))
recommended_lossmaxttl = passing_ttls[0] if passing_ttls else None

# libsrt identity from the build manifest, when present.
manifest = {}
mpath = os.path.join(libsrt_matrix, "manifest.txt")
if os.path.isfile(mpath):
    section = None
    with open(mpath) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]; manifest[section] = {}
            elif section and "=" in line and not line.startswith("#"):
                k, v = (x.strip() for x in line.split("=", 1))
                manifest[section][k] = v

doc = {
    "task": "task-6-srt-receive-profiles",
    "title": "A/B profile validation matrix — 4 non-FEC profiles vs patched baseline",
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "fec_scope": "non-FEC only (Balanced/Low-Latency/Resilient/Classic); "
                 "Low-Latency+FEC row gated separately",
    "methodology": {
        "instrument": "scenarios/reorder-stress.sh (cross-link reorder: 50/150ms "
                      "asymmetric delay + netem reorder 25% 50% phase)",
        "reps_per_arm": reps,
        "phase_sec": phase_sec,
        "approx_sec_per_rep": 5 + 2 * phase_sec,
        "bitrate_kbps": bitrate,
        "pairing": "alternating baseline/profile per rep, shared per-rep netem seed",
        "seed_base": int(seed_base),
        "signal": "srt-sink TS-continuity + SRT loss/retrans (Task 5), NOT bytes-only",
        "equal_gate": {
            "disconnects": "== 0 (both arms)",
            "ts_sync_errors": "== 0 (profile)",
            "ts_cc_errors": "<= baseline (median)",
            "goodput": ">= 99% baseline (median)",
            "p95_late_drop": "<= baseline (pkt_rcv_drop p95)",
            "wire_amplification": "<= 1.10x baseline (median)",
        },
    },
    "libsrt": {
        "baseline": {"role": "patched (unconditional BELABOX merge)",
                     "loader": baseline_lib, "manifest": manifest.get("patched", {})},
        "freeze": {"role": "reorderfreeze-1.5.5 (opt-in SRTO_REORDERFREEZE)",
                   "loader": freeze_lib, "manifest": manifest.get("vanilla", {})},
    },
    "profiles": main,
    "regression_validation_cell": regression,
    "lossmaxttl_sweep": lossmaxttl,
    "control_stock_decay": control,
    "verdict": {
        "non_fec_profiles_pass": main_pass,
        "regression_cell_pass": regression_pass,
        "blocking_pass": blocking_pass,
        "recommended_lossmaxttl": recommended_lossmaxttl,
    },
}

with open(evidence_json, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")

def line(name, c):
    g = c["profile"]["goodput_median"]; b = c["baseline"]["goodput_median"]
    ratio = (g / b) if b else 0.0
    sys.stderr.write(
        "  %-22s %s  goodput=%.0f/%.0f (%.1f%%) wire_amp=%.3f/%.3f "
        "ts_cc=%.0f/%.0f p95_drop=%.0f/%.0f disc=%d/%d\n" % (
            name, "PASS" if c["pass"] else "FAIL", g, b, 100 * ratio,
            c["profile"]["wire_amp_median"], c["baseline"]["wire_amp_median"],
            c["profile"]["ts_cc_median"], c["baseline"]["ts_cc_median"],
            c["profile"]["pkt_drop_p95"], c["baseline"]["pkt_drop_p95"],
            c["profile"]["disc_max"], c["baseline"]["disc_max"]))

sys.stderr.write("\n================ equal-gate results (profile/baseline) ================\n")
sys.stderr.write("-- main (4 non-FEC profiles) --\n")
for n, c in main.items(): line(n, c)
sys.stderr.write("-- regression-validation cell (balanced NAK-on) --\n")
for n, c in regression.items(): line(n, c)
sys.stderr.write("-- LOSSMAXTTL sweep --\n")
for n, c in lossmaxttl.items(): line(n, c)
sys.stderr.write("-- control (falsifiability; informational) --\n")
for n, c in control.items(): line(n, c)
sys.stderr.write("recommended LOSSMAXTTL cap: %s\n" % recommended_lossmaxttl)
sys.stderr.write("non-FEC profiles PASS: %s | regression cell PASS: %s\n"
                 % (main_pass, regression_pass))
sys.stderr.write("BLOCKING VERDICT: %s\n" % ("PASS" if blocking_pass else "FAIL"))
sys.stderr.write("======================================================================\n")

sys.exit(0 if blocking_pass else 1)
PY
PY_RC=$?

if [[ "$KEEP_LOGS" -eq 0 && "$PY_RC" -eq 0 ]]; then
  rm -rf "$RESULTS_DIR"
fi

log ""
log "evidence: ${EVIDENCE_JSON}"
if [[ "$PY_RC" -eq 0 ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi
