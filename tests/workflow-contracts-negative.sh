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

  cp "$REPO_ROOT/.github/workflows/publish-release.yml" \
    "$FIXTURE_ROOT/.github/workflows/publish-release.yml"
  cp "$REPO_ROOT/.github/workflows/static-analysis.yml" \
    "$FIXTURE_ROOT/.github/workflows/static-analysis.yml"

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

failures=0
run_negative_case \
  remove-build-deb-need \
  "publish-release: publish job does not require build-deb" || failures=$((failures + 1))
run_negative_case \
  remove-validation-build \
  "publish-release: validate job does not run the normal CMake build" || failures=$((failures + 1))
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

exit "$failures"
