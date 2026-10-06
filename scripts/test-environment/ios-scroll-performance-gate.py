#!/usr/bin/env python3
"""Fail-closed physical scrolling acceptance from a sealed XCTest result.

Run the physical performance case in Release without debugger, sanitizers or
coverage, then pass its xcresult directory here. Never treats simulator timing,
missing metrics or a skipped performance case as a successful device result.
"""
import argparse
import json
import math
import pathlib
import re
import subprocess
import sys

TEST_ID = "ChatRoomV2ScrollRegressionUITests/testPhysicalMixedContentScrollPerformance()"
MIN_ITERATIONS = 5
MAX_HITCH_MS_PER_SECOND = 5.0


class GateFailure(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise GateFailure(message)


def measurements(metric):
    values = metric.get("measurements", [])
    require(isinstance(values, list) and len(values) >= MIN_ITERATIONS,
            "Each metric needs at least five measured iterations")
    require(all(type(v) in (int, float) and math.isfinite(v) and v >= 0 for v in values),
            "Metrics must contain finite nonnegative numbers")
    return values


def normalized(value):
    return re.sub(r"[^a-z0-9]", "", value.lower())


def evaluate(summary, details, metrics):
    require(summary.get("result") == "Passed" and summary.get("failedTests") == 0
            and summary.get("skippedTests") == 0, "Result bundle must pass without failures or skips")
    require(details.get("testIdentifier") == TEST_ID and details.get("testResult") == "Passed",
            "The physical scrolling case must be present and pass")
    require(details.get("hasPerformanceMetrics") is True, "Physical case has no performance metrics")
    devices = {item["device"]["deviceId"]: item["device"]
               for item in summary.get("devicesAndConfigurations", [])}
    target = [entry for entry in metrics if entry.get("testIdentifier") == TEST_ID]
    require(len(target) == 1, "Expected exactly one physical scrolling test in metric export")
    runs = target[0].get("testRuns", [])
    require(bool(runs), "No measured test runs")
    accepted = []
    for run in runs:
        device = devices.get(run.get("device", {}).get("deviceId"), {})
        require(device.get("platform") == "iOS" and device.get("architecture") in ("arm64", "arm64e"),
                "Only a physical ARM64 iOS device can establish frame pacing")
        require(any(d.get("deviceId") == device.get("deviceId") for d in details.get("devices", [])),
                "Metric device does not match the physical test")
        rows = run.get("metrics", [])
        ratios = [m for m in rows if normalized(m.get("displayName", "")).endswith("hitchtimeratio")]
        durations = [m for m in rows if normalized(m.get("displayName", "")).endswith("duration")]
        require(len(ratios) == 1 and len(durations) == 1,
                "Expected one scroll hitch-time ratio and one duration metric; inspect unknown metric names")
        ratio, duration = ratios[0], durations[0]
        require(ratio.get("unitOfMeasurement") == "ms/s", "Hitch ratio unit must be ms/s")
        ratio_values = measurements(ratio)
        duration_values = measurements(duration)
        require(len(ratio_values) == len(duration_values), "Iteration counts do not match")
        unit = duration.get("unitOfMeasurement")
        require(unit in ("s", "ms"), "Duration unit must be s or ms")
        seconds = [v / 1000 if unit == "ms" else v for v in duration_values]
        require(all(v >= 0.1 for v in seconds), "Each iteration must contain measurable scrolling")
        require(all(v < MAX_HITCH_MS_PER_SECOND for v in ratio_values),
                "One or more iterations exceed the strict <5 ms/s hitch threshold")
        accepted.append({
            "device_model": device.get("modelName"),
            "os_version": device.get("osVersion"),
            "iterations": len(ratio_values),
            "hitch_ratio_ms_per_second": ratio_values,
            "maximum_hitch_ratio": max(ratio_values),
            "scroll_duration_seconds": seconds,
        })
    return {
        "result": "passed", "test": TEST_ID,
        "threshold": "every measured iteration <5 ms/s; at least five iterations",
        "runs": accepted,
        "scope": "Physical fixture scrolling only; not all app flows or provider acceptance",
    }


def export(bundle, kind, test=False):
    args = ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(bundle), "--compact"]
    if test:
        args += ["--test-id", TEST_ID]
    result = subprocess.run(args, capture_output=True, text=True)
    require(result.returncode == 0, "xcresult export failed for " + kind + "; result may be incomplete or test absent")
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        report = evaluate(export(args.result_bundle, "summary"),
                          export(args.result_bundle, "test-details", True),
                          export(args.result_bundle, "metrics", True))
    except (GateFailure, ValueError, KeyError, TypeError, OSError) as error:
        report = {"result": "not_accepted", "reason": str(error), "test": TEST_ID}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
