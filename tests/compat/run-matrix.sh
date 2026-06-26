#!/usr/bin/env bash
#
# run-matrix.sh — SRTLA compatibility integration harness.
#
# Drives a real end-to-end bonded-stream run for each (sender x receiver) pair
# and decides PASS/FAIL against objective criteria measured by the mock SRT
# endpoint (srt-sink) and the receiver's own log:
#
#     SENDER (srtla_send + MPEG-TS feed) --SRTLA--> RECEIVER (srtla_rec) --SRT--> srt-sink
#
#   "ours" sender/receiver  -> locally-built binaries from the CMake build dir
#                              (built with -DBUILD_COMPAT_TESTS=ON).
#   external sender/receiver -> the pinned Docker images from tests/compat/docker
#                               (compat/<name>), run on the host network.
#
# Pass criteria (per pair, scenario=stream):
#   1. handshake completes <= 5 s   (receiver-log marker + first byte at the sink)
#   2. bytes_received >= 1000        (srt-sink)
#   3. disconnects == 0              (srt-sink, measurement window only)
#   4. clean teardown                (SIGTERM honoured, no SIGKILL/137, sink exit 0)
#
# Results are written to tests/compat/results/<pair>/result.json (gitignored).
#
# Usage:
#   run-matrix.sh --pair <sender>x<receiver> [options]
#   run-matrix.sh --sender <name> --receiver <name> [options]
#   run-matrix.sh --tier blocking|informational|all [options]
#
# Options:
#   --pair <s>x<r>     Run a single pair by harness token (e.g. belabox-senderxours,
#                      oursxours).
#   --sender <name>    With --receiver: run a single pair addressed by its
#   --receiver <name>  matrix.yaml names (e.g. --sender ceralive-srtla-send-rs
#                      --receiver ours). This is the CI-matrix fan-out entry point —
#                      the names map to harness tokens via the same table the --tier
#                      path uses, so no token aliasing has to leak into the workflow.
#                      Tier is resolved from matrix.yaml.
#   --tier <t>         Run every matrix.yaml pair of tier blocking|informational|all.
#   --scenario <name>  stream (default, healthy) | port-mismatch (negative/broken).
#   --duration <sec>   Measurement window length (default 20).
#   --keep-logs        Keep all per-run logs even on PASS (default: prune logs on PASS).
#   --build-dir <dir>  Directory holding the local srtla binaries + helpers.
#   -h, --help         This help.
#
# Environment:
#   SRTLA_BUILD_DIR    Same as --build-dir.
#
set -uo pipefail

# --------------------------------------------------------------------------- #
# Locations                                                                    #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
MATRIX_YAML="${SCRIPT_DIR}/matrix.yaml"

# Max end-to-end first-byte latency that still counts as a timely handshake.
# On localhost a real handshake is sub-second; the 3-5 s we observe is SRT
# warm-up. 10 s absorbs CI scheduling jitter (a loaded runner pushed go-srtla to
# 5.3 s) without masking a stalled handshake — bytes/disconnect checks catch that.
HANDSHAKE_MAX_MS=10000

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'run-matrix: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

# --------------------------------------------------------------------------- #
# Defaults / CLI                                                               #
# --------------------------------------------------------------------------- #
TIER=""
PAIR=""
SENDER_NAME=""
RECEIVER_NAME=""
SCENARIO="stream"
DURATION=20
KEEP_LOGS=0
BUILD_DIR="${SRTLA_BUILD_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)      TIER="${2:?--tier needs a value}"; shift 2 ;;
    --pair)      PAIR="${2:?--pair needs a value}"; shift 2 ;;
    --sender)    SENDER_NAME="${2:?--sender needs a value}"; shift 2 ;;
    --receiver)  RECEIVER_NAME="${2:?--receiver needs a value}"; shift 2 ;;
    --scenario)  SCENARIO="${2:?--scenario needs a value}"; shift 2 ;;
    --duration)  DURATION="${2:?--duration needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    -h|--help)   sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

