#!/usr/bin/env bash
#
# ab-campaign.sh — run a pre-registered A/B campaign from its scenario document.
#
# The document (tests/compat/scenarios/ab-*.yaml) owns the arms, the groups, the
# run count and the frozen decision rule. This script owns the mechanics: it
# expands the document into the exact ordered run plan, executes each run through
# the document's `instrument`, appends one row per run to rows.json, and hands
# rows.json to tests/compat/lib/ab-verdict.py. It never inspects a metric and
# never decides a winner — that separation is the whole point of pre-registration.
#
# Execution model (per run):
#   * the arm's `apply` knobs (e.g. PERIODICNAKGATE) are passed as environment to
#     the instrument, as are the group's (`STEADY_LOSS_PCT`, `REORDER_PCT`, ...);
#   * the receiver libsrt is selected with SINK_LD_LIBRARY_PATH;
#   * the instrument runs under `sudo -n env ...` because it needs CAP_NET_ADMIN;
#   * an invalid run (harness error, missing metric, capture < 90 % of the
#     scenario duration) is retried ONCE, and only the final attempt of each
#     (arm, cell, run) slot is recorded, so rows.json is exactly
#     arms x cells x runs_per_group rows.
#
# One campaign at a time is enforced with an exclusive flock on
# tests/compat/results/<scenario>.lock; a second concurrent launch is refused.
#
# Usage:
#   ab-campaign.sh --scenario <name> --plan         # print the run plan, exit 0
#   ab-campaign.sh --scenario <name> --print-rule   # print the frozen rule
#   ab-campaign.sh --scenario <name> [options]      # execute the campaign
#
#   --scenario <name>  document stem, e.g. ab-periodic-nak
#   --plan             expand and print the plan only. Unprivileged, touches no
#                      network, builds nothing — this is the mode CI and a
#                      reviewer use.
#   --print-rule       print the document's frozen `rule:` scalar verbatim.
#   --out <dir>        where rows.json / verdict.json land
#                      (default: tests/compat/results/<scenario>/)
#   --build-dir <dir>  srtla build dir holding srtla_rec / srtla_send / srt-sink
#                      (default: $SRTLA_BUILD_DIR or <repo>/build)
#   --sink-lib <dir>   receiver libsrt prefix on SINK_LD_LIBRARY_PATH (default:
#                      <repo>/test-results/libsrt-matrix/install/patched/lib)
#   --sender-bin <path> srtla-send-rs binary (default: $SRTLA_SEND_RS_BIN)
#   --duration <sec>   instrument per-phase duration (default 14)
#   --seed <n>         fixed netem reorder seed for paired runs (default 20260920)
#   --keep-logs        passed through to the instrument (always on for a campaign)
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMPAT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${COMPAT_DIR}/../.." >/dev/null 2>&1 && pwd)"

die() { printf 'ab-campaign: %s\n' "$*" >&2; exit 2; }
log() { printf 'ab-campaign: %s\n' "$*" >&2; }

SCENARIO=""
MODE="execute"
OUT_DIR=""
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
SINK_LIB=""
SENDER_BIN="${SRTLA_SEND_RS_BIN:-}"
DURATION=14
DURATION_SET=0
SEED=20260920
DISK_FLOOR_BYTES=60000000000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)   SCENARIO="${2:?--scenario needs a value}"; shift 2 ;;
    --plan)       MODE="plan"; shift ;;
    --print-rule) MODE="rule"; shift ;;
    --out)        OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    --build-dir)  BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --sink-lib)   SINK_LIB="${2:?--sink-lib needs a value}"; shift 2 ;;
    --sender-bin) SENDER_BIN="${2:?--sender-bin needs a value}"; shift 2 ;;
    --duration)   DURATION="${2:?--duration needs a value}"; DURATION_SET=1; shift 2 ;;
    --seed)       SEED="${2:?--seed needs a value}"; shift 2 ;;
    --keep-logs)  shift ;;
    -h|--help)    sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument '$1' (try --help)" ;;
  esac
