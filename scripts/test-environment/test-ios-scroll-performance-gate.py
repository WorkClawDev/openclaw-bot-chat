#!/usr/bin/env python3
"""Schema-based parser checks; these are NOT real physical performance results."""
import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("scroll_gate", pathlib.Path(__file__).with_name("ios-scroll-performance-gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ScrollGateTests(unittest.TestCase):
    def setUp(self):
        device = {"deviceId": "synthetic-device", "modelName": "iPhone test fixture",
                  "platform": "iOS", "architecture": "arm64", "osVersion": "test"}
        self.summary = {"result": "Passed", "failedTests": 0, "skippedTests": 0,
                        "devicesAndConfigurations": [{"device": device}]}
        self.details = {"testIdentifier": gate.TEST_ID, "testResult": "Passed",
                        "hasPerformanceMetrics": True, "devices": [device]}
        self.metrics = [{"testIdentifier": gate.TEST_ID, "testRuns": [{
            "device": {"deviceId": "synthetic-device"}, "metrics": [
                {"displayName": "Scrolling and Deceleration Hitch Time Ratio",
                 "unitOfMeasurement": "ms/s", "measurements": [0, 1, 2, 3, 4.9]},
                {"displayName": "Scrolling and Deceleration Duration",
                 "unitOfMeasurement": "s", "measurements": [1, 1, 1, 1, 1]}
            ]}]}]

    def run_gate(self):
        return gate.evaluate(self.summary, self.details, self.metrics)

    def test_good_schema_and_millisecond_duration(self):
        self.assertEqual(self.run_gate()["result"], "passed")
        duration = self.metrics[0]["testRuns"][0]["metrics"][1]
        duration.update(unitOfMeasurement="ms", measurements=[1000]*5)
        self.assertEqual(self.run_gate()["runs"][0]["scroll_duration_seconds"], [1]*5)

    def test_simulator_rejected_even_with_invented_good_metrics(self):
        self.summary["devicesAndConfigurations"][0]["device"]["platform"] = "iOS Simulator"
        with self.assertRaises(gate.GateFailure): self.run_gate()

    def test_failed_skipped_or_missing_case_rejected(self):
        for change in ({"testResult": "Skipped"}, {"testResult": "Failed"},
                       {"testIdentifier": "Other/test()"}, {"hasPerformanceMetrics": False}):
            with self.subTest(change=change):
                original = copy.deepcopy(self.details)
                self.details.update(change)
                with self.assertRaises(gate.GateFailure): self.run_gate()
                self.details = original
        self.summary["skippedTests"] = 1
        with self.assertRaises(gate.GateFailure): self.run_gate()

    def test_outlier_cannot_hide_in_good_average(self):
        self.metrics[0]["testRuns"][0]["metrics"][0]["measurements"] = [0, 0, 0, 0, 5]
        with self.assertRaises(gate.GateFailure): self.run_gate()

    def test_missing_duplicate_unknown_or_incomplete_metrics_rejected(self):
        original = copy.deepcopy(self.metrics)
        cases = [
            [], [{"testIdentifier": gate.TEST_ID, "testRuns": []}],
            original + copy.deepcopy(original),
        ]
        for value in cases:
            with self.subTest(value=value):
                self.metrics = value
                with self.assertRaises(gate.GateFailure): self.run_gate()
        self.metrics = original
        ratio = self.metrics[0]["testRuns"][0]["metrics"][0]
        for values in ([], [1]*4, [0, 0, 0, 0, float("nan")],
                       [0, 0, 0, 0, float("inf")], [0, 0, 0, 0, -1], [True]*5):
            with self.subTest(values=values):
                ratio["measurements"] = values
                with self.assertRaises(gate.GateFailure): self.run_gate()
        ratio["measurements"] = [0]*5
        ratio["unitOfMeasurement"] = "%"
        with self.assertRaises(gate.GateFailure): self.run_gate()

    def test_zero_scrolling_or_mismatched_device_rejected(self):
        run = self.metrics[0]["testRuns"][0]
        run["metrics"][1]["measurements"] = [0]*5
        with self.assertRaises(gate.GateFailure): self.run_gate()
        run["metrics"][1]["measurements"] = [1]*5
        run["device"]["deviceId"] = "unrelated"
        with self.assertRaises(gate.GateFailure): self.run_gate()


if __name__ == "__main__":
    unittest.main()
