#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=${1:-$DEFAULT_REPO_ROOT}

python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import re
import sys

import yaml


repo_root = Path(sys.argv[1])


def load_workflow(name: str) -> dict:
    path = repo_root / ".github" / "workflows" / name
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if not isinstance(data, dict):
        raise SystemExit(f"workflow-contracts: {path} is not a mapping")
    return data


def as_set(value: object) -> set[str]:
    if isinstance(value, str):
        return {value}
    if isinstance(value, list):
        return {str(item) for item in value}
    return set()


def scalar_strings(value: object) -> list[str]:
    if isinstance(value, dict):
        return [text for item in value.values() for text in scalar_strings(item)]
    if isinstance(value, list):
        return [text for item in value for text in scalar_strings(item)]
    return [value] if isinstance(value, str) else []


errors: list[str] = []
release = load_workflow("publish-release.yml")
release_jobs = release.get("jobs", {})
validate = release_jobs.get("validate")
build_deb = release_jobs.get("build-deb")
build_deb_focal = release_jobs.get("build-deb-focal")
publish = release_jobs.get("publish", {})

if not isinstance(validate, dict):
    errors.append("publish-release: required validate job is missing")
else:
    if validate.get("continue-on-error") is True:
        errors.append("publish-release: validate job may not continue on error")
    validate_commands = "\n".join(
        str(step.get("run", ""))
        for step in validate.get("steps", [])
        if isinstance(step, dict)
    )
    if "cmake --build build --target lint" not in validate_commands:
        errors.append("publish-release: validate job does not run clang-tidy")
    if 'cmake --build build -j"$(nproc)"' not in validate_commands:
        errors.append("publish-release: validate job does not run the normal CMake build")
    if "ctest --test-dir build --output-on-failure" not in validate_commands:
        errors.append("publish-release: validate job does not run CTest")

if not isinstance(build_deb_focal, dict):
    errors.append("publish-release: required build-deb-focal job is missing")
else:
    focal_commands = "\n".join(
        str(step.get("run", ""))
        for step in build_deb_focal.get("steps", [])
        if isinstance(step, dict)
    )
    if "ubuntu:20.04" not in str(build_deb_focal.get("container", "")):
        errors.append("publish-release: build-deb-focal does not use Ubuntu 20.04")
    if "-DSRTLA_BUILD_TESTS=ON" not in focal_commands:
        errors.append("publish-release: build-deb-focal does not enable package tests")
    if "-DINSTALL_GTEST=OFF" not in focal_commands:
        errors.append("publish-release: build-deb-focal does not restrict the staged payload")
    if 'cmake --build build-focal -j"$(nproc)"' not in focal_commands:
        errors.append("publish-release: build-deb-focal does not run the normal CMake build")
    focal_test_steps = [
        step
        for step in build_deb_focal.get("steps", [])
        if isinstance(step, dict) and step.get("name") == "Test Focal package build"
    ]
    if (
        len(focal_test_steps) != 1
        or focal_test_steps[0].get("working-directory") != "build-focal"
        or focal_test_steps[0].get("run") != "ctest --output-on-failure"
    ):
        errors.append("publish-release: build-deb-focal does not run CTest")
    if 'DESTDIR="$PWD/install-focal" cmake --install build-focal' not in focal_commands:
        errors.append("publish-release: build-deb-focal does not stage the install payload")

    focal_uploads = [
        step
        for step in build_deb_focal.get("steps", [])
        if isinstance(step, dict)
        and str(step.get("uses", "")).startswith("actions/upload-artifact@")
    ]
    if len(focal_uploads) != 1:
        errors.append("publish-release: build-deb-focal must upload exactly one artifact")
    else:
        focal_with = focal_uploads[0].get("with", {})
        if focal_with.get("name") != "srtla-amd64":
            errors.append("publish-release: build-deb-focal artifact name is incorrect")
        focal_paths = as_set(str(focal_with.get("path", "")).splitlines())
        expected_focal_paths = {
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_amd64.deb",
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_amd64.tar.gz",
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_amd64.deb.sha256",
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_amd64.tar.gz.sha256",
        }
        if focal_paths != expected_focal_paths:
            errors.append("publish-release: build-deb-focal artifact payload is incorrect")

