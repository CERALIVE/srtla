#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=${1:-$DEFAULT_REPO_ROOT}

python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import posixpath
import re
import sys

import yaml


repo_root = Path(sys.argv[1])
CCACHE_MAXSIZE = "200M"
CCACHE_ACTIVE_BUDGET_MB = 1800
COMPAT_IMAGE_CACHE_INPUTS = {
    ".github/actions/compat-build/**",
    "tests/compat/docker/**",
    "tests/compat/gen-ci-matrix.sh",
    "tests/compat/matrix.yaml",
    "tests/compat/moblin-mock/**",
}


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


def job_text(job: object) -> str:
    return "\n".join(scalar_strings(job))


def executable_step_text(step: object) -> str:
    if not isinstance(step, dict) or not isinstance(step.get("run"), str):
        return ""
    commands = []
    for line in step["run"].splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        commands.append(line.split(" #", 1)[0].rstrip())
    return "\n".join(commands)


def executable_run_text(container: object) -> str:
    if not isinstance(container, dict):
        return ""
    return "\n".join(
        executable_step_text(step)
        for step in container.get("steps", [])
        if executable_step_text(step)
    )


def cmake_configure_text(container: object) -> str:
    if not isinstance(container, dict):
        return ""
    configure_steps = []
    for step in container.get("steps", []):
        command = executable_step_text(step)
        if re.search(r"(^|\n)\s*cmake\s+-B(?:\s|$)", command):
            configure_steps.append(command)
    return "\n".join(configure_steps)


def compat_matrix_build_contexts() -> set[str]:
    path = repo_root / "tests" / "compat" / "matrix.yaml"
    with path.open(encoding="utf-8") as handle:
        matrix = yaml.safe_load(handle) or {}
    contexts = set()
    for section in ("senders", "receivers"):
        for entry in matrix.get(section, []):
            build = entry.get("build") if isinstance(entry, dict) else None
            if not isinstance(build, str) or not build:
                continue
            normalized = (
                build
                if build.startswith("tests/compat/")
                else posixpath.join("tests/compat", build)
            )
            context = (
                normalized.rstrip("/")
                if build.endswith("/")
                else posixpath.dirname(normalized)
            )
            contexts.add(posixpath.normpath(context))
    return contexts


def glob_covers_context(pattern: str, context: str) -> bool:
    if not pattern.endswith("/**"):
        return False
    prefix = pattern.removesuffix("/**")
    return context == prefix or context.startswith(prefix + "/")


def cache_step(job: object, path_fragment: str) -> dict | None:
    if not isinstance(job, dict):
        return None
    for step in job.get("steps", []):
        if not isinstance(step, dict):
            continue
        if not str(step.get("uses", "")).startswith("actions/cache@"):
            continue
        path = str(step.get("with", {}).get("path", ""))
        if path_fragment in path:
            return step
    return None


def require_cache_v6(label: str, step: dict) -> None:
    if step.get("uses") != "actions/cache@v6":
        errors.append(f"{label} cache action must use actions/cache@v6")


