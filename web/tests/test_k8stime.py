"""Parsing the timestamps the API server writes."""

from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone

from support import NAMESPACE  # noqa: F401  - applies the sys.path bootstrap

from k8stime import elapsed_since, format_timestamp, parse_timestamp, seconds_between


class ParseTests(unittest.TestCase):
    def test_reads_the_zulu_form_the_api_writes(self):
        parsed = parse_timestamp("2026-10-25T03:00:05Z")
        self.assertEqual(parsed, datetime(2026, 10, 25, 3, 0, 5, tzinfo=timezone.utc))

    def test_reads_an_explicit_offset(self):
        parsed = parse_timestamp("2026-10-25T03:00:05+00:00")
        self.assertEqual(parsed, datetime(2026, 10, 25, 3, 0, 5, tzinfo=timezone.utc))

    def test_reads_fractional_seconds(self):
        parsed = parse_timestamp("2026-10-25T03:00:05.123456Z")
        assert parsed is not None
        self.assertEqual(parsed.microsecond, 123456)

    def test_assumes_utc_when_the_offset_is_missing(self):
        parsed = parse_timestamp("2026-10-25T03:00:05")
        assert parsed is not None
        self.assertEqual(parsed.tzinfo, timezone.utc)

    def test_converts_an_offset_to_utc(self):
        parsed = parse_timestamp("2026-10-25T03:00:05-04:00")
        self.assertEqual(parsed, datetime(2026, 10, 25, 7, 0, 5, tzinfo=timezone.utc))

    def test_missing_and_malformed_values_are_none(self):
        for value in (None, "", "   ", "yesterday", 12345, "2026-13-45T99:99:99Z"):
            with self.subTest(value=value):
                self.assertIsNone(parse_timestamp(value))


class FormatTests(unittest.TestCase):
    def test_round_trips(self):
        text = "2026-10-25T03:00:05Z"
        self.assertEqual(format_timestamp(parse_timestamp(text)), text)

    def test_none_is_none(self):
        self.assertIsNone(format_timestamp(None))


class DurationTests(unittest.TestCase):
    def test_seconds_between_two_moments(self):
        start = parse_timestamp("2026-10-25T03:00:05Z")
        end = parse_timestamp("2026-10-25T03:42:05Z")
        self.assertEqual(seconds_between(start, end), 2520)

    def test_unknown_ends_give_no_duration(self):
        self.assertIsNone(seconds_between(None, None))
        self.assertIsNone(seconds_between(parse_timestamp("2026-10-25T03:00:05Z"), None))

    def test_a_clock_that_went_backwards_does_not_produce_a_negative(self):
        start = parse_timestamp("2026-10-25T03:00:05Z")
        end = parse_timestamp("2026-10-25T02:00:05Z")
        self.assertEqual(seconds_between(start, end), 0)

    def test_elapsed_uses_the_supplied_now(self):
        start = parse_timestamp("2026-10-25T03:00:00Z")
        now = start + timedelta(minutes=7)
        self.assertEqual(elapsed_since(start, now), 420)


if __name__ == "__main__":
    unittest.main()