done

[[ -n "$SCENARIO" ]] || die "--scenario is required"
DOC="${COMPAT_DIR}/scenarios/${SCENARIO}.yaml"
[[ -f "$DOC" ]] || die "no such scenario document: ${DOC}"
: "${OUT_DIR:=${COMPAT_DIR}/results/${SCENARIO}}"
: "${BUILD_DIR:=${REPO_ROOT}/build}"
: "${SINK_LIB:=${REPO_ROOT}/test-results/libsrt-matrix/install/patched/lib}"

[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 1 ]] || die "--duration must be a positive integer"
[[ "$SEED" =~ ^[0-9]+$ ]] || die "--seed must be a non-negative integer"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v jq      >/dev/null 2>&1 || die "jq is required"

# --------------------------------------------------------------------------- #
# The scenario document drives the instrument output dir, the metrics parser,   #
# the per-run duration and whether a sink image is a precondition. Reading them #
# here keeps the driver campaign-agnostic: a campaign that measures receiver    #
# counters (D10) and one that measures the sender's log (D21) differ only in    #
# the document, not in this script.                                             #
# --------------------------------------------------------------------------- #
read -r DOC_DURATION INSTRUMENT_OUT_ABS PARSER_ABS IMPAIRMENT_START_S HAS_SINK < <(
  python3 - "$DOC" "$REPO_ROOT" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1]))
repo = sys.argv[2]
run = doc.get("run") or {}

def absify(path: str) -> str:
    return path if path.startswith("/") else f"{repo}/{path}"

out = absify(run.get("instrument_out") or "tests/compat/results/reorder-stress")
parser = absify(run.get("metrics_parser") or "tests/compat/lib/ab-row-metrics.py")
has_sink = "1" if (doc.get("stack") or {}).get("sink") else "0"
print(run.get("duration_s", 0) or 0, out, parser, run.get("impairment_start_s", 0) or 0, has_sink)
PY
) || die "could not read the run config from ${DOC}"

[[ "$DURATION_SET" -eq 1 || "$DOC_DURATION" == "0" ]] || DURATION="$DOC_DURATION"
[[ -f "$PARSER_ABS" ]] || die "metrics parser '${PARSER_ABS}' not found"

if [[ "$MODE" == "rule" ]]; then
  exec python3 "${COMPAT_DIR}/lib/ab-verdict.py" --print-rule "$DOC"
fi

PLAN="$(python3 - "$DOC" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1]))
group_key = doc["group_key"]
print(f"campaign : {doc['name']}")
print(f"instrument: {doc['instrument']}")
print(f"rule kind : {doc['decision']['kind']}")
print(f"runs      : {len(doc['arms'])} arms x {len(doc['groups'])} {group_key}s "
      f"x {doc['runs_per_group']} = "
      f"{len(doc['arms']) * len(doc['groups']) * doc['runs_per_group']} rows")
print("")
for arm in doc["arms"]:
    for group in doc["groups"]:
        for run in range(1, doc["runs_per_group"] + 1):
            settings = {**arm["apply"], **group["apply"]}
            rendered = " ".join(f"{k}={v}" for k, v in settings.items())
            print(f"  arm={arm['id']} {group_key}={group['id']} run={run} :: {rendered}")
PY
)" || die "could not expand ${DOC} (is PyYAML installed? see lib/requirements.txt)"

printf '%s\n' "$PLAN"

if [[ "$MODE" == "plan" ]]; then
  exit 0
fi