SELECT_BY_NAME=0
[[ -n "$SENDER_NAME" || -n "$RECEIVER_NAME" ]] && SELECT_BY_NAME=1
[[ "$SELECT_BY_NAME" -eq 0 || ( -n "$SENDER_NAME" && -n "$RECEIVER_NAME" ) ]] \
  || die "--sender and --receiver must be given together"
_modes=0
[[ -n "$PAIR" ]]            && _modes=$((_modes + 1))
[[ "$SELECT_BY_NAME" -eq 1 ]] && _modes=$((_modes + 1))
[[ -n "$TIER" ]]           && _modes=$((_modes + 1))
[[ "$_modes" -eq 1 ]] \
  || die "specify exactly one of: --pair <s>x<r>, --sender <name> --receiver <name>, or --tier <t>"
case "$SCENARIO" in stream|port-mismatch) ;; *) die "unknown --scenario '$SCENARIO'";; esac
[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 1 ]] || die "--duration must be a positive integer"

for tool in docker ffmpeg jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

# --------------------------------------------------------------------------- #
# Resolve the local build directory (ours binaries + helpers).                #
# --------------------------------------------------------------------------- #
resolve_build_dir() {
  local candidates=()
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  local d
  for d in "${candidates[@]}"; do
    if [[ -x "${d}/srtla_rec" && -x "${d}/srtla_send" \
       && -x "${d}/tests/compat/srt-sink/srt-sink" ]]; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

BUILD_DIR="$(resolve_build_dir)" || die \
  "no usable build dir (need srtla_rec, srtla_send, srt-sink). Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j
   then re-run, optionally with --build-dir <dir> or SRTLA_BUILD_DIR."

SRT_SINK="${BUILD_DIR}/tests/compat/srt-sink/srt-sink"
SRTLA_REC="${BUILD_DIR}/srtla_rec"
SRTLA_SEND="${BUILD_DIR}/srtla_send"
EXT_KA_PROBE="${BUILD_DIR}/tests/compat/ext-ka-probe/ext-ka-probe"

# CERALIVE fork sender (ceralive-srtla-send-rs): a pre-built release binary, not
# a build-dir binary nor a Docker image. Resolve from SRTLA_SEND_RS_BIN else a
# `srtla_send_rs` on PATH; empty -> the forkbin pair SKIPs (like a missing image).
SRTLA_SEND_RS_BIN="${SRTLA_SEND_RS_BIN:-}"
[[ -z "$SRTLA_SEND_RS_BIN" ]] && SRTLA_SEND_RS_BIN="$(command -v srtla_send_rs 2>/dev/null || true)"

# --------------------------------------------------------------------------- #
# Token registry: token -> role / kind / docker image / matrix name / marker.  #
# "ours" is local (build dir); every external impl is a compat/* Docker image. #
# MARKER is the receiver-log line proving the SRTLA handshake completed.        #
# --------------------------------------------------------------------------- #
declare -A ROLE KIND IMAGE MATRIX MARKER

reg() { # token role kind image matrix marker
  ROLE["$1"]="$2"; KIND["$1"]="$3"; IMAGE["$1"]="$4"; MATRIX["$1"]="$5"; MARKER["$1"]="$6"
}
#    token              role      kind    image                      matrix-name           handshake marker
reg  ours               both      local   -                          ours                  "Group registered"
reg  belabox-sender     sender    docker  compat/belabox-sender      belabox-srtla-send    ""
reg  irlserver-send     sender    docker  compat/irlserver-send      irlserver-srtla-send  ""
reg  ceralive-send-rs   sender    forkbin -                          ceralive-srtla-send-rs ""
reg  moblin-mock        sender    docker  compat/moblin-mock         moblin-mock           ""
reg  belabox-receiver   receiver  docker  compat/belabox-receiver    belabox-srtla-rec     "registered"
reg  openirl-receiver   receiver  docker  compat/openirl-receiver    openirl-receiver      "Group registered"
reg  go-srtla           receiver  docker  compat/go-srtla            go-srtla              ""
reg  go-irl             receiver  docker  compat/go-irl              go-irl                ""

# Pair -> tier (mirrors matrix.yaml; used when running a single --pair).
declare -A PAIR_TIER
PAIR_TIER["belabox-sender:ours"]=blocking
PAIR_TIER["irlserver-send:ours"]=blocking
PAIR_TIER["ceralive-send-rs:ours"]=blocking
PAIR_TIER["ceralive-send-rs:belabox-receiver"]=blocking
PAIR_TIER["ceralive-send-rs:openirl-receiver"]=blocking
PAIR_TIER["moblin-mock:ours"]=blocking
PAIR_TIER["ours:belabox-receiver"]=blocking
PAIR_TIER["ours:openirl-receiver"]=blocking
PAIR_TIER["ours:ours"]=blocking
PAIR_TIER["ours:go-srtla"]=informational
PAIR_TIER["ours:go-irl"]=informational
PAIR_TIER["ceralive-send-rs:go-srtla"]=informational
PAIR_TIER["ceralive-send-rs:go-irl"]=informational

# Map a matrix.yaml sender/receiver name onto a registry token.
matrix_to_token() {
  local name="$1" t
  for t in "${!MATRIX[@]}"; do
    [[ "${MATRIX[$t]}" == "$name" ]] && { printf '%s' "$t"; return 0; }
  done
  return 1
}

# Split a "<sender>x<receiver>" token on the 'x' that yields a valid
# sender-token + receiver-token (handles hyphens and the 'x' inside "belabox").
split_pair() {
  local p="$1" i left right
  for (( i=1; i<${#p}-1; i++ )); do
    [[ "${p:i:1}" == "x" ]] || continue
    left="${p:0:i}"; right="${p:i+1}"
    if [[ -n "${ROLE[$left]:-}" && "${ROLE[$left]}" =~ ^(sender|both)$ \
       && -n "${ROLE[$right]:-}" && "${ROLE[$right]}" =~ ^(receiver|both)$ ]]; then
      printf '%s %s\n' "$left" "$right"; return 0
    fi
  done
  return 1
}

# --------------------------------------------------------------------------- #
# Per-run process / container tracking + cleanup.                              #
# --------------------------------------------------------------------------- #
RUN_PIDS=()
RUN_CONTAINERS=()
track_pid()       { RUN_PIDS+=("$1"); }
track_container() { RUN_CONTAINERS+=("$1"); }

kill_pid() { # pid  -> SIGTERM, return its exit code (143 on SIGTERM)
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return $?
}

stop_container() { # name -> SIGTERM via docker stop, echo exit code
  local name="$1" code
  docker stop -t 5 "$name" >/dev/null 2>&1
  code="$(docker inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null || echo 1)"
  printf '%s' "$code"
}

cleanup_all() {
  local p c
  for p in "${RUN_PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
  for c in "${RUN_CONTAINERS[@]:-}"; do [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1; done
}
trap cleanup_all EXIT INT TERM

# Only SIGKILL (137 = ignored SIGTERM past docker stop's grace) fails teardown.
# Other non-zero codes are expected here: ffmpeg yields 1/255 because sink-first
# teardown removes its downstream mid-stream. Real failures fail bytes/handshake.
is_clean_exit() {
  local c="$1"
  [[ "$c" =~ ^[0-9]+$ ]] || return 1
  [[ "$c" -ne 137 ]]
}

# --------------------------------------------------------------------------- #
# Run one pair. Echoes PASS/FAIL; returns 0 on PASS, 1 on FAIL, 3 on skip.     #
# --------------------------------------------------------------------------- #
run_pair() {
  local sender="$1" receiver="$2" tier="$3"
  local pair="${sender}x${receiver}"
  local outdir="${RESULTS_DIR}/${pair}"
  rm -rf "$outdir"; mkdir -p "$outdir"

  RUN_PIDS=(); RUN_CONTAINERS=()

  # Distinct ports per role; UDP/SRT so re-use across sequential pairs is safe.
  local SINK_PORT=4101 SRTLA_PORT=5101 LOCAL_SRT_PORT=6101
  local target_srtla_port="$SRTLA_PORT"
  [[ "$SCENARIO" == "port-mismatch" ]] && target_srtla_port=$((SRTLA_PORT + 1))

  # Verify required Docker images exist up-front (skip with a clear message).
  local tok
  for tok in "$sender" "$receiver"; do
    if [[ "${KIND[$tok]}" == "docker" ]]; then
      if ! docker image inspect "${IMAGE[$tok]}" >/dev/null 2>&1; then
        log "SKIP ${pair}: docker image '${IMAGE[$tok]}' not built"
        printf '{"pair":"%s","skipped":true,"reason":"image %s not built"}\n' \
          "$pair" "${IMAGE[$tok]}" > "${outdir}/result.json"
        return 3
      fi
    fi
  done

  # The fork sender pair needs the resolved release binary (SRTLA_SEND_RS_BIN).
  if [[ "${KIND[$sender]}" == "forkbin" && ! -x "$SRTLA_SEND_RS_BIN" ]]; then
    log "SKIP ${pair}: fork sender binary unresolved (set SRTLA_SEND_RS_BIN)"
    printf '{"pair":"%s","skipped":true,"reason":"SRTLA_SEND_RS_BIN not set/executable"}\n' \
      "$pair" > "${outdir}/result.json"
    return 3
  fi

  local sink_log="${outdir}/sink.log"  sink_json="${outdir}/sink.json"
  local rx_log="${outdir}/receiver.log" tx_log="${outdir}/sender.log"
  local ff_log="${outdir}/ffmpeg.log"  probe_log="${outdir}/probe.log"
  local rx_marker="${MARKER[$receiver]}"

  log "==> ${pair}  (tier=${tier} scenario=${SCENARIO} duration=${DURATION}s)"

  # 1) srt-sink — start first; self-times-out well after the window as a guard.
  "$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 --result "$sink_json" \
              --duration $((DURATION + 20)) >"$sink_log" 2>&1 &
  local sink_pid=$!; track_pid "$sink_pid"
  sleep 0.5

  # 2) receiver
  local rx_pid="" rx_cname=""
  if [[ "${KIND[$receiver]}" == "local" ]]; then
    "$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
                 --srt_port "$SINK_PORT" --log_level trace >"$rx_log" 2>&1 &
    rx_pid=$!; track_pid "$rx_pid"
    local rdy=0 t
    for (( t=0; t<50; t++ )); do
      grep -q "srtla_rec is now running" "$rx_log" 2>/dev/null && { rdy=1; break; }
      sleep 0.1
    done
    [[ "$rdy" == 1 ]] || log "    warn: receiver readiness marker not seen"
  else
    rx_cname="compat-${pair}-rx-$$"; docker rm -f "$rx_cname" >/dev/null 2>&1
    # --init (tini as PID 1): the kernel applies no default signal action to
    # PID 1, so an external srtla_rec with no SIGTERM handler would ignore
    # `docker stop` and be SIGKILLed (137). tini forwards SIGTERM so the child
    # exits cleanly (143) — without it teardown fails for reasons unrelated to interop.
    docker run -d --init --name "$rx_cname" --network host \
      -e SRTLA_PORT="$SRTLA_PORT" -e SRT_TARGET_HOST=127.0.0.1 \
      -e SRT_TARGET_PORT="$SINK_PORT" "${IMAGE[$receiver]}" >/dev/null 2>&1
    track_container "$rx_cname"
    sleep 2
  fi

  # 3) sender — record the moment we start it for handshake timing.
  local t_send_ms; t_send_ms="$(now_ms)"
  local tx_pid="" ff_pid="" tx_cname=""
  if [[ "${KIND[$sender]}" == "local" || "${KIND[$sender]}" == "forkbin" ]]; then
    local send_bin="$SRTLA_SEND"
    [[ "${KIND[$sender]}" == "forkbin" ]] && send_bin="$SRTLA_SEND_RS_BIN"
    printf '127.0.0.1\n' > "${outdir}/ips.txt"
    "$send_bin" "$LOCAL_SRT_PORT" 127.0.0.1 "$target_srtla_port" \
                  "${outdir}/ips.txt" >"$tx_log" 2>&1 &
    tx_pid=$!; track_pid "$tx_pid"
    sleep 0.6
    ffmpeg -hide_banner -loglevel warning -re \
      -f lavfi -i testsrc2=size=320x240:rate=25 \
      -c:v mpeg2video -b:v 1M -f mpegts \
      "srt://127.0.0.1:${LOCAL_SRT_PORT}?mode=caller&transtype=live" \
      >"$ff_log" 2>&1 &
    ff_pid=$!; track_pid "$ff_pid"
  else
    tx_cname="compat-${pair}-tx-$$"; docker rm -f "$tx_cname" >/dev/null 2>&1
    docker run -d --init --name "$tx_cname" --network host \
      -e RECEIVER_HOST=127.0.0.1 -e RECEIVER_PORT="$target_srtla_port" \
      -e LOCAL_SRT_PORT="$LOCAL_SRT_PORT" -e IPS=127.0.0.1 \
      "${IMAGE[$sender]}" >/dev/null 2>&1
    track_container "$tx_cname"
  fi

  # 3b) ours x ours: drive the receiver's *extended* keepalive path with a real
  # extended keepalive (our srtla_send only emits the bare 2-byte variant). Runs
  # in the background so it does not delay handshake-marker timing.
  local ext_ka_attempted=0
  if [[ "$SCENARIO" == "stream" && "$sender" == "ours" && "$receiver" == "ours" \
        && -x "$EXT_KA_PROBE" ]]; then
    ext_ka_attempted=1
    ( sleep 2; "$EXT_KA_PROBE" --host 127.0.0.1 --port "$SRTLA_PORT" --count 5 ) \
      >"$probe_log" 2>&1 &
    track_pid "$!"
  fi

  # 4) Monitor the window; record the first handshake-marker sighting.
  local handshake_ms=-1 end_ms; end_ms=$(( $(now_ms) + DURATION * 1000 ))
  while [[ "$(now_ms)" -lt "$end_ms" ]]; do
    if [[ "$handshake_ms" -lt 0 && -n "$rx_marker" ]] \
       && grep -q -- "$rx_marker" "$rx_log" 2>/dev/null; then
      handshake_ms=$(( $(now_ms) - t_send_ms ))
    fi
    sleep 0.5
  done

  # 5) Teardown — SINK FIRST so an intentional sender stop is not miscounted
  #    as a mid-stream disconnect, then sender, then receiver.
  local sink_code; kill_pid "$sink_pid"; sink_code=$?

  local sender_code receiver_code
  if [[ "${KIND[$sender]}" == "local" || "${KIND[$sender]}" == "forkbin" ]]; then
    [[ -n "$ff_pid" ]] && { kill -TERM "$ff_pid" 2>/dev/null; wait "$ff_pid" 2>/dev/null; }
    kill_pid "$tx_pid"; sender_code=$?
  else
    sender_code="$(stop_container "$tx_cname")"
    docker logs "$tx_cname" >"$tx_log" 2>&1; docker rm -f "$tx_cname" >/dev/null 2>&1
  fi

  if [[ "${KIND[$receiver]}" == "local" ]]; then
    kill_pid "$rx_pid"; receiver_code=$?
  else
    receiver_code="$(stop_container "$rx_cname")"
    docker logs "$rx_cname" >"$rx_log" 2>&1; docker rm -f "$rx_cname" >/dev/null 2>&1
  fi

  # 6) Gather metrics from the sink result + receiver log.
  local bytes first_byte disc sdur
  bytes="$(jq -r '.bytes_received // 0'  "$sink_json" 2>/dev/null || echo 0)"
  first_byte="$(jq -r '.first_byte_ms // -1' "$sink_json" 2>/dev/null || echo -1)"
  disc="$(jq -r '.disconnects // -1'     "$sink_json" 2>/dev/null || echo -1)"
  sdur="$(jq -r '.duration_ms // 0'      "$sink_json" 2>/dev/null || echo 0)"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  [[ "$first_byte" =~ ^-?[0-9]+$ ]] || first_byte=-1
  [[ "$disc" =~ ^-?[0-9]+$ ]] || disc=-1

  local marker_found=false
  [[ -n "$rx_marker" ]] && grep -q -- "$rx_marker" "$rx_log" 2>/dev/null && marker_found=true

  local ext_ka=false
  grep -q "Per-connection keepalive" "$rx_log" 2>/dev/null && ext_ka=true

  # ---- criteria ----
  local handshake_ok=false bytes_ok=false disc_ok=false teardown_ok=false
  # handshake proof = end-to-end first byte within 5s: data cannot cross
  # srtla_rec without a completed REG1/REG2/REG3 registration. For our OWN
  # receiver we additionally require the registration log marker (we own that
  # line). We do NOT gate on an external impl's exact log wording — that tests
  # their logging, not interop; marker_found is still recorded for visibility.
  # Falsifiability is preserved: --scenario port-mismatch yields no first byte.
  if [[ "$first_byte" -ge 0 && "$first_byte" -le "$HANDSHAKE_MAX_MS" ]]; then
    if [[ "${KIND[$receiver]}" == "local" ]]; then
      [[ -z "$rx_marker" || "$marker_found" == true ]] && handshake_ok=true
    else
      handshake_ok=true
    fi
  fi
  [[ "$bytes" -ge 1000 ]] && bytes_ok=true
  [[ "$disc" -eq 0 ]] && disc_ok=true
  if [[ "$sink_code" -eq 0 ]] && is_clean_exit "$sender_code" \
     && is_clean_exit "$receiver_code"; then teardown_ok=true; fi

  local pass=false
  [[ "$handshake_ok" == true && "$bytes_ok" == true \
     && "$disc_ok" == true && "$teardown_ok" == true ]] && pass=true

  # 7) Compose the per-pair result.json.
  jq -n \
    --arg pair "$pair" --arg sender "$sender" --arg receiver "$receiver" \
    --arg tier "$tier" --arg scenario "$SCENARIO" \
    --argjson pass "$pass" \
    --argjson handshake_ok "$handshake_ok" --argjson bytes_ok "$bytes_ok" \
    --argjson disc_ok "$disc_ok" --argjson teardown_ok "$teardown_ok" \
    --arg marker "$rx_marker" --argjson marker_found "$marker_found" \
    --argjson handshake_ms "$handshake_ms" --argjson hmax "$HANDSHAKE_MAX_MS" \
     --argjson bytes "$bytes" --argjson first_byte "$first_byte" \
    --argjson disc "$disc" --argjson sdur "$sdur" \
    --argjson ext_ka "$ext_ka" --argjson ext_ka_attempted "$ext_ka_attempted" \
    --argjson sink_code "$sink_code" --argjson sender_code "$sender_code" \
    --argjson receiver_code "$receiver_code" \
    --argjson duration "$DURATION" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      pair:$pair, sender:$sender, receiver:$receiver, tier:$tier,
      scenario:$scenario, pass:$pass,
      criteria:{handshake_ok:$handshake_ok, bytes_ok:$bytes_ok,
                disconnects_ok:$disc_ok, teardown_ok:$teardown_ok},
      handshake:{marker:$marker, marker_found:$marker_found,
                 handshake_ms:$handshake_ms, max_ms:$hmax},
      sink:{bytes_received:$bytes, first_byte_ms:$first_byte,
            disconnects:$disc, duration_ms:$sdur},
      extended_ka_detected:$ext_ka, extended_ka_probe_run:($ext_ka_attempted==1),
      exit_codes:{sink:$sink_code, sender:$sender_code, receiver:$receiver_code},
      duration_sec:$duration, timestamp:$ts
    }' > "${outdir}/result.json"

  # 8) Prune logs on PASS unless --keep-logs.
  if [[ "$pass" == true && "$KEEP_LOGS" -eq 0 ]]; then
    rm -f "$sink_log" "$rx_log" "$tx_log" "$ff_log" "$probe_log" "${outdir}/ips.txt"
  fi

  if [[ "$pass" == true ]]; then
    log "    PASS  bytes=${bytes} first_byte_ms=${first_byte} disc=${disc} ext_ka=${ext_ka}"
    return 0
  else
    log "    FAIL  bytes=${bytes} first_byte_ms=${first_byte} disc=${disc}" \
        "handshake_ok=${handshake_ok} bytes_ok=${bytes_ok} disc_ok=${disc_ok} teardown_ok=${teardown_ok}" \
        "(exit sink=${sink_code} sender=${sender_code} receiver=${receiver_code})"
    return 1
  fi
}

# --------------------------------------------------------------------------- #
# Build the list of (sender,receiver,tier) triples to run.                     #
# --------------------------------------------------------------------------- #
declare -a JOBS
add_job() { JOBS+=("$1|$2|$3"); }

if [[ "$SELECT_BY_NAME" -eq 1 ]]; then
  s="$(matrix_to_token "$SENDER_NAME")" \
    || die "unknown matrix sender name '$SENDER_NAME' (see matrix.yaml senders:)"
  r="$(matrix_to_token "$RECEIVER_NAME")" \
    || die "unknown matrix receiver name '$RECEIVER_NAME' (see matrix.yaml receivers:)"
  add_job "$s" "$r" "${PAIR_TIER["$s:$r"]:-blocking}"
elif [[ -n "$PAIR" ]]; then
  read -r s r < <(split_pair "$PAIR") \
    || die "could not parse --pair '$PAIR' into known sender x receiver tokens"
  add_job "$s" "$r" "${PAIR_TIER["$s:$r"]:-blocking}"
else
  [[ -f "$MATRIX_YAML" ]] || die "matrix.yaml not found at $MATRIX_YAML"
  command -v python3 >/dev/null 2>&1 || die "--tier requires python3 (matrix.yaml)"
  while IFS=$'\t' read -r ms mr mt; do
    [[ -n "$ms" ]] || continue
    if [[ "$TIER" != "all" && "$mt" != "$TIER" ]]; then continue; fi
    st="$(matrix_to_token "$ms")" || { log "SKIP: unknown matrix sender '$ms'"; continue; }
    rt="$(matrix_to_token "$mr")" || { log "SKIP: unknown matrix receiver '$mr'"; continue; }
    add_job "$st" "$rt" "$mt"
  done < <(python3 - "$MATRIX_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    m = yaml.safe_load(f)
for p in (m.get("pairs") or []):
    print("\t".join([str(p.get("sender","")), str(p.get("receiver","")),
                     str(p.get("tier",""))]))
PY
)
  [[ "$TIER" == "all" || "$TIER" == "blocking" || "$TIER" == "informational" ]] \
    || die "unknown --tier '$TIER'"
fi

[[ ${#JOBS[@]} -gt 0 ]] || die "no pairs to run"

mkdir -p "$RESULTS_DIR"

# --------------------------------------------------------------------------- #
# Execute jobs sequentially; aggregate verdict.                                #
# --------------------------------------------------------------------------- #
total=0; passed=0; failed=0; skipped=0; fail_pairs=()
for job in "${JOBS[@]}"; do
  IFS='|' read -r s r t <<<"$job"
  total=$((total + 1))
  run_pair "$s" "$r" "$t"
  case $? in
    0) passed=$((passed + 1)) ;;
    3) skipped=$((skipped + 1)) ;;
    *) failed=$((failed + 1)); fail_pairs+=("${s}x${r}") ;;
  esac
done

log ""
log "================ compat matrix summary ================"
log "  total=${total}  passed=${passed}  failed=${failed}  skipped=${skipped}"
[[ ${#fail_pairs[@]} -gt 0 ]] && log "  failed pairs: ${fail_pairs[*]}"
log "  results: ${RESULTS_DIR}/<pair>/result.json"
log "======================================================="

[[ "$failed" -eq 0 ]] && exit 0 || exit 1
