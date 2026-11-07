"""Reading the quantity strings the quota system uses.

The distinction that matters is decimal against binary: ``4Gi`` is not ``4G``,
and treating a memory quota as decimal makes a full namespace look two per cent
empty.
"""

from __future__ import annotations

import unittest

from support import NAMESPACE  # noqa: F401  - applies the sys.path bootstrap

import quantities


class ParseTests(unittest.TestCase):
    def test_plain_integer(self):
        parsed = quantities.parse("16")
        assert parsed is not None
        self.assertEqual(parsed.value, 16)

    def test_decimal_suffixes_are_powers_of_a_thousand(self):
        assert quantities.parse("2k") is not None
        self.assertEqual(quantities.parse("2k").value, 2000)
        self.assertEqual(quantities.parse("3G").value, 3_000_000_000)

    def test_binary_suffixes_are_powers_of_1024(self):
        self.assertEqual(quantities.parse("1Ki").value, 1024)
        self.assertEqual(quantities.parse("1Mi").value, 1024**2)
        self.assertEqual(quantities.parse("4Gi").value, 4 * 1024**3)

    def test_gigabytes_and_gibibytes_differ(self):
        decimal = quantities.parse("4G")
        binary = quantities.parse("4Gi")
        assert decimal is not None and binary is not None
        self.assertGreater(binary.value, decimal.value)

    def test_sub_normal_suffixes(self):
        self.assertAlmostEqual(quantities.parse("500m").value, 0.5)
        self.assertAlmostEqual(quantities.parse("900n").value, 0.0000009)

    def test_fractional_number(self):
        self.assertAlmostEqual(quantities.parse("1.5Gi").value, 1.5 * 1024**3)

    def test_unreadable_values_are_none(self):
        for value in (None, "", "lots", "50%", "abcGi"):
            with self.subTest(value=value):
                self.assertIsNone(quantities.parse(value))

    def test_binary_flag(self):
        assert quantities.parse("4Gi") is not None and quantities.parse("4G") is not None
        self.assertTrue(quantities.parse("4Gi").is_binary)
        self.assertFalse(quantities.parse("4G").is_binary)


class RatioTests(unittest.TestCase):
    def test_half_full(self):
        self.assertEqual(quantities.percent_used("8", "16"), 50)

    def test_mixed_units_of_the_same_family(self):
        # 4Gi against a 16Gi quota is 25%, and both sides are binary.
        self.assertEqual(quantities.percent_used("4Gi", "16Gi"), 25)

    def test_a_fractional_cpu_quantity(self):
        self.assertEqual(quantities.percent_used("500m", "2"), 25)

    def test_over_the_limit_is_clamped(self):
        self.assertEqual(quantities.percent_used("20", "16"), 100)

    def test_no_limit_means_no_percentage(self):
        self.assertIsNone(quantities.percent_used("3", "0"))
        self.assertIsNone(quantities.percent_used("3", None))
        self.assertIsNone(quantities.percent_used(None, "16"))

    def test_unreadable_input_gives_no_percentage_rather_than_zero(self):
        # Zero would render as an empty bar and read as "nothing used".
        self.assertIsNone(quantities.percent_used("3", "16 potatoes"))


class HumaniseTests(unittest.TestCase):
    def test_keeps_the_string_the_api_sent(self):
        self.assertEqual(quantities.humanise("4Gi"), "4Gi")
        self.assertEqual(quantities.humanise("500m"), "500m")

    def test_empty_becomes_zero(self):
        self.assertEqual(quantities.humanise(None), "0")
        self.assertEqual(quantities.humanise(""), "0")


if __name__ == "__main__":
    unittest.main()
