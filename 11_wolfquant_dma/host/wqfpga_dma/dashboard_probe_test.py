#!/usr/bin/env python3
"""Check dashboard JSON semantics without claiming a hardware test."""

import json
import unittest

from dashboard_probe import build_report, sums_as_strings
from moments_vol20_demo import cpu_integer_moments


class DashboardProbeTests(unittest.TestCase):
    def test_self_test_has_no_fpga_result(self):
        report = build_report()
        self.assertEqual(report["mode"], "cpu-self-test")
        self.assertIsNone(report["fpga"])
        self.assertEqual(report["sample"]["pair_count"], 20)

    def test_live_result_is_exact_and_serializes_64_bit_sums_as_strings(self):
        def fake_call(_device, _payload, _pairs):
            return cpu_integer_moments(report_raw)

        report_raw = [4404, -5743, 4620, 8467, -2074, 4260, -6105,
                      5413, 9113, -2669, 7102, -3680, -2667, 8022,
                      7247, -2737, 5183, -6675, 5598, 5467]
        report = build_report("/dev/fake", fake_call)
        self.assertTrue(report["fpga"]["exact_match"])
        self.assertTrue(report["fpga"]["reconstruction_match"])
        self.assertEqual(report["fpga"]["sums"], report["cpu"]["sums"])
        encoded = json.dumps(sums_as_strings((-(1 << 55), 0, 1 << 55, 0, 0)))
        self.assertIn('"-36028797018963968"', encoded)
        self.assertIn('"36028797018963968"', encoded)

    def test_bad_fpga_sum_is_visible_as_a_failed_comparison(self):
        def bad_call(_device, _payload, _pairs):
            return (0, 0, 0, 0, 0)

        report = build_report("/dev/fake", bad_call)
        self.assertFalse(report["fpga"]["exact_match"])
        self.assertNotEqual(report["fpga"]["sums"], report["cpu"]["sums"])


if __name__ == "__main__":
    unittest.main()
