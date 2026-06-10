#!/usr/bin/env bash
#
# gen-ci-matrix.sh — derive CI inputs from the compat matrix registry.
#
# matrix.yaml (tests/compat/matrix.yaml) is the single source of truth for the
# compatibility test pairs and the pinned external implementations. This script
# translates it into the two machine-readable shapes the GitHub Actions
# compat-matrix workflow consumes, so adding a new implementation is a YAML edit
# rather than a workflow rewrite.
#
# Modes:
#   --pairs            (default) emit a GitHub Actions matrix object:
#                        {"include":[{"sender":..,"receiver":..,"tier":..}, ..]}
#   --images           emit a JSON array describing the buildable external
#                      Docker images:
#                        [{"name","image","context","dockerfile",
#                          "build_arg","pin","repo"}, ..]
#                      Only entries whose Dockerfile actually exists are listed
#                      (an entry still being wired up is silently skipped so the
#                      harness — which SKIPs missing images — stays in charge).
#
# Filters (both modes):
#   --tier blocking|informational|all   default: all
#
# Output is compact JSON on stdout, suitable for `>>"$GITHUB_OUTPUT"`.
#
# Paths in --images output are relative to the repository root so the workflow
# can use them directly after checkout.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
MATRIX_YAML="${SCRIPT_DIR}/matrix.yaml"

MODE="pairs"
TIER="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pairs)   MODE="pairs";  shift ;;
    --images)  MODE="images"; shift ;;
    --tier)    TIER="${2:?--tier needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'gen-ci-matrix: unknown argument %q\n' "$1" >&2; exit 2 ;;
  esac
done

case "$TIER" in blocking|informational|all) ;; *)
  printf 'gen-ci-matrix: unknown --tier %q\n' "$TIER" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || {
  printf 'gen-ci-matrix: python3 is required\n' >&2; exit 2; }

[[ -f "$MATRIX_YAML" ]] || {
  printf 'gen-ci-matrix: matrix.yaml not found at %s\n' "$MATRIX_YAML" >&2; exit 2; }

python3 - "$MATRIX_YAML" "$REPO_ROOT" "$SCRIPT_DIR" "$MODE" "$TIER" <<'PY'
import json
import os
import re
import sys

matrix_path, repo_root, script_dir, mode, tier = sys.argv[1:6]

try:
    import yaml
except ImportError:
    sys.stderr.write("gen-ci-matrix: PyYAML not installed (pip install pyyaml)\n")
    sys.exit(2)

with open(matrix_path) as fh:
    matrix = yaml.safe_load(fh) or {}

# matrix.yaml names map 1:1 to harness tokens except for a few historical
# aliases. The harness (run-matrix.sh) tags each external image "compat/<token>";
# we mirror that here so the images we build are the ones the harness consumes.
TOKEN_ALIAS = {
    "belabox-srtla-send": "belabox-sender",
    "irlserver-srtla-send": "irlserver-send",
    "belabox-srtla-rec": "belabox-receiver",
}


def token_of(name):
    return TOKEN_ALIAS.get(name, name)


def tier_match(entry_tier):
    return tier == "all" or entry_tier == tier


def rel(path):
    return os.path.relpath(path, repo_root)


def resolve_build(build):
    """Map a matrix.yaml `build:` value to (dockerfile, context) absolute paths.

    `build:` is either a Dockerfile path or a context directory. Paths that
    already start with `tests/compat/` are repo-root relative; everything else
    is relative to tests/compat/ (the registry's own directory)."""
    if not build:
        return None, None
    if build.startswith("tests/compat/"):
        base = os.path.join(repo_root, build)
    else:
        base = os.path.join(script_dir, build)
    if build.endswith("/") or os.path.isdir(base):
        dockerfile = os.path.join(base.rstrip("/"), "Dockerfile")
        context = base.rstrip("/")
    else:
        dockerfile = base
        context = os.path.dirname(base)
    return dockerfile, context


def first_build_arg(dockerfile):
    """The first `ARG <NAME>` in a Dockerfile is its pin override knob."""
    try:
        with open(dockerfile) as fh:
            for line in fh:
                m = re.match(r"\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                if m:
                    return m.group(1)
    except OSError:
        return None
    return None


if mode == "pairs":
    include = []
    for pair in (matrix.get("pairs") or []):
        ptier = pair.get("tier", "")
        if not tier_match(ptier):
            continue
        include.append({
            "sender": pair.get("sender", ""),
            "receiver": pair.get("receiver", ""),
            "tier": ptier,
        })
    json.dump({"include": include}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.exit(0)

# mode == "images": external sender + receiver implementations only ("ours" is
# the locally-built binary, never a Docker image).
images = []
seen = set()
for section in ("senders", "receivers"):
    for entry in (matrix.get(section) or []):
        name = entry.get("name")
        if not name or name == "ours" or name in seen:
            continue
        if not tier_match(entry.get("tier", "")):
            continue
        dockerfile, context = resolve_build(entry.get("build"))
        if not dockerfile or not os.path.isfile(dockerfile):
            # Implementation registered but image not wired up yet — the harness
            # SKIPs it, so we omit it here rather than fail the build.
            continue
        seen.add(name)
        images.append({
            "name": name,
            "image": "compat/" + token_of(name),
            "context": rel(context),
            "dockerfile": rel(dockerfile),
            "build_arg": first_build_arg(dockerfile) or "",
            "pin": entry.get("pin", ""),
            "repo": entry.get("repo", ""),
        })

json.dump(images, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