# --------------------------------------------------------------------------- #
# One campaign at a time — an exclusive lock held for this process's lifetime. #
# It lives outside the results tree (which privileged scenario runs can leave   #
# root-owned) so a campaign never depends on that tree being user-writable.     #
# --------------------------------------------------------------------------- #
LOCK_KEY="$(printf '%s' "$REPO_ROOT" | sha256sum | cut -c1-12)"
LOCK_FILE="${TMPDIR:-/tmp}/ab-campaign-${LOCK_KEY}-${SCENARIO}.lock"
# Never truncate the lock file before flock: a refused second launch must read
# the holder's pid back intact, and only the winning holder writes it.
: >>"$LOCK_FILE" 2>/dev/null || die "cannot create lock file ${LOCK_FILE}"
exec 9<>"$LOCK_FILE"
if ! flock -n 9; then
  holder="$(cat "$LOCK_FILE" 2>/dev/null || echo unknown)"
  printf 'ab-campaign: REFUSING to start a second %s campaign: lock %s is held (pid %s).\n' \
    "$SCENARIO" "$LOCK_FILE" "$holder" >&2
  exit 75
fi
printf '%s\n' "$$" >"$LOCK_FILE"

mkdir -p "${OUT_DIR}" || die "cannot create output dir ${OUT_DIR} (is tests/compat/results user-writable?)"

# --------------------------------------------------------------------------- #
# Preconditions (all captured to <out>/preconditions.txt).                    #
# --------------------------------------------------------------------------- #
disk_avail() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d ' '; }

[[ -n "$SENDER_BIN" ]] || die "--sender-bin (or SRTLA_SEND_RS_BIN) is required for execution"
[[ -x "$SENDER_BIN" ]] || die "sender binary '$SENDER_BIN' is not executable"
[[ -x "${BUILD_DIR}/srtla_rec" ]] || die "${BUILD_DIR}/srtla_rec missing (cmake -B build -DBUILD_COMPAT_TESTS=ON)"
[[ -x "${BUILD_DIR}/tests/compat/srt-sink/srt-sink" ]] || die "${BUILD_DIR}/tests/compat/srt-sink/srt-sink missing (rebuild with -DBUILD_COMPAT_TESTS=ON)"
[[ -d "$SINK_LIB" ]] || die "sink libsrt dir '$SINK_LIB' missing (tests/compat/lib/build-libsrt-matrix.sh --only patched)"
command -v sudo >/dev/null 2>&1 || die "sudo is required (the instrument needs CAP_NET_ADMIN)"

for mnt in / /mnt/development; do
  avail="$(disk_avail "$mnt")"
  [[ "$avail" =~ ^[0-9]+$ ]] || die "cannot read free space for $mnt"
  (( avail >= DISK_FLOOR_BYTES )) || die "disk floor: $mnt has ${avail} B free (< ${DISK_FLOOR_BYTES})"
done

# A sink image is a precondition only for a campaign whose document declares one
# (D10). A sender-log campaign (D21) has no Docker sink on the measured path.
SINK_IMAGE=""
SINK_SHA=""
if [[ "$HAS_SINK" == "1" ]]; then
  command -v docker >/dev/null 2>&1 || die "docker is required (sink precondition)"
  SINK_PRECOND="$(python3 - "$DOC" <<'PY' || die "sink precondition failed"
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1]))
sink = doc["stack"]["sink"]
if sink.get("resolved") is not True:
    sys.exit(f"scenario sink is unresolved: {sink}")
if not sink.get("image") or not sink.get("image_sha256"):
    sys.exit(f"scenario sink has no recorded image/sha256: {sink}")
print(f"{sink['image']}\t{sink['image_sha256']}")
PY
)"
  IFS=$'\t' read -r SINK_IMAGE SINK_SHA <<<"$SINK_PRECOND"
  docker image inspect "$SINK_IMAGE" >/dev/null 2>&1 \
    || die "recorded sink image '$SINK_IMAGE' is not present on this host"
fi

INSTRUMENT_REL="$(python3 - "$DOC" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["instrument"])
PY
)"
INSTRUMENT="${REPO_ROOT}/${INSTRUMENT_REL}"
[[ -f "$INSTRUMENT" ]] || die "instrument '$INSTRUMENT_REL' not found"

