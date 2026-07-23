#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$REPO_ROOT/test-results"
FIXTURE_ROOT=$(mktemp -d "$REPO_ROOT/test-results/workflow-contracts.XXXXXX")
trap 'rm -rf "$FIXTURE_ROOT"' EXIT
mkdir -p "$FIXTURE_ROOT/.github/workflows"

run_negative_case() {
  local mutation=$1
  local expected_error=$2
  local output
  local rc

  cp -a "$REPO_ROOT/.github/workflows/." "$FIXTURE_ROOT/.github/workflows/"
  mkdir -p "$FIXTURE_ROOT/.github/actions/compat-build"
  cp "$REPO_ROOT/.github/actions/compat-build/action.yml" \
    "$FIXTURE_ROOT/.github/actions/compat-build/action.yml"
  mkdir -p "$FIXTURE_ROOT/tests/compat"
  cp "$REPO_ROOT/tests/compat/matrix.yaml" \
    "$FIXTURE_ROOT/tests/compat/matrix.yaml"
  mkdir -p "$FIXTURE_ROOT/tests/compat/scenarios"
  cp "$REPO_ROOT/tests/compat/scenarios/jitter-stress.sh" \
    "$FIXTURE_ROOT/tests/compat/scenarios/jitter-stress.sh"

  python3 - "$FIXTURE_ROOT/.github/workflows/publish-release.yml" "$mutation" <<'PY'
from pathlib import Path
import sys

import yaml


path = Path(sys.argv[1])
mutation = sys.argv[2]
with path.open(encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

jobs = workflow["jobs"]
if mutation == "remove-build-deb-need":
    jobs["publish"]["needs"].remove("build-deb")
elif mutation == "remove-validation-build":
    build_step = next(
        step for step in jobs["validate"]["steps"] if step.get("name") == "Build"
    )
    build_step["run"] = "echo validation build skipped"
elif mutation == "remove-release-cache":
    jobs["build-deb"]["steps"] = [
        step
        for step in jobs["build-deb"]["steps"]
        if step.get("name") != "Cache ccache"
    ]
elif mutation == "remove-focal-cache":
    jobs["build-deb-focal"]["steps"] = [
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") != "Cache ccache"
    ]
elif mutation == "remove-focal-job":
    del jobs["build-deb-focal"]
elif mutation == "disable-focal-tests":
    configure_step = next(
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") == "Configure Focal package build"
    )
    configure_step["run"] = configure_step["run"].replace(
        "-DSRTLA_BUILD_TESTS=ON", "-DSRTLA_BUILD_TESTS=OFF"
    )
elif mutation == "allow-gtest-in-focal-payload":
    configure_step = next(
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") == "Configure Focal package build"
    )
    configure_step["run"] = configure_step["run"].replace(
        "-DINSTALL_GTEST=OFF ", ""
    )
elif mutation == "remove-focal-build":
    build_step = next(
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") == "Build Focal package"
    )
    build_step["run"] = "echo Focal build skipped"
elif mutation == "remove-focal-ctest":
    test_step = next(
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") == "Test Focal package build"
    )
    test_step["run"] = "echo Focal tests skipped"
elif mutation == "remove-focal-need":
    jobs["publish"]["needs"].remove("build-deb-focal")
elif mutation == "duplicate-native-amd64":
    jobs["build-deb"]["strategy"]["matrix"]["include"].append(
        {"arch": "amd64", "runner": "ubuntu-latest"}
    )
elif mutation == "rename-native-artifact":
    upload_step = next(
        step
        for step in jobs["build-deb"]["steps"]
        if step.get("name") == "Upload artifact"
    )
    upload_step["with"]["name"] = "srtla-native"
elif mutation == "remove-native-artifact-payload":
    upload_step = next(
        step
        for step in jobs["build-deb"]["steps"]
        if step.get("name") == "Upload artifact"
    )
    upload_step["with"]["path"] = "dist/*.deb"
elif mutation == "rename-focal-artifact":
    upload_step = next(
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") == "Upload Focal artifact"
    )
    upload_step["with"]["name"] = "srtla-focal"
elif mutation == "remove-focal-artifact-payload":
    upload_step = next(
        step
        for step in jobs["build-deb-focal"]["steps"]
        if step.get("name") == "Upload Focal artifact"
    )
    upload_step["with"]["path"] = "dist/*.deb"
elif mutation == "remove-focal-publish-collection":
    prepare_step = next(
        step
        for step in jobs["publish"]["steps"]
        if step.get("name") == "Prepare dist directory"
    )
    prepare_step["run"] = "\n".join(
        line
        for line in prepare_step["run"].splitlines()
        if "srtla-amd64" not in line
    )
elif mutation == "remove-focal-release-payload":
    release_step = next(
        step
        for step in jobs["publish"]["steps"]
        if step.get("name") == "Create GitHub Release"
    )
    release_step["with"]["files"] = release_step["with"]["files"].replace(
        "dist/amd64/*.deb\n", ""
    )
elif mutation == "add-apt-worker-dispatch":
    jobs["publish"]["steps"].append(
        {
            "name": "Unsupported receiver reindex",
            "uses": "peter-evans/repository-dispatch@v4",
            "with": {
                "repository": "CERALIVE/apt-worker",
                "event-type": "apt-reindex",
                "client-payload": '{"component":"srtla","repo":"srtla"}',
            },
        }
    )
elif mutation == "add-unsupported-apt-identifiers":
    jobs["publish"]["env"] = {
        "UNSUPPORTED_APT_PAYLOAD": '{"component": "srtla", "repo": "srtla"}'
    }
elif mutation == "bypass-release-gates":
    jobs["publish"]["if"] = "${{ always() }}"
else:
    raise SystemExit(f"unknown mutation: {mutation}")

with path.open("w", encoding="utf-8") as handle:
    yaml.safe_dump(workflow, handle, sort_keys=False)
PY

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

run_compat_negative_case() {
  local mutation=$1
  local expected_error=$2
  local output
  local rc

  cp -a "$REPO_ROOT/.github/workflows/." "$FIXTURE_ROOT/.github/workflows/"
  mkdir -p "$FIXTURE_ROOT/.github/actions/compat-build"
  cp "$REPO_ROOT/.github/actions/compat-build/action.yml" \
    "$FIXTURE_ROOT/.github/actions/compat-build/action.yml"
  mkdir -p "$FIXTURE_ROOT/tests/compat"
  cp "$REPO_ROOT/tests/compat/matrix.yaml" \
    "$FIXTURE_ROOT/tests/compat/matrix.yaml"
  mkdir -p "$FIXTURE_ROOT/tests/compat/scenarios"
  cp "$REPO_ROOT/tests/compat/scenarios/jitter-stress.sh" \
    "$FIXTURE_ROOT/tests/compat/scenarios/jitter-stress.sh"

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

failures=0
run_negative_case \
  remove-build-deb-need \
  "publish-release: publish job does not require build-deb" || failures=$((failures + 1))
run_negative_case \
  remove-validation-build \
  "publish-release: validate job does not run the normal CMake build" || failures=$((failures + 1))
run_negative_case \
  remove-release-cache \
  "publish-release: build-deb must cache ccache" || failures=$((failures + 1))
run_negative_case \
  remove-focal-cache \
  "publish-release: build-deb-focal must cache ccache" || failures=$((failures + 1))
run_negative_case \
  remove-focal-job \
  "publish-release: required build-deb-focal job is missing" || failures=$((failures + 1))
run_negative_case \
  disable-focal-tests \
  "publish-release: build-deb-focal does not enable package tests" || failures=$((failures + 1))
run_negative_case \
  allow-gtest-in-focal-payload \
  "publish-release: build-deb-focal does not restrict the staged payload" || failures=$((failures + 1))
run_negative_case \
  remove-focal-build \
  "publish-release: build-deb-focal does not run the normal CMake build" || failures=$((failures + 1))
run_negative_case \
  remove-focal-ctest \
  "publish-release: build-deb-focal does not run CTest" || failures=$((failures + 1))
run_negative_case \
  remove-focal-need \
  "publish-release: publish job does not require build-deb-focal" || failures=$((failures + 1))
run_negative_case \
  duplicate-native-amd64 \
  "publish-release: build-deb must leave amd64 ownership to build-deb-focal" || failures=$((failures + 1))
run_negative_case \
  rename-native-artifact \
  "publish-release: build-deb artifact name is incorrect" || failures=$((failures + 1))
run_negative_case \
  remove-native-artifact-payload \
  "publish-release: build-deb artifact payload is incorrect" || failures=$((failures + 1))
run_negative_case \
  rename-focal-artifact \
  "publish-release: build-deb-focal artifact name is incorrect" || failures=$((failures + 1))
run_negative_case \
  remove-focal-artifact-payload \
  "publish-release: build-deb-focal artifact payload is incorrect" || failures=$((failures + 1))
run_negative_case \
  remove-focal-publish-collection \
  "publish-release: publish job does not collect the Focal Debian package" || failures=$((failures + 1))
run_negative_case \
  remove-focal-release-payload \
  "publish-release: GitHub release omits the Focal Debian package" || failures=$((failures + 1))
run_negative_case \
  add-apt-worker-dispatch \
  "publish-release: srtla must not dispatch apt-worker" || failures=$((failures + 1))
run_negative_case \
  add-unsupported-apt-identifiers \
  "publish-release: unsupported srtla apt-worker identifiers are present" || failures=$((failures + 1))
run_negative_case \
  bypass-release-gates \
  "publish-release: publish job may not bypass failed dependencies" || failures=$((failures + 1))
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

exit "$failures"
