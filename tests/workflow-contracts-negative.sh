#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$REPO_ROOT/test-results"
FIXTURE_ROOT=$(mktemp -d "$REPO_ROOT/test-results/workflow-contracts.XXXXXX")
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

seed_fixture() {
  rm -rf "${FIXTURE_ROOT:?}/.github" "${FIXTURE_ROOT:?}/tests"
  mkdir -p "$FIXTURE_ROOT/.github/workflows"
  cp -a "$REPO_ROOT/.github/workflows/." "$FIXTURE_ROOT/.github/workflows/"
  if [[ -f "$REPO_ROOT/.github/actions/compat-build/action.yml" ]]; then
    mkdir -p "$FIXTURE_ROOT/.github/actions/compat-build"
    cp "$REPO_ROOT/.github/actions/compat-build/action.yml" \
      "$FIXTURE_ROOT/.github/actions/compat-build/action.yml"
  fi
  if [[ -d "$REPO_ROOT/tests/compat" ]]; then
    mkdir -p "$FIXTURE_ROOT/tests/compat/scenarios"
    cp "$REPO_ROOT/tests/compat/matrix.yaml" "$FIXTURE_ROOT/tests/compat/matrix.yaml"
    cp "$REPO_ROOT/tests/compat/scenarios/jitter-stress.sh" \
      "$FIXTURE_ROOT/tests/compat/scenarios/jitter-stress.sh"
  fi
}

assert_rejected() {
  local mutation=$1
  local expected_error=$2
  local output
  local rc

  set +e
  output=$("$REPO_ROOT/tests/workflow-contracts.sh" "$FIXTURE_ROOT" 2>&1)
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    printf 'ERROR: mutation %s was not rejected\n' "$mutation" >&2
    return 1
  fi
  if [[ $output != *"$expected_error"* ]]; then
    printf 'ERROR: mutation %s failed without expected error: %s\n%s\n' \
      "$mutation" "$expected_error" "$output" >&2
    return 1
  fi
  printf 'workflow-contracts-negative: rejected %s\n' "$mutation"
}

# Reintroducing either retired workflow must FAIL the contract rather than pass
# unnoticed: that assertion is the only thing keeping the receiver release-free
# (D22) and binding-free (D13) once someone copies a file back from legacy.
run_reintroduction_case() {
  local mutation=$1
  local workflow=$2
  local expected_error=$3

  seed_fixture
  printf 'name: retired\non:\n  push:\n    branches: [upstream/main]\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' \
    > "$FIXTURE_ROOT/.github/workflows/$workflow"
  assert_rejected "$mutation" "$expected_error"
}

