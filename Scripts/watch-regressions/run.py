#!/usr/bin/env python3
"""Compile actual Watch orchestration against Core and hardware-only host stubs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


# Add new Watch model files to MANIFEST, in shared or the relevant program's sources.
MANIFEST = {
    "core_targets": ("WatchPlayback", "WatchProtocol", "PlayerCore", "ABSApi"),
    "shared": (
        "WatchDownloadManager.swift", "WatchDownloadManager+Events.swift",
        "WatchDownloadURLSessionAdapter.swift",
        "WatchSetupReceiver.swift",
        "WatchNetworkStatus.swift", "WatchDiagnostics.swift",
        "WatchBrowseModel.swift", "WatchPhoneBrowseModel.swift", "WatchHomeProjection.swift",
        "WatchNavigationPolicy.swift", "WatchABSEnqueue.swift", "WatchABSRequestDriver.swift",
        "WatchDownloadRowPresentation.swift", "WatchSessionContext.swift",
        "WatchSessionController.swift", "WatchCatalogueController.swift",
        "WatchPlaybackController.swift", "WatchPlaybackController+Preparation.swift",
        "WatchPlaybackController+Handoff.swift", "WatchPlaybackController+Progress.swift",
        "WatchPlaybackController+Effects.swift",
        "WatchOfflineSyncController.swift",
        "WatchDownloadController.swift", "WatchEpisodeSync.swift", "WatchEpisodeSync+Offer.swift",
        "WatchEpisodeSync+Inventory.swift", "WatchNativePlayback.swift",
        "WatchNativeEpisodeRows.swift",
        "WatchRSSDownloadValues.swift", "WatchRSSDownloadStaging.swift",
        "WatchRSSTransferState.swift", "WatchRSSDownloadURLSessionAdapter.swift",
        "WatchRSSDownloadDriver.swift", "WatchRSSDownloadDriver+Completion.swift",
        "WatchReceivedEpisode+Download.swift",
        "WatchRSSDiagnostics.swift",
        "WatchDisplayFormatting.swift",
    ),
    "cross_target": (),
    "stubs": ("HardwareStubs.swift",),
    # Compiled into every program: the bounded waits that replace hand-written yield loops.
    "always": ("HostWaiting.swift",),
    "programs": {
        "DownloadRegression": {
            "combined": ("WatchDownloadURLSessionAdapter.swift", "WatchDownloadManager.swift",
                         "WatchDownloadManager+Events.swift", "WatchDiagnostics.swift"),
        },
        "PaginationRegression": {
            "shared": True,
            "combined": ("WatchLibraryModel.swift", "WatchApplicationContextPublisher.swift"),
        },
        "PlaybackPolicyRegression": {
            "shared": True,
            "combined": ("WatchLibraryModel.swift", "WatchApplicationContextPublisher.swift"),
        },
        "DownloadGroupRegression": {
            "sources": ("WatchDownloadRowPresentation.swift", "WatchNetworkStatus.swift"),
        },
        "NavigationRegression": {"sources": ("WatchNavigationPolicy.swift",)},
        "ChapterListRegression": {"sources": ("WatchDisplayFormatting.swift",)},
        "PhoneBrowseRegression": {
            "sources": ("WatchPhoneBrowseModel.swift", "WatchBrowseModel.swift",
                        "WatchDisplayFormatting.swift", "WatchCommandOutcome.swift"),
        },
        "HomeProjectionRegression": {
            "sources": ("WatchHomeProjection.swift", "WatchNavigationPolicy.swift"),
        },
        "RefreshWakeRegression": {"sources": ("WatchRefreshWake.swift",)},
    },
}

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Packages/Core"
SOURCE = ROOT / "App/WhirrWatch Watch App"
SHARED_SOURCE = ROOT / "App/WatchShared"
HERE = Path(__file__).resolve().parent
TIMEOUT_SECONDS = 120
BUILD_HINT = "Build Core debug first: swift build --package-path Packages/Core"


def core_build_directory(env):
    fallback = CORE / ".build/arm64-apple-macosx/debug"
    try:
        result = subprocess.run(
            ["swift", "build", "--package-path", str(CORE), "--configuration", "debug",
             "--show-bin-path", "--disable-sandbox"],
            check=True, capture_output=True, text=True, env=env, timeout=TIMEOUT_SECONDS,
        )
        if result.stdout.strip():
            return Path(result.stdout.strip()).resolve()
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Core build-path lookup unavailable ({error}); using {fallback}", file=sys.stderr)
    return fallback


def core_module_directory(build):
    """The native build system keeps modules under Modules/; Swift Build puts them beside the objects."""
    return build / "Modules" if (build / "Modules").is_dir() else build


def swift_build_objects(build):
    """Swift Build links each target into one prelinked Name.o next to Name.swiftmodule."""
    objects = []
    for target in MANIFEST["core_targets"]:
        obj = build / f"{target}.o"
        if not obj.is_file():
            raise RuntimeError(f"Core debug target {target} is missing object {obj}. {BUILD_HINT}")
        if not (build / f"{target}.swiftmodule").exists():
            raise RuntimeError(f"Core debug target {target} is missing its module at {build}. {BUILD_HINT}")
        objects.append(str(obj))
    return objects


def core_objects(build):
    if not (build / "Modules").is_dir():
        if any((build / f"{target}.swiftmodule").exists() for target in MANIFEST["core_targets"]):
            return swift_build_objects(build)
        raise RuntimeError(f"Core debug build is absent at {build}. {BUILD_HINT}")
    objects = []
    for target in MANIFEST["core_targets"]:
        output_map = build / f"{target}.build/output-file-map.json"
        try:
            entries = json.loads(output_map.read_text())
            target_objects = sorted({entry["object"] for entry in entries.values() if "object" in entry})
        except (OSError, ValueError, AttributeError, TypeError) as error:
            raise RuntimeError(f"Core debug target {target}: cannot read {output_map}. {BUILD_HINT}") from error
        if not target_objects:
            raise RuntimeError(f"Core debug target {target} produced no objects at {build}. {BUILD_HINT}")
        for filename in target_objects:
            path = Path(filename)
            if not path.is_absolute():
                path = CORE / path
            if not path.is_file():
                raise RuntimeError(f"Core debug target {target} is missing object {path}. {BUILD_HINT}")
            objects.append(str(path))
        if not (build / "Modules" / f"{target}.swiftmodule").exists():
            raise RuntimeError(f"Core debug target {target} is missing its module at {build}. {BUILD_HINT}")
    return objects


def run_step(name, command, env):
    try:
        subprocess.run(command, check=True, env=env, timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"{name}: timed out after {TIMEOUT_SECONDS} s") from error
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"{name}: failed with exit code {error.returncode}") from error
    except OSError as error:
        raise RuntimeError(f"{name}: could not start: {error}") from error


def program_sources(name, program, out):
    sources = [SOURCE / filename for filename in program.get("sources", ())]
    sources += [HERE / filename for filename in MANIFEST["always"]]
    if program.get("shared"):
        sources += [SOURCE / filename for filename in MANIFEST["shared"]]
        sources += [SHARED_SOURCE / filename for filename in MANIFEST["cross_target"]]
        sources += [HERE / filename for filename in MANIFEST["stubs"]]
    regression = HERE / f"{name}.swift"
    if program.get("combined"):
        # File-private regression probes need the model and program in one compilation unit.
        combined = out / f"{name}-Combined.swift"
        inputs = [SOURCE / filename for filename in program["combined"]] + [regression]
        combined.write_text("\n".join(path.read_text() for path in inputs))
        sources.append(combined)
    else:
        sources.append(regression)
    return [str(path) for path in sources]


def main():
    env = dict(os.environ,
               CLANG_MODULE_CACHE_PATH=str(CORE / ".build/mcache"),
               XDG_CACHE_HOME=str(CORE / ".build/xdg"))
    for key in ("CLANG_MODULE_CACHE_PATH", "XDG_CACHE_HOME"):
        Path(env[key]).mkdir(parents=True, exist_ok=True)
    build = core_build_directory(env)
    objects = core_objects(build)
    print(f"Using Core debug build: {build}", flush=True)
    with tempfile.TemporaryDirectory(prefix="watch-regressions-") as folder:
        out = Path(folder)
        run_step("WatchConnectivity stub compile", [
            "swiftc", "-emit-module", "-emit-module-path", str(out / "WatchConnectivity.swiftmodule"),
            "-emit-library", "-module-name", "WatchConnectivity",
            str(HERE / "WatchConnectivityStub.swift"), "-o", str(out / "libWatchConnectivity.dylib"),
        ], env)
        for name, program in MANIFEST["programs"].items():
            print(f"Running {name}", flush=True)
            try:
                sources = program_sources(name, program, out)
            except OSError as error:
                raise RuntimeError(f"{name}: cannot read manifest sources: {error}") from error
            executable = out / name
            run_step(f"{name} compile", [
                "swiftc", "-parse-as-library", "-swift-version", "5", "-I", str(core_module_directory(build)),
                "-I", str(out), "-L", str(out), "-lWatchConnectivity",
                "-Xlinker", "-rpath", "-Xlinker", str(out),
                *sources, *objects, "-o", str(executable),
            ], env)
            run_step(name, [str(executable)], env)
            print(f"PASS {name}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        print(f"Watch regressions: {error}", file=sys.stderr)
        sys.exit(1)