if isinstance(build_deb, dict):
    native_matrix = build_deb.get("strategy", {}).get("matrix", {}).get("include", [])
    native_arches = {
        str(entry.get("arch"))
        for entry in native_matrix
        if isinstance(entry, dict)
    }
    if native_arches != {"arm64"}:
        errors.append("publish-release: build-deb must leave amd64 ownership to build-deb-focal")
    native_uploads = [
        step
        for step in build_deb.get("steps", [])
        if isinstance(step, dict)
        and str(step.get("uses", "")).startswith("actions/upload-artifact@")
    ]
    if len(native_uploads) != 1:
        errors.append("publish-release: build-deb must upload exactly one artifact per architecture")
    else:
        native_with = native_uploads[0].get("with", {})
        if native_with.get("name") != "srtla-${{ matrix.arch }}":
            errors.append("publish-release: build-deb artifact name is incorrect")
        native_paths = as_set(str(native_with.get("path", "")).splitlines())
        expected_native_paths = {
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_${{ matrix.arch }}.deb",
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_${{ matrix.arch }}.tar.gz",
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_${{ matrix.arch }}.deb.sha256",
            "dist/srtla_${{ needs.calculate-version.outputs.version }}_${{ matrix.arch }}.tar.gz.sha256",
        }
        if native_paths != expected_native_paths:
            errors.append("publish-release: build-deb artifact payload is incorrect")

publish_needs = as_set(publish.get("needs"))
required_publish_needs = {"calculate-version", "validate", "build-deb", "build-deb-focal"}
if "validate" not in publish_needs:
    errors.append("publish-release: publish job does not require validate")
if "build-deb" not in publish_needs:
    errors.append("publish-release: publish job does not require build-deb")
if "build-deb-focal" not in publish_needs:
    errors.append("publish-release: publish job does not require build-deb-focal")
if publish_needs != required_publish_needs:
    errors.append("publish-release: GitHub release is not gated by the exact release DAG")
if "always()" in str(publish.get("if", "")):
    errors.append("publish-release: publish job may not bypass failed dependencies")

publish_commands = "\n".join(
    str(step.get("run", ""))
    for step in publish.get("steps", [])
    if isinstance(step, dict)
)
if "artifacts/srtla-amd64/*.deb" not in publish_commands:
    errors.append("publish-release: publish job does not collect the Focal Debian package")
if "artifacts/srtla-amd64/*.tar.gz" not in publish_commands:
    errors.append("publish-release: publish job does not collect the Focal archive")

release_steps = [
    step
    for step in publish.get("steps", [])
    if isinstance(step, dict) and step.get("uses") == "softprops/action-gh-release@v3"
]
if release_steps:
    release_files = as_set(str(release_steps[0].get("with", {}).get("files", "")).splitlines())
    if "dist/amd64/*.deb" not in release_files:
        errors.append("publish-release: GitHub release omits the Focal Debian package")

release_text = "\n".join(scalar_strings(release))
unsupported_apt_identifiers = (
    "CERALIVE/apt-worker",
    "apt-reindex",
)
unsupported_srtla_identifiers = (
    re.compile(r'["\']?component["\']?\s*[:=]\s*["\']?srtla["\']?'),
    re.compile(r'["\']?repo["\']?\s*[:=]\s*["\']?srtla["\']?'),
)
if (
    any(identifier in release_text for identifier in unsupported_apt_identifiers)
    or any(pattern.search(release_text) for pattern in unsupported_srtla_identifiers)
):
    errors.append("publish-release: unsupported srtla apt-worker identifiers are present")

external_actions = {"softprops/action-gh-release@v3": 0}
for job_name, job in release_jobs.items():
    if not isinstance(job, dict):
        continue
    for step in job.get("steps", []):
        if not isinstance(step, dict):
            continue
        action = str(step.get("uses", ""))
        if action.startswith("peter-evans/repository-dispatch@"):
            errors.append("publish-release: srtla must not dispatch apt-worker")
        if action not in external_actions:
            continue
        external_actions[action] += 1
        if job_name != "publish":
            errors.append(f"publish-release: {action} must remain in publish job")

for action, count in external_actions.items():
    if count != 1:
        errors.append(f"publish-release: expected exactly one {action}, found {count}")

static_analysis = load_workflow("static-analysis.yml")
clang_tidy = static_analysis.get("jobs", {}).get("clang-tidy", {})
if "CCACHE_DIR" in clang_tidy.get("env", {}):
    errors.append("static-analysis: clang-tidy job declares ineffective CCACHE_DIR")

for step in clang_tidy.get("steps", []):
    if not isinstance(step, dict):
        continue
    if str(step.get("uses", "")).startswith("actions/cache@"):
        errors.append("static-analysis: clang-tidy job restores an ineffective cache")
    run = str(step.get("run", ""))
    if "ccache" in run:
        errors.append("static-analysis: clang-tidy job installs or invokes ccache")
    if "COMPILER_LAUNCHER=ccache" in run:
        errors.append("static-analysis: clang-tidy configures an unused ccache launcher")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print("workflow-contracts: release validation and clang-tidy cache contracts pass")
PY