run_workflow_negative_case() {
  local workflow=$1
  local mutation=$2
  local expected_error=$3

  seed_fixture
  python3 - "$FIXTURE_ROOT/.github/workflows/$workflow" "$mutation" <<'PY'
from pathlib import Path
import sys

import yaml


path = Path(sys.argv[1])
mutation = sys.argv[2]
with path.open(encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

jobs = workflow["jobs"]
if mutation == "remove-build-check-cache":
    jobs["build"]["steps"] = [
        step for step in jobs["build"]["steps"] if step.get("name") != "Cache ccache"
    ]
elif mutation == "downgrade-build-check-cache-major":
    step = next(s for s in jobs["build"]["steps"] if s.get("name") == "Cache ccache")
    step["uses"] = "actions/cache@v5"
elif mutation == "inflate-build-check-maxsize":
    jobs["build"]["env"]["CCACHE_MAXSIZE"] = "2G"
elif mutation == "drop-build-check-cache-revision":
    step = next(s for s in jobs["build"]["steps"] if s.get("name") == "Cache ccache")
    step["with"]["key"] = "ccache-${{ runner.os }}-${{ matrix.arch }}-gcc"
elif mutation == "remove-build-check-launcher":
    step = next(s for s in jobs["build"]["steps"] if s.get("name") == "Build srtla")
    step["run"] = step["run"].replace("-DCMAKE_C_COMPILER_LAUNCHER=ccache ", "")
elif mutation == "remove-build-check-eviction":
    jobs["build"]["steps"] = [
        step
        for step in jobs["build"]["steps"]
        if step.get("name") != "Enforce ccache bound"
    ]
elif mutation == "remove-build-check-bound":
    jobs["build"]["steps"] = [
        step
        for step in jobs["build"]["steps"]
        if step.get("name") != "Configure bounded ccache"
    ]
elif mutation == "remove-static-test-cache":
    jobs["test"]["steps"] = [
        step for step in jobs["test"]["steps"] if step.get("name") != "Cache ccache"
    ]
elif mutation == "add-clang-tidy-ccache":
    jobs["clang-tidy"]["steps"].append(
        {"name": "Ineffective ccache", "run": "ccache -s"}
    )
else:
    raise SystemExit(f"unknown mutation: {mutation}")

with path.open("w", encoding="utf-8") as handle:
    yaml.safe_dump(workflow, handle, sort_keys=False)
PY

  assert_rejected "$mutation" "$expected_error"
}

run_compat_negative_case() {
  local mutation=$1
  local expected_error=$2
  seed_fixture

  python3 - \
    "$FIXTURE_ROOT/.github/workflows/compat-matrix.yml" \
    "$FIXTURE_ROOT/.github/actions/compat-build/action.yml" \
    "$FIXTURE_ROOT/tests/compat/scenarios/jitter-stress.sh" \
    "$mutation" <<'PY'
from pathlib import Path
import sys

import yaml


path = Path(sys.argv[1])
action_path = Path(sys.argv[2])
jitter_path = Path(sys.argv[3])
mutation = sys.argv[4]
with path.open(encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

jobs = workflow["jobs"]
if mutation == "remove-compat-cache":
    jobs["compat-blocking"]["steps"] = [
        step
        for step in jobs["compat-blocking"]["steps"]
        if step.get("name") != "Cache ccache"
    ]
elif mutation == "remove-pcap-cache":
    jobs["pcap-replay"]["steps"] = [
        step
        for step in jobs["pcap-replay"]["steps"]
        if step.get("name") != "Cache ccache"
    ]
elif mutation == "downgrade-cache-major":
    cache_step = next(
        step
        for step in jobs["compat-blocking"]["steps"]
        if step.get("name") == "Cache ccache"
    )
    cache_step["uses"] = "actions/cache@v5"
elif mutation.startswith("remove-image-input:"):
    omitted = mutation.split(":", 1)[1]
    cache_step = next(
        step
        for step in jobs["compat-blocking"]["steps"]
        if step.get("name") == "Restore external image cache"
    )
    key = cache_step["with"]["key"]
    for token in (f"'{omitted}', ", f", '{omitted}'", f"'{omitted}'"):
        key = key.replace(token, "")
    cache_step["with"]["key"] = key
elif mutation == "inflate-ccache-maxsize":
    jobs["compat-blocking"]["env"]["CCACHE_MAXSIZE"] = "2G"
elif mutation == "remove-pcap-eviction":
    jobs["pcap-replay"]["steps"] = [
        step
        for step in jobs["pcap-replay"]["steps"]
        if step.get("name") != "Enforce ccache bound"
    ]
elif mutation == "remove-workflow-dispatch":
    triggers = workflow.get("on", workflow.get(True))
    del triggers["workflow_dispatch"]
elif mutation == "change-hosted-srt-pin":
    jobs["hosted-jitter"]["env"]["SRT_SHA"] = "0" * 40
elif mutation == "change-hosted-irl-pin":
    jobs["hosted-jitter"]["env"]["IRL_SRT_SERVER_SHA"] = "0" * 40
elif mutation == "change-hosted-rust-sender-pin":
    jobs["hosted-jitter"]["env"]["SRTLA_SEND_RS_SHA"] = "0" * 40
elif mutation == "remove-hosted-jitter-approval":
    jobs["hosted-jitter"]["if"] = "${{ github.event_name == 'pull_request' }}"
elif mutation == "remove-hosted-head-ref":
    checkout_step = next(
        step
        for step in jobs["hosted-jitter"]["steps"]
        if step.get("name") == "Checkout srtla"
    )
    del checkout_step["with"]["ref"]
elif mutation == "misreport-hosted-source-sha":
    jobs["hosted-jitter"]["env"]["SRTLA_SOURCE_SHA"] = "${{ github.sha }}"
elif mutation == "record-hosted-event-sha":
    provenance_step = next(
        step
        for step in jobs["hosted-jitter"]["steps"]
        if step.get("name") == "Record source and runtime provenance"
    )
    provenance_step["run"] = provenance_step["run"].replace(
        '--arg srtla_sha "$resolved_srtla_sha"',
        '--arg srtla_sha "$GITHUB_SHA"',
    )
elif mutation == "remove-hosted-irl-runtime":
    jobs["hosted-jitter"]["steps"] = [
        step
        for step in jobs["hosted-jitter"]["steps"]
        if step.get("name") != "Build and exercise pinned irl-srt-server runtime"
    ]
elif mutation == "allow-hosted-jitter-skip":
    verify_step = next(
        step
        for step in jobs["hosted-jitter"]["steps"]
        if step.get("name") == "Run and verify real jitter stress"
    )
    verify_step["run"] = verify_step["run"].replace(
        ".skipped != true", ".skipped == true"
    )
elif mutation == "remove-hosted-jitter-evidence":
    jobs["hosted-jitter"]["steps"] = [
        step
        for step in jobs["hosted-jitter"]["steps"]
        if step.get("name") != "Upload hosted jitter evidence"
    ]
elif mutation == "remove-hosted-jitter-readiness":
    jitter_path.write_text(
        jitter_path.read_text(encoding="utf-8").replace(
            "wait_for_connection_count 1 10", "sleep 0.6"
        ),
        encoding="utf-8",
    )
elif mutation == "break-hosted-jitter-source-symmetry":
    jitter_path.write_text(
        jitter_path.read_text(encoding="utf-8").replace(
            'LINK2_SRC="10.173.${OCTET}.4"',
            'LINK2_SRC="10.174.${OCTET}.1"\nLINK2_PEER="10.174.${OCTET}.2"',
        ),
        encoding="utf-8",
    )
elif mutation == "comment-launcher-decoy":
    with action_path.open(encoding="utf-8") as handle:
        action = yaml.safe_load(handle)
    build_step = next(
        step
        for step in action["runs"]["steps"]
        if step.get("name") == "Build srtla + compat helpers"
    )
    build_step["run"] = "\n".join(
        line
        for line in build_step["run"].splitlines()
        if "COMPILER_LAUNCHER=ccache" not in line
    )
    with action_path.open("w", encoding="utf-8") as handle:
        yaml.safe_dump(action, handle, sort_keys=False)
        handle.write("# -DCMAKE_C_COMPILER_LAUNCHER=ccache\n")
        handle.write("# -DCMAKE_CXX_COMPILER_LAUNCHER=ccache\n")
else:
    raise SystemExit(f"unknown mutation: {mutation}")

with path.open("w", encoding="utf-8") as handle:
    yaml.safe_dump(workflow, handle, sort_keys=False)
PY

  assert_rejected "$mutation" "$expected_error"
}

failures=0

run_reintroduction_case \
  reintroduce-publish-release \
  publish-release.yml \
  "publish-release: the receiver is never released; this workflow must not exist" \
  || failures=$((failures + 1))
run_reintroduction_case \
  reintroduce-bindings \
  bindings.yml \
  "bindings: the receiver ships no TypeScript bindings; this workflow must not exist" \
  || failures=$((failures + 1))

run_workflow_negative_case build-check.yml \
  remove-build-check-cache \
  "build-check: build must cache ccache" || failures=$((failures + 1))
run_workflow_negative_case build-check.yml \
  downgrade-build-check-cache-major \
  "build-check: build cache action must use actions/cache@v6" || failures=$((failures + 1))
run_workflow_negative_case build-check.yml \
  inflate-build-check-maxsize \
  "build-check: build must set CCACHE_MAXSIZE to 200M" || failures=$((failures + 1))
run_workflow_negative_case build-check.yml \
  drop-build-check-cache-revision \
  "build-check: build ccache key omits source revision" || failures=$((failures + 1))
run_workflow_negative_case build-check.yml \
  remove-build-check-launcher \
  "build-check: build does not configure -DCMAKE_C_COMPILER_LAUNCHER=ccache" \
  || failures=$((failures + 1))
run_workflow_negative_case build-check.yml \
  remove-build-check-eviction \
  "build-check: build does not enforce ccache eviction" || failures=$((failures + 1))
run_workflow_negative_case build-check.yml \
  remove-build-check-bound \
  "build-check: build does not configure the ccache size bound" || failures=$((failures + 1))
run_workflow_negative_case static-analysis.yml \
  remove-static-test-cache \
  "static-analysis: test must cache ccache" || failures=$((failures + 1))
run_workflow_negative_case static-analysis.yml \
  add-clang-tidy-ccache \
  "static-analysis: clang-tidy job installs or invokes ccache" || failures=$((failures + 1))

if [[ -f "$REPO_ROOT/.github/workflows/compat-matrix.yml" ]]; then
  run_compat_negative_case \
    remove-compat-cache \
    "compat-matrix: compat-blocking must cache ccache" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-pcap-cache \
    "compat-matrix: pcap-replay must cache ccache" || failures=$((failures + 1))
  run_compat_negative_case \
    downgrade-cache-major \
    "compat-matrix: compat-blocking cache action must use actions/cache@v6" || failures=$((failures + 1))
  run_compat_negative_case \
    comment-launcher-decoy \
    "compat-build: composite action does not configure -DCMAKE_C_COMPILER_LAUNCHER=ccache" || failures=$((failures + 1))
  run_compat_negative_case \
    "remove-image-input:tests/compat/matrix.yaml" \
    "compat-matrix: compat-blocking external-image key omits tests/compat/matrix.yaml" || failures=$((failures + 1))
  run_compat_negative_case \
    "remove-image-input:tests/compat/gen-ci-matrix.sh" \
    "compat-matrix: compat-blocking external-image key omits tests/compat/gen-ci-matrix.sh" || failures=$((failures + 1))
  run_compat_negative_case \
    "remove-image-input:tests/compat/docker/**" \
    "compat-matrix: compat-blocking external-image key omits tests/compat/docker/**" || failures=$((failures + 1))
  run_compat_negative_case \
    "remove-image-input:tests/compat/moblin-mock/**" \
    "compat-matrix: compat-blocking external-image key omits tests/compat/moblin-mock/**" || failures=$((failures + 1))
  run_compat_negative_case \
    "remove-image-input:.github/actions/compat-build/**" \
    "compat-matrix: compat-blocking external-image key omits .github/actions/compat-build/**" || failures=$((failures + 1))
  run_compat_negative_case \
    inflate-ccache-maxsize \
    "compat-matrix: compat-blocking must set CCACHE_MAXSIZE to 200M" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-pcap-eviction \
    "compat-matrix: pcap-replay does not enforce ccache eviction" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-workflow-dispatch \
    "compat-matrix: hosted jitter lane must be workflow_dispatch enabled" || failures=$((failures + 1))
  run_compat_negative_case \
    change-hosted-srt-pin \
    "compat-matrix: hosted-jitter SRT 1.5.6 pin is not immutable" || failures=$((failures + 1))
  run_compat_negative_case \
    change-hosted-irl-pin \
    "compat-matrix: hosted-jitter irl-srt-server pin is not immutable" || failures=$((failures + 1))
  run_compat_negative_case \
    change-hosted-rust-sender-pin \
    "compat-matrix: hosted-jitter Rust sender pin is not immutable" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-hosted-jitter-approval \
    "compat-matrix: hosted-jitter PR execution lacks exact-head maintainer approval" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-hosted-head-ref \
    "compat-matrix: hosted-jitter does not checkout the approved PR head SHA" || failures=$((failures + 1))
  run_compat_negative_case \
    misreport-hosted-source-sha \
    "compat-matrix: hosted-jitter provenance is not bound to the approved PR head SHA" || failures=$((failures + 1))
  run_compat_negative_case \
    record-hosted-event-sha \
    "compat-matrix: hosted-jitter records event SHA instead of checked-out source SHA" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-hosted-irl-runtime \
    "compat-matrix: hosted-jitter does not exercise the pinned irl-srt-server runtime" || failures=$((failures + 1))
  run_compat_negative_case \
    allow-hosted-jitter-skip \
    "compat-matrix: hosted-jitter can accept a skip or misleading PASS" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-hosted-jitter-evidence \
    "compat-matrix: hosted-jitter must always upload non-empty evidence" || failures=$((failures + 1))
  run_compat_negative_case \
    remove-hosted-jitter-readiness \
    "jitter-stress: media caller starts before an upstream link is ready" || failures=$((failures + 1))
  run_compat_negative_case \
    break-hosted-jitter-source-symmetry \
    "jitter-stress: second link does not preserve the receiver source address" || failures=$((failures + 1))

else
  printf 'workflow-contracts-negative: compat harness absent; compat cases inert\n'
fi

exit "$failures"
