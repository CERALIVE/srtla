#!/usr/bin/env bash
#
# build-libsrt-matrix.sh — reproducibly build the two libsrt artifacts the
# srt-patch A/B/C evaluation compares:
#
#   V (vanilla)  : stock Haivision libsrt          -> install/vanilla/
#   P (patched)  : CERALIVE/srt fork (BELABOX delta) -> install/patched/
#
# The fork's only divergence from upstream is a 6-line unconditional merge
# (f5800cd) in srtcore/core.cpp that silences the RTT log, disables
# reorder-tolerance decay, and disables periodic NAK reports. This script
# builds both libsrt.so so the harness can swap one for the other under
# srt-sink WITHOUT touching the system libsrt or the sibling ../srt checkout.
#
# ─ Output (all under the repo-local, gitignored test-results/ tree) ──────────
#   test-results/libsrt-matrix/install/vanilla/   CMAKE_INSTALL_PREFIX for V
#   test-results/libsrt-matrix/install/patched/   CMAKE_INSTALL_PREFIX for P
#   test-results/libsrt-matrix/manifest.txt       resolved SHAs + sha256 of each .so
#
# ─ Swapping srt-sink's libsrt (how the A/B/C evaluation consumes this) ───────
#   srt-sink links the system libsrt dynamically (SONAME libsrt.so.1.5). Point
#   the loader at either prefix to run srt-sink against that build — no relink:
#
#     SINK=build/tests/compat/srt-sink/srt-sink
#     # A = vanilla
#     LD_LIBRARY_PATH=test-results/libsrt-matrix/install/vanilla/lib ldd "$SINK" | grep libsrt
#     # B = patched
#     LD_LIBRARY_PATH=test-results/libsrt-matrix/install/patched/lib ldd "$SINK" | grep libsrt
#
#   ldd must resolve libsrt.so.* into the chosen prefix (not /usr/local/lib).
#
# ─ Reproducible 6-line delta (optional, for a clean A↔B comparison) ──────────
#   By default V tracks Haivision HEAD and P tracks the fork HEAD, which may sit
#   on different upstream bases. For a delta that is EXACTLY the BELABOX patch,
#   pin both refs to the fork lineage:
#
#     build-libsrt-matrix.sh \
#       --vanilla-url https://github.com/CERALIVE/srt --vanilla-ref f5800cd~1 \
#       --patched-url https://github.com/CERALIVE/srt --patched-ref f5800cd
#
# ─ Usage ─────────────────────────────────────────────────────────────────────
#   build-libsrt-matrix.sh [options]
#     --vanilla-url <url>   default https://github.com/Haivision/srt
#     --vanilla-ref <ref>   sha/tag/branch; default: remote HEAD
#     --patched-url <url>   default https://github.com/CERALIVE/srt
#     --patched-ref <ref>   sha/tag/branch; default: remote HEAD
#     --jobs <n>            parallel build jobs; default: nproc
#     -h | --help
#
# Constraints: never installs system-wide, never reads/writes above the repo
# root, never touches the ../srt sibling checkout (Rule D). Vanilla srt is
# cloned by this script; the patched fork URL is an argument.

set -euo pipefail

# ── Locate repo root from this script's own path (no ../-escaping in tracked
#    files; resolved at runtime) ───────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"

OUT_DIR="${REPO_ROOT}/test-results/libsrt-matrix"
INSTALL_DIR="${OUT_DIR}/install"
MANIFEST="${OUT_DIR}/manifest.txt"

VANILLA_URL="https://github.com/Haivision/srt"
VANILLA_REF=""
PATCHED_URL="https://github.com/CERALIVE/srt"
PATCHED_REF=""
JOBS="$(nproc 2>/dev/null || echo 4)"

die() { printf 'build-libsrt-matrix: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vanilla-url) VANILLA_URL="${2:?--vanilla-url needs a value}"; shift 2 ;;
    --vanilla-ref) VANILLA_REF="${2:?--vanilla-ref needs a value}"; shift 2 ;;
    --patched-url) PATCHED_URL="${2:?--patched-url needs a value}"; shift 2 ;;
    --patched-ref) PATCHED_REF="${2:?--patched-ref needs a value}"; shift 2 ;;
    --jobs)        JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help)     sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
done

