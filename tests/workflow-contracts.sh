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
CCACHE_ACTIVE_BUDGET_MB = 2000
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


def workflow_exists(name: str) -> bool:
    return (repo_root / ".github" / "workflows" / name).is_file()


errors: list[str] = []

# The hard-fork base is receiver-only and release-free: nothing is packaged and
# nothing is published, so the presence of either workflow is itself the defect
# the contract has to catch (D22 receiver-never-released, D13 no bindings).
if workflow_exists("publish-release.yml"):
    errors.append("publish-release: the receiver is never released; this workflow must not exist")
if workflow_exists("bindings.yml"):
    errors.append("bindings: the receiver ships no TypeScript bindings; this workflow must not exist")

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

# The compat/A-B harness is ported separately; its contracts arm themselves the
# moment compat-matrix.yml appears, so they cannot be silently skipped later.
if workflow_exists("compat-matrix.yml"):
    compat = load_workflow("compat-matrix.yml")
    compat_jobs = compat.get("jobs", {})
    compat_triggers = compat.get("on", compat.get(True, {}))
    if not isinstance(compat_triggers, dict) or "workflow_dispatch" not in compat_triggers:
        errors.append("compat-matrix: hosted jitter lane must be workflow_dispatch enabled")

    hosted_jitter = compat_jobs.get("hosted-jitter")
    if not isinstance(hosted_jitter, dict):
        errors.append("compat-matrix: hosted-jitter job is missing")
    else:
        hosted_env = hosted_jitter.get("env", {})
        if hosted_env.get("IRL_SRT_SERVER_SHA") != (
            "02fd73e3ef7795c1c631350adb8a873af67f1c4a"
        ):
            errors.append("compat-matrix: hosted-jitter irl-srt-server pin is not immutable")
        if hosted_env.get("SRT_SHA") != (
            "b06fdb6b85937f3f5cf5452b150a6bb7e35b0226"
        ):
            errors.append("compat-matrix: hosted-jitter SRT 1.5.6 pin is not immutable")
        if hosted_env.get("SRTLA_SEND_RS_SHA") != (
            "2a4ecd4a7d6e84cbcec56b09eecbf721838dc4d8"
        ):
            errors.append("compat-matrix: hosted-jitter Rust sender pin is not immutable")
        hosted_if = str(hosted_jitter.get("if", ""))
        if (
            "github.event_name == 'workflow_dispatch'" not in hosted_if
            or "github.event.action == 'labeled'" not in hosted_if
            or "github.event.label.name == 'privileged-ci-approved'" not in hosted_if
        ):
            errors.append(
                "compat-matrix: hosted-jitter PR execution lacks exact-head maintainer approval"
            )
        hosted_checkout = next(
            (
                step
                for step in hosted_jitter.get("steps", [])
                if isinstance(step, dict) and step.get("name") == "Checkout srtla"
            ),
            {},
        )
        if hosted_checkout.get("with", {}).get("ref") != (
            "${{ github.event.pull_request.head.sha || github.sha }}"
        ):
            errors.append(
                "compat-matrix: hosted-jitter does not checkout the approved PR head SHA"
            )
        if hosted_env.get("SRTLA_SOURCE_SHA") != (
            "${{ github.event.pull_request.head.sha || github.sha }}"
        ):
            errors.append(
                "compat-matrix: hosted-jitter provenance is not bound to the approved PR head SHA"
            )
        hosted_commands = executable_run_text(hosted_jitter)
        if (
            'resolved_srtla_sha="$(git rev-parse HEAD)"' not in hosted_commands
            or 'test "$resolved_srtla_sha" = "$SRTLA_SOURCE_SHA"' not in hosted_commands
            or '--arg srtla_sha "$resolved_srtla_sha"' not in hosted_commands
        ):
            errors.append(
                "compat-matrix: hosted-jitter records event SHA instead of checked-out source SHA"
            )
        if (
            "build-hosted-irl/bin/srt_server" not in hosted_commands
            or 'grep -q "SRT profile: L3-direct"' not in hosted_commands
            or 'wait "$irl_pid"' not in hosted_commands
            or "irl-srt-server-ldd.txt" not in hosted_commands
        ):
            errors.append(
                "compat-matrix: hosted-jitter does not exercise the pinned irl-srt-server runtime"
            )
        if "tests/compat/scenarios/jitter-stress.sh" not in hosted_commands:
            errors.append("compat-matrix: hosted-jitter does not run jitter-stress")
        if "sudo -n" not in hosted_commands:
            errors.append("compat-matrix: hosted-jitter does not use the sanctioned sudo gate")
        if ".pass == true" not in hosted_commands or ".skipped != true" not in hosted_commands:
            errors.append("compat-matrix: hosted-jitter can accept a skip or misleading PASS")
        if (
            "REQUIRE_RS_SENDER=1" not in hosted_commands
            or '.sender.kind == "rust"' not in hosted_commands
        ):
            errors.append("compat-matrix: hosted-jitter can fall back to the retired C sender")
        hosted_uploads = [
            step
            for step in hosted_jitter.get("steps", [])
            if isinstance(step, dict)
            and str(step.get("uses", "")).startswith("actions/upload-artifact@")
        ]
        if (
            len(hosted_uploads) != 1
            or hosted_uploads[0].get("if") != "${{ always() }}"
            or hosted_uploads[0].get("with", {}).get("name")
            != "hosted-jitter-${{ env.SRTLA_SOURCE_SHA }}"
            or hosted_uploads[0].get("with", {}).get("if-no-files-found") != "error"
        ):
            errors.append("compat-matrix: hosted-jitter must always upload non-empty evidence")
        require_ccache(
            "compat-matrix",
            "hosted-jitter",
            hosted_jitter,
            direct_build=True,
        )
    if compat_jobs.get("generate-matrix", {}).get("if") != (
        "${{ github.event_name != 'workflow_dispatch' }}"
    ):
        errors.append("compat-matrix: manual jitter dispatch also starts the pair matrix")

    jitter_script = (
        repo_root / "tests" / "compat" / "scenarios" / "jitter-stress.sh"
    ).read_text(encoding="utf-8")
    ready_marker = "wait_for_connection_count 1 10"
    caller_marker = "ffmpeg -hide_banner"
    if (
        ready_marker not in jitter_script
        or caller_marker not in jitter_script
        or jitter_script.index(ready_marker) > jitter_script.index(caller_marker)
    ):
        errors.append(
            "jitter-stress: media caller starts before an upstream link is ready"
        )
    if (
        'LINK2_SRC="10.173.${OCTET}.4"' not in jitter_script
        or "LINK2_PEER=" in jitter_script
    ):
        errors.append(
            "jitter-stress: second link does not preserve the receiver source address"
        )

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
    build_check.get("jobs", {}).get("build"),
    static_test,
]
if workflow_exists("compat-matrix.yml"):
    ccache_jobs.extend(
        compat_jobs.get(name)
        for name in (
            "compat-blocking",
            "compat-informational",
            "hosted-jitter",
            "pcap-replay",
            "upstream-drift",
        )
    )
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
    "workflow-contracts: receiver-only workflow set, build-check and clang-tidy "
    "cache contracts pass; "
    f"ccache budget {len(active_keys)}x{CCACHE_MAXSIZE}={active_ccache_mb}MB"
)
PY