def require_ccache(
    workflow_name: str,
    job_name: str,
    job: object,
    *,
    direct_build: bool,
) -> None:
    if not isinstance(job, dict):
        errors.append(f"{workflow_name}: {job_name} build job is missing")
        return

    env = job.get("env", {})
    if not isinstance(env, dict) or "CCACHE_DIR" not in env:
        errors.append(f"{workflow_name}: {job_name} does not declare CCACHE_DIR")
    if not isinstance(env, dict) or env.get("CCACHE_MAXSIZE") != CCACHE_MAXSIZE:
        errors.append(
            f"{workflow_name}: {job_name} must set CCACHE_MAXSIZE to {CCACHE_MAXSIZE}"
        )

    cache = cache_step(job, "env.CCACHE_DIR")
    if cache is None:
        errors.append(f"{workflow_name}: {job_name} must cache ccache")
    else:
        require_cache_v6(f"{workflow_name}: {job_name}", cache)
        cache_with = cache.get("with", {})
        key = str(cache_with.get("key", ""))
        restore_keys = str(cache_with.get("restore-keys", ""))
        if "${{ runner.os }}" not in key:
            errors.append(f"{workflow_name}: {job_name} ccache key omits runner OS")
        if "gcc" not in key.lower():
            errors.append(f"{workflow_name}: {job_name} ccache key omits compiler")
        if "${{ github.sha }}" not in key and "hashFiles(" not in key:
            errors.append(f"{workflow_name}: {job_name} ccache key omits source revision")
        if not restore_keys.strip():
            errors.append(f"{workflow_name}: {job_name} ccache cache has no restore prefix")

    commands = executable_run_text(job)
    if direct_build and "ccache" not in commands:
        errors.append(f"{workflow_name}: {job_name} does not install or invoke ccache")
    if direct_build:
        config_steps = [
            step
            for step in job.get("steps", [])
            if isinstance(step, dict) and step.get("name") == "Configure bounded ccache"
        ]
        if (
            len(config_steps) != 1
            or executable_step_text(config_steps[0]) != 'ccache -M "$CCACHE_MAXSIZE"'
        ):
            errors.append(
                f"{workflow_name}: {job_name} does not configure the ccache size bound"
            )
        configure_commands = cmake_configure_text(job)
        for launcher in (
            "-DCMAKE_C_COMPILER_LAUNCHER=ccache",
            "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache",
        ):
            if launcher not in configure_commands:
                errors.append(f"{workflow_name}: {job_name} does not configure {launcher}")
        cleanup_steps = [
            step
            for step in job.get("steps", [])
            if isinstance(step, dict) and step.get("name") == "Enforce ccache bound"
        ]
        if (
            len(cleanup_steps) != 1
            or cleanup_steps[0].get("if") != "${{ always() }}"
            or "ccache -c" not in executable_step_text(cleanup_steps[0])
        ):
            errors.append(
                f"{workflow_name}: {job_name} does not enforce ccache eviction"
            )


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

require_ccache(
    "publish-release",
    "validate",
    validate,
    direct_build=True,
)
require_ccache(
    "publish-release",
    "build-deb",
    build_deb,
    direct_build=True,
)
require_ccache(
    "publish-release",
    "build-deb-focal",
    build_deb_focal,
    direct_build=True,
)

build_check = load_workflow("build-check.yml")
require_ccache(
    "build-check",
    "build",
    build_check.get("jobs", {}).get("build"),
    direct_build=True,
)

static_test = static_analysis.get("jobs", {}).get("test")
require_ccache(
    "static-analysis",
    "test",
    static_test,
    direct_build=True,
)

bindings = load_workflow("bindings.yml")
bindings_job = bindings.get("jobs", {}).get("build-and-test")
bun_cache = cache_step(bindings_job, "~/.bun/install/cache")
if bun_cache is None:
    errors.append("bindings: build-and-test must cache the Bun install store")
else:
    require_cache_v6("bindings: build-and-test", bun_cache)
    bun_key = str(bun_cache.get("with", {}).get("key", ""))
    if "${{ runner.os }}" not in bun_key:
        errors.append("bindings: Bun cache key omits runner OS")
    if "hashFiles('bindings/typescript/bun.lock')" not in bun_key:
        errors.append("bindings: Bun cache key omits bun.lock")
if "bun install --frozen-lockfile" not in job_text(bindings_job):
    errors.append("bindings: build-and-test does not enforce the lockfile")

compat = load_workflow("compat-matrix.yml")
compat_jobs = compat.get("jobs", {})
for job_name in ("compat-blocking", "compat-informational"):
    require_ccache(
        "compat-matrix",
        job_name,
        compat_jobs.get(job_name),
        direct_build=False,
    )
    image_cache = cache_step(compat_jobs.get(job_name), "/tmp/compat-images")
    if image_cache is None:
        errors.append(f"compat-matrix: {job_name} must cache external images")
    else:
        require_cache_v6(f"compat-matrix: {job_name} external-image", image_cache)
        image_key = str(image_cache.get("with", {}).get("key", ""))
        if "${{ runner.os }}" not in image_key or "amd64" not in image_key:
            errors.append(
                f"compat-matrix: {job_name} external-image key omits runner/architecture"
            )
        hash_match = re.search(r"hashFiles\(([^)]*)\)", image_key)
        image_inputs = (
            set(re.findall(r"'([^']+)'", hash_match.group(1)))
            if hash_match
            else set()
        )
        missing_inputs = COMPAT_IMAGE_CACHE_INPUTS - image_inputs
        if missing_inputs:
            errors.append(
                f"compat-matrix: {job_name} external-image key omits "
                + ", ".join(sorted(missing_inputs))
            )
        uncovered_contexts = {
            context
            for context in compat_matrix_build_contexts()
            if not any(
                glob_covers_context(pattern, context)
                for pattern in image_inputs
            )
        }
        if uncovered_contexts:
            errors.append(
                f"compat-matrix: {job_name} external-image key does not cover "
                + ", ".join(sorted(uncovered_contexts))
            )