# --------------------------------------------------------------------------- #
# Per-arm receiver build. An arm whose `apply.patch` is non-null is a           #
# BUILD-TIME variant: the patch is applied to a scratch source tree (never to   #
# the checkout) and the resulting srtla_rec is selected for that arm's runs via  #
# SRTLA_REC_BIN. Arms without a patch share the base build dir's receiver.      #
# --------------------------------------------------------------------------- #
declare -A ARM_RECEIVER=()
ARM_BUILD_INFO="$(python3 - "$DOC" <<'PY' || die "could not read the arm patch map"
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1]))
for arm in doc["arms"]:
    patch = (arm.get("apply") or {}).get("patch")
    print(f"{arm['id']}\t{patch if patch else ''}")
PY
)"
if [[ -n "$ARM_BUILD_INFO" ]]; then
  while IFS=$'\t' read -r arm_id patch_rel; do
    [[ -n "$arm_id" ]] || continue
    if [[ -z "$patch_rel" ]]; then
      ARM_RECEIVER[$arm_id]="${BUILD_DIR}/srtla_rec"
      log "arm ${arm_id}: receiver=${ARM_RECEIVER[$arm_id]} (unpatched)"
    else
      patch_abs="$patch_rel"
      [[ "$patch_abs" = /* ]] || patch_abs="${REPO_ROOT}/${patch_rel}"
      [[ -f "$patch_abs" ]] || die "arm ${arm_id} patch '${patch_abs}' not found"
      out="${OUT_DIR}/receiver-build/${arm_id}/srtla_rec"
      log "arm ${arm_id}: building patched receiver from ${patch_rel}"
      bash "${COMPAT_DIR}/lib/build-receiver-variant.sh" \
        --repo "$REPO_ROOT" --patch "$patch_abs" --out "$out" \
        || die "could not build the receiver variant for arm ${arm_id}"
      ARM_RECEIVER[$arm_id]="$out"
      log "arm ${arm_id}: receiver=${out} (patched)"
    fi
  done <<< "$ARM_BUILD_INFO"
fi

{
  echo "campaign=${SCENARIO}"
  echo "instrument=${INSTRUMENT_REL}"
  echo "metrics_parser=${PARSER_ABS}"
  echo "instrument_out=${INSTRUMENT_OUT_ABS}"
  echo "build_dir=${BUILD_DIR}"
  echo "sink_lib=${SINK_LIB}"
  echo "sender_bin=${SENDER_BIN} sha256=$(sha256sum "$SENDER_BIN" | awk '{print $1}')"
  if [[ "$HAS_SINK" == "1" ]]; then
    echo "sink_image=${SINK_IMAGE}"
    echo "sink_image_sha256=${SINK_SHA}"
  else
    echo "sink_image=<none: campaign measures the sender log>"
  fi
  echo "duration_s=${DURATION}"
  echo "impairment_start_s=${IMPAIRMENT_START_S}"
  echo "netem_seed=${SEED}"
  echo "lock=${LOCK_FILE}"
  for arm_id in "${!ARM_RECEIVER[@]}"; do
    echo "receiver_${arm_id}=${ARM_RECEIVER[$arm_id]} sha256=$(sha256sum "${ARM_RECEIVER[$arm_id]}" | awk '{print $1}')"
  done
  echo "--- df -B1 ---"
  df -B1 / /mnt/development
} | tee "$OUT_DIR/preconditions.txt"

RUNS_DIR="${OUT_DIR}/runs"
ATTEMPT_LOG="${OUT_DIR}/attempts.log"
ROWS_TMP="${OUT_DIR}/rows.ndjson"
mkdir -p "$RUNS_DIR"
: > "$ATTEMPT_LOG"
: > "$ROWS_TMP"

EXPECTED_MS=$(( (5 + 2 * DURATION) * 1000 ))

PLAN_TSV="$(python3 - "$DOC" <<'PY'
import json
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1]))
for arm in doc["arms"]:
    for group in doc["groups"]:
        for run in range(1, doc["runs_per_group"] + 1):
            env = {**arm["apply"], **group["apply"]}
            print("\t".join([arm["id"], group["id"], str(run), json.dumps(env)]))
PY
)" || die "could not build the run plan"

while IFS=$'\t' read -r arm cell run env_json; do
  [[ -n "$arm" ]] || continue
  mapfile -t kvs < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$env_json")
  row=""
  attempt=0
  while (( attempt < 2 )); do
    attempt=$(( attempt + 1 ))
    label="${arm}_${cell}_run${run}_attempt${attempt}"
    log "run ${label}"
    sudo -n env \
      PATH="$PATH" \
      SINK_LD_LIBRARY_PATH="$SINK_LIB" \
      SRTLA_SEND_RS_BIN="$SENDER_BIN" \
      SRTLA_REC_BIN="${ARM_RECEIVER[$arm]:-${BUILD_DIR}/srtla_rec}" \
      IMPAIRMENT_START_S="$IMPAIRMENT_START_S" \
      REQUIRE_RS_SENDER=1 \
      PROFILE_LABEL="$label" \
      NETEM_SEED="$SEED" \
      ${kvs[@]+"${kvs[@]}"} \
      bash "$INSTRUMENT" --build-dir "$BUILD_DIR" --duration "$DURATION" --keep-logs \
      </dev/null >>"$ATTEMPT_LOG" 2>&1
    rc=$?
    sudo -n chmod -R a+rX "$INSTRUMENT_OUT_ABS" 2>/dev/null || true
    cp "${INSTRUMENT_OUT_ABS}/result.json" "${RUNS_DIR}/${label}.result.json" 2>/dev/null || true
    mkdir -p "${RUNS_DIR}/${label}.logs"
    cp -r "${INSTRUMENT_OUT_ABS}/." "${RUNS_DIR}/${label}.logs/" 2>/dev/null || true
    # The row extractor is chosen by the document's declared parser: D10 reads
    # receiver counters out of result.json, D21 reads the sender's log through
    # the same result.json (its path + window live there).
    if [[ "$(basename "$PARSER_ABS")" == "sender-log-metrics.py" ]]; then
      row="$(python3 "$PARSER_ABS" \
        --result "${INSTRUMENT_OUT_ABS}/result.json" --exit-code "$rc" \
        --arm "$arm" --scenario "$cell" --run "$run")" \
        || die "per-run metric extraction failed for ${label}"
    else
      row="$(python3 "$PARSER_ABS" \
        --result "${INSTRUMENT_OUT_ABS}/result.json" --exit-code "$rc" \
        --expected-ms "$EXPECTED_MS" --arm "$arm" --cell "$cell" --run "$run")" \
        || die "per-run metric extraction failed for ${label}"
    fi
    printf '%s rc=%s %s\n' "$label" "$rc" "$row" >> "$ATTEMPT_LOG"
    if [[ "$(jq -r '.valid' <<<"$row")" == "true" ]]; then
      break
    fi
  done
  printf '%s\n' "$row" >> "$ROWS_TMP"
done <<< "$PLAN_TSV"

jq -s '.' "$ROWS_TMP" > "${OUT_DIR}/rows.json" || die "could not assemble rows.json"
row_count="$(jq 'length' "${OUT_DIR}/rows.json")"
log "rows.json: ${row_count} rows"

WINNER="$(python3 "${COMPAT_DIR}/lib/ab-verdict.py" \
  "${OUT_DIR}/rows.json" "$DOC" --json "${OUT_DIR}/verdict.json")" \
  || die "verdict computation failed"
log "verdict.json: winner=${WINNER}"
log "evidence: ${OUT_DIR}/rows.json ${OUT_DIR}/verdict.json"
exit 0
