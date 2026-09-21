#!/usr/bin/env bash
#
# build-receiver-variant.sh — build srtla_rec from HEAD plus a BUILD-TIME patch.
#
# The D21 `ab-keepalive-cadence` A/B pits upstream's receiver against the same
# receiver with the legacy recovery-keepalive cadence. That alternative must NOT
# live in the tree: the fork ships upstream `src/` verbatim until a campaign
# elects the change, so arm B can only exist as a scratch build. This script
# materialises it without touching the checkout:
#
#   1. export HEAD with `git archive` into a private scratch source tree
#      (tracked files only, so no build/ or .git);
#   2. restore the `deps/argparse` submodule (git archive skips gitlinks);
#   3. apply the patch with `patch -p1`;
#   4. configure + build `srtla_rec`, reusing the real build tree's FetchContent
#      cache for spdlog so no network fetch happens;
#   5. install the resulting binary at --out and delete the scratch tree.
#
# Nothing is written inside the repository (Rule D) — the scratch tree defaults
# to a `mktemp -d` under $TMPDIR, and --out is expected to live under the
# gitignored tests/compat/results/ tree.
#
# Usage:
#   build-receiver-variant.sh --patch FILE --out PATH
#       [--repo DIR] [--deps DIR] [--jobs N] [--work DIR] [--keep-work] [-h]
#
#   --patch FILE   unified diff to apply (required)
#   --out PATH     where the patched srtla_rec lands (required)
#   --repo DIR     srtla checkout (default: derived from this script's location)
#   --deps DIR     FetchContent base dir holding cached spdlog
#                  (default: <repo>/build/_deps when present)
#   --jobs N       parallel build jobs (default: nproc)
#   --work DIR     scratch tree (default: mktemp -d); implies --keep-work
#   --keep-work    leave the scratch tree behind for inspection
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DEFAULT_REPO="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"

log() { printf 'build-receiver-variant: %s\n' "$*" >&2; }
die() { printf 'build-receiver-variant: %s\n' "$*" >&2; exit 2; }

PATCH=""
OUT=""
REPO="$DEFAULT_REPO"
DEPS=""
WORK=""
JOBS="$(nproc 2>/dev/null || echo 4)"
KEEP_WORK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch)     PATCH="${2:?--patch needs a value}"; shift 2 ;;
    --out)       OUT="${2:?--out needs a value}"; shift 2 ;;
    --repo)      REPO="${2:?--repo needs a value}"; shift 2 ;;
    --deps)      DEPS="${2:?--deps needs a value}"; shift 2 ;;
    --jobs)      JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --work)      WORK="${2:?--work needs a value}"; KEEP_WORK=1; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help)   sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

[[ -n "$PATCH" ]] || die "--patch is required"
[[ -n "$OUT" ]] || die "--out is required"
[[ -f "$PATCH" ]] || die "patch file '$PATCH' not found"
[[ -d "$REPO/.git" || -f "$REPO/.git" ]] || die "'$REPO' is not a git checkout"
command -v cmake >/dev/null 2>&1 || die "cmake is required"
command -v patch >/dev/null 2>&1 || die "patch is required"
command -v tar   >/dev/null 2>&1 || die "tar is required"

[[ -n "$DEPS" ]] || DEPS="${REPO}/build/_deps"

OWN_WORK=0
if [[ -z "$WORK" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/srtla-receiver-variant.XXXXXX")" || die "mktemp failed"
  OWN_WORK=1
fi
SRC="${WORK}/src"
BUILD="${WORK}/build"

cleanup_work() {
  if [[ "$OWN_WORK" -eq 1 && "$KEEP_WORK" -eq 0 ]]; then
    rm -rf "$WORK"
  fi
}
trap cleanup_work EXIT INT TERM

log "scratch source: ${SRC}"
mkdir -p "$SRC" "$BUILD" || die "cannot create scratch dirs under ${WORK}"

# 1. Export tracked files at HEAD (no .git, no build/, no untracked cruft).
git -C "$REPO" archive --format=tar HEAD | tar -x -C "$SRC" \
  || die "git archive failed in ${REPO}"

# 2. Restore the argparse submodule (a gitlink git archive does not carry).
if [[ -d "${REPO}/deps/argparse/include" ]]; then
  rm -rf "${SRC}/deps/argparse"
  mkdir -p "${SRC}/deps"
  cp -a "${REPO}/deps/argparse" "${SRC}/deps/argparse" \
    || die "could not copy deps/argparse into the scratch tree"
else
  die "deps/argparse is missing in ${REPO} (run: git submodule update --init --recursive)"
fi

# 3. Apply the build-time patch.
( cd "$SRC" && patch -p1 --binary --forward < "$PATCH" ) \
  || die "could not apply ${PATCH} to the scratch tree"

# 4. Configure + build the receiver. FETCHCONTENT_BASE_DIR points at the real
#    build tree's dependency cache so spdlog is not re-fetched.
CMAKE_ARGS=(
  -S "$SRC" -B "$BUILD"
  -DSRTLA_BUILD_TESTS=OFF
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
)
if [[ -d "$DEPS" ]]; then
  CMAKE_ARGS+=( "-DFETCHCONTENT_BASE_DIR=${DEPS}" )
else
  log "no FetchContent cache at ${DEPS}; spdlog will be fetched"
fi

cmake "${CMAKE_ARGS[@]}" >"${WORK}/cmake.log" 2>&1 \
  || { tail -30 "${WORK}/cmake.log" >&2; die "cmake configure failed (see ${WORK}/cmake.log)"; }
cmake --build "$BUILD" --target srtla_rec -j "$JOBS" >"${WORK}/build.log" 2>&1 \
  || { tail -30 "${WORK}/build.log" >&2; die "srtla_rec build failed (see ${WORK}/build.log)"; }

[[ -x "${BUILD}/srtla_rec" ]] || die "build finished but ${BUILD}/srtla_rec is missing"

mkdir -p "$(dirname -- "$OUT")" || die "cannot create output dir for '${OUT}'"
cp "${BUILD}/srtla_rec" "$OUT" || die "cannot install patched receiver at '${OUT}'"

log "built $(basename -- "$PATCH") -> ${OUT} ($(sha256sum "$OUT" | cut -d' ' -f1))"
exit 0