for tool in git cmake; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# ── Scratch clones land in a temp dir, removed on exit; nothing is left in the
#    source tree and the ../srt sibling is never read ──────────────────────────
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/libsrt-matrix.XXXXXX")"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# clone_at <url> <ref> <dest>  -> echoes the resolved 40-char SHA on stdout
clone_at() {
  local url="$1" ref="$2" dest="$3"
  if [[ -n "$ref" ]]; then
    # Fetch only what we need, then check out the exact ref.
    git clone --quiet --no-checkout "$url" "$dest" >&2
    git -C "$dest" fetch --quiet origin "$ref" >&2 2>/dev/null || true
    git -C "$dest" checkout --quiet --detach "$ref" >&2
  else
    git clone --quiet --depth 1 "$url" "$dest" >&2
  fi
  git -C "$dest" rev-parse HEAD
}

# build_libsrt <src> <prefix>  -> configure + build + install shared libsrt
build_libsrt() {
  local src="$1" prefix="$2" bdir="${1}-build"
  cmake -S "$src" -B "$bdir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=OFF \
    -DENABLE_APPS=OFF \
    -DENABLE_UNITTESTS=OFF >&2
  cmake --build "$bdir" -j"$JOBS" >&2
  cmake --install "$bdir" >&2
}

# Resolve the installed libsrt.so SONAME target inside a prefix.
find_libsrt_so() {
  local prefix="$1"
  # Prefer the real (non-symlink) shared object so sha256 reflects bytes built.
  find "${prefix}" -name 'libsrt.so.*' -type f 2>/dev/null | sort | head -1
}

rm -rf "${OUT_DIR}"
mkdir -p "${INSTALL_DIR}/vanilla" "${INSTALL_DIR}/patched"

log "vanilla : ${VANILLA_URL} @ ${VANILLA_REF:-HEAD}"
VANILLA_SHA="$(clone_at "$VANILLA_URL" "$VANILLA_REF" "${WORK_DIR}/vanilla")"
log "vanilla SHA ${VANILLA_SHA}"
build_libsrt "${WORK_DIR}/vanilla" "${INSTALL_DIR}/vanilla"

log "patched : ${PATCHED_URL} @ ${PATCHED_REF:-HEAD}"
PATCHED_SHA="$(clone_at "$PATCHED_URL" "$PATCHED_REF" "${WORK_DIR}/patched")"
log "patched SHA ${PATCHED_SHA}"
build_libsrt "${WORK_DIR}/patched" "${INSTALL_DIR}/patched"

VANILLA_SO="$(find_libsrt_so "${INSTALL_DIR}/vanilla")"
PATCHED_SO="$(find_libsrt_so "${INSTALL_DIR}/patched")"
[[ -n "$VANILLA_SO" ]] || die "vanilla libsrt.so not found under ${INSTALL_DIR}/vanilla"
[[ -n "$PATCHED_SO" ]] || die "patched libsrt.so not found under ${INSTALL_DIR}/patched"

VANILLA_HASH="$(sha256sum "$VANILLA_SO" | awk '{print $1}')"
PATCHED_HASH="$(sha256sum "$PATCHED_SO" | awk '{print $1}')"

{
  echo "# libsrt build matrix — generated by tests/compat/lib/build-libsrt-matrix.sh"
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "[vanilla]"
  echo "url    = ${VANILLA_URL}"
  echo "ref    = ${VANILLA_REF:-HEAD}"
  echo "sha    = ${VANILLA_SHA}"
  echo "so     = ${VANILLA_SO#${REPO_ROOT}/}"
  echo "sha256 = ${VANILLA_HASH}"
  echo
  echo "[patched]"
  echo "url    = ${PATCHED_URL}"
  echo "ref    = ${PATCHED_REF:-HEAD}"
  echo "sha    = ${PATCHED_SHA}"
  echo "so     = ${PATCHED_SO#${REPO_ROOT}/}"
  echo "sha256 = ${PATCHED_HASH}"
} > "${MANIFEST}"

log "manifest written: ${MANIFEST#${REPO_ROOT}/}"
cat "${MANIFEST}"

if [[ "$VANILLA_HASH" == "$PATCHED_HASH" ]]; then
  die "vanilla and patched libsrt.so are byte-identical (sha256 ${VANILLA_HASH}). \
The refs may resolve to the same tree; pin distinct --vanilla-ref / --patched-ref."
fi

log "OK: vanilla and patched libsrt.so differ"
log "  vanilla ${VANILLA_HASH}  ${VANILLA_SO#${REPO_ROOT}/}"
log "  patched ${PATCHED_HASH}  ${PATCHED_SO#${REPO_ROOT}/}"
log "swap srt-sink with: LD_LIBRARY_PATH=${INSTALL_DIR#${REPO_ROOT}/}/<vanilla|patched>/lib ldd build/tests/compat/srt-sink/srt-sink | grep libsrt"