require_ccache(
    "compat-matrix",
    "pcap-replay",
    compat_jobs.get("pcap-replay"),
    direct_build=True,
)
require_ccache(
    "compat-matrix",
    "upstream-drift",
    compat_jobs.get("upstream-drift"),
    direct_build=False,
)

compat_action_path = repo_root / ".github" / "actions" / "compat-build" / "action.yml"
if not compat_action_path.is_file():
    errors.append("compat-build: composite build action is missing")
else:
    with compat_action_path.open(encoding="utf-8") as handle:
        compat_action = yaml.safe_load(handle)
    compat_runs = compat_action.get("runs", {}) if isinstance(compat_action, dict) else {}
    compat_commands = executable_run_text(compat_runs)
    if "ccache" not in compat_commands:
        errors.append("compat-build: composite action does not install ccache")
    compat_config = [
        step
        for step in compat_runs.get("steps", [])
        if isinstance(step, dict) and step.get("name") == "Configure bounded ccache"
    ]
    if (
        len(compat_config) != 1
        or executable_step_text(compat_config[0]) != 'ccache -M "$CCACHE_MAXSIZE"'
    ):
        errors.append("compat-build: composite action does not configure ccache max size")
    compat_configure_commands = cmake_configure_text(compat_runs)
    for launcher in (
        "-DCMAKE_C_COMPILER_LAUNCHER=ccache",
        "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache",
    ):
        if launcher not in compat_configure_commands:
            errors.append(f"compat-build: composite action does not configure {launcher}")
    compat_cleanup = [
        step
        for step in compat_runs.get("steps", [])
        if isinstance(step, dict) and step.get("name") == "Enforce ccache bound"
    ]
    if (
        len(compat_cleanup) != 1
        or compat_cleanup[0].get("if") != "${{ always() }}"
        or "ccache -c" not in executable_step_text(compat_cleanup[0])
    ):
        errors.append("compat-build: composite action does not enforce ccache eviction")

ccache_jobs = [
    validate,
    build_deb,
    build_deb_focal,
    build_check.get("jobs", {}).get("build"),
    static_test,
    compat_jobs.get("compat-blocking"),
    compat_jobs.get("compat-informational"),
    compat_jobs.get("pcap-replay"),
    compat_jobs.get("upstream-drift"),
]
active_keys = set()
for job in ccache_jobs:
    cache = cache_step(job, "env.CCACHE_DIR")
    if cache is None:
        continue
    key = str(cache.get("with", {}).get("key", ""))
    strategy = job.get("strategy", {}) if isinstance(job, dict) else {}
    matrix = strategy.get("matrix", {}) if isinstance(strategy, dict) else {}
    matrix_entries = matrix.get("include", []) if isinstance(matrix, dict) else []
    arches = {
        str(entry.get("arch"))
        for entry in matrix_entries
        if isinstance(entry, dict) and entry.get("arch")
    }
    if "${{ matrix.arch }}" in key and arches:
        active_keys.update(key.replace("${{ matrix.arch }}", arch) for arch in arches)
    else:
        active_keys.add(key)

active_ccache_mb = len(active_keys) * int(CCACHE_MAXSIZE.removesuffix("M"))
if active_ccache_mb > CCACHE_ACTIVE_BUDGET_MB:
    errors.append(
        "ccache active key budget exceeds "
        f"{CCACHE_ACTIVE_BUDGET_MB} MB: {len(active_keys)} keys at {CCACHE_MAXSIZE}"
    )

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "workflow-contracts: release validation and clang-tidy cache contracts pass; "
    f"ccache budget {len(active_keys)}x{CCACHE_MAXSIZE}={active_ccache_mb}MB"
)
PY
