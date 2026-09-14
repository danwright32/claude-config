"""Tests for the coffee tracker analysis script.

Every seam the script has is set here: the Downloads directory it scans, the
CSV it reads, and the state directory it remembers the previous run in. None
of them is left real, so the suite never touches the actual tracker export or
the actual run history (LESSONS L284, L2).

TestFirstExport reads a frozen copy of the real export the first profile
was built from (tests/fixtures/export-2026-09-14.csv), so the numbers that
profile reported stay pinned however the live sheet grows.
"""
import csv
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
sys.path.insert(0, str(SKILL))

import analyze  # noqa: E402

HEADER = (HERE / "fixtures" / "header.txt").read_text().strip().split(",")
FIRST_EXPORT = HERE / "fixtures" / "export-2026-09-14.csv"


def row(**fields):
    """Build one CSV row against the REAL header, blanks everywhere else."""
    cells = [""] * len(HEADER)
    for key, value in fields.items():
        cells[HEADER.index(key)] = value
    return cells


# A synthetic log shaped so one roaster carries a whole roast level.
# Bad Co is three medium-light coffees scored 1, 2, 3. Mid Co has two
# medium-light coffees scored 7 and 6. So medium-light averages 3.8 with
# Bad Co and 6.5 without it: the confound the script must name.
FIXTURE_ROWS = [
    row(**{"Coffee Name": "Alpha", "Roaster": "Good Co", "Roast Level": "Dark", "Grind": "Whole Bean",
           "Type": "Blend", "Milling Process": "", "Boldness": "5 – Incredibly bold", "Bitterness": "5 – No bitterness at all",
           "Sweetness": "5 – Subtle hint", "Aftertaste": "5 – Amazing", "Smoothness": "5 – Silky", "Aroma": "4 – Nice aroma",
           "Overall Enjoyment": "9 – Fantastic", "Buy Again?": "3 - Yes"}),
    row(**{"Coffee Name": "Bravo", "Roaster": "Good Co", "Roast Level": "Dark", "Grind": "Whole Bean",
           "Type": "Blend", "Milling Process": "", "Boldness": "4 – Full-bodied", "Bitterness": "4 – Slight",
           "Sweetness": "4 – No sweetness", "Aftertaste": "4 – Rich", "Smoothness": "4 – Very smooth", "Aroma": "3 – Decent",
           "Overall Enjoyment": "8 – Really liked it", "Buy Again?": "3 - Yes"}),
    row(**{"Coffee Name": "Charlie", "Roaster": "Good Co", "Roast Level": "Medium-Dark", "Grind": "Pre-Ground",
           "Type": "Blend", "Milling Process": "", "Boldness": "4 – Full-bodied", "Bitterness": "4 – Slight",
           "Sweetness": "3 – Noticeable", "Aftertaste": "3 – Pleasant", "Smoothness": "4 – Very smooth", "Aroma": "3 – Decent",
           "Overall Enjoyment": "7 – Solid choice", "Buy Again?": "3 - Yes"}),
    row(**{"Coffee Name": "Delta", "Roaster": "Bad Co", "Roast Level": "Medium-Light", "Grind": "Whole Bean",
           "Type": "Single-Origin", "Milling Process": "Fully Washed", "Boldness": "1 – Weak", "Bitterness": "3 – Balanced",
           "Sweetness": "1 – Way too sweet", "Aftertaste": "1 – Unpleasant", "Smoothness": "2 – A little rough", "Aroma": "2 – Faint",
           "Overall Enjoyment": "1 – Can’t stand it", "Buy Again?": "1 - No"}),
    row(**{"Coffee Name": "Echo", "Roaster": "Bad Co", "Roast Level": "Medium-Light", "Grind": "Whole Bean",
           "Type": "Single-Origin", "Milling Process": "Fully Washed", "Boldness": "2 – Mild", "Bitterness": "3 – Balanced",
           "Sweetness": "1 – Way too sweet", "Aftertaste": "2 – Short", "Smoothness": "3 – Smooth enough", "Aroma": "2 – Faint",
           "Overall Enjoyment": "2 – Not great", "Buy Again?": "1 - No"}),
    row(**{"Coffee Name": "Foxtrot", "Roaster": "Bad Co", "Roast Level": "Medium-Light", "Grind": "Whole Bean",
           "Type": "Single-Origin", "Milling Process": "Fully Washed", "Boldness": "2 – Mild", "Bitterness": "2 – Strong",
           "Sweetness": "2 – Too much", "Aftertaste": "2 – Short", "Smoothness": "3 – Smooth enough", "Aroma": "1 – Harsh",
           "Overall Enjoyment": "3 – Meh", "Buy Again?": "1 - No"}),
    row(**{"Coffee Name": "Golf", "Roaster": "Mid Co", "Roast Level": "Medium-Light", "Grind": "Whole Bean",
           "Type": "Single-Origin", "Milling Process": "", "Boldness": "4 – Full-bodied", "Bitterness": "5 – No bitterness at all",
           "Sweetness": "3 – Noticeable", "Aftertaste": "4 – Rich", "Smoothness": "4 – Very smooth", "Aroma": "",
           "Overall Enjoyment": "7 – Solid choice", "Buy Again?": "3 - Yes"}),
    row(**{"Coffee Name": "Hotel", "Roaster": "Mid Co", "Roast Level": "Dark", "Grind": "Pre-Ground",
           "Type": "Blend", "Milling Process": "", "Boldness": "3 – Medium-bodied", "Bitterness": "4 – Slight",
           "Sweetness": "3 – Noticeable", "Aftertaste": "3 – Pleasant", "Smoothness": "4 – Very smooth", "Aroma": "3 – Decent",
           "Overall Enjoyment": "6 – Pretty good", "Buy Again?": "2 - Would Consider"}),
    row(**{"Coffee Name": "India", "Roaster": "Mid Co", "Roast Level": "Light", "Grind": "Whole Bean",
           "Type": "Single-Origin", "Milling Process": "Fully Washed", "Boldness": "3 – Medium-bodied", "Bitterness": "2 – Strong",
           "Sweetness": "3 – Noticeable", "Aftertaste": "3 – Pleasant", "Smoothness": "3 – Smooth enough", "Aroma": "2 – Faint",
           "Overall Enjoyment": "5 – Decent", "Buy Again?": "2 - Would Consider"}),
    row(**{"Coffee Name": "Juliet", "Roaster": "Mid Co", "Roast Level": "", "Grind": "Pre-Ground",
           "Type": "", "Milling Process": "", "Boldness": "2 – Mild", "Bitterness": "3 – Balanced",
           "Sweetness": "3 – Noticeable", "Aftertaste": "2 – Short", "Smoothness": "3 – Smooth enough", "Aroma": "2 – Faint",
           "Overall Enjoyment": "4 – Fine", "Buy Again?": "1 - No"}),
    row(**{"Coffee Name": "Kilo", "Roaster": "Mid Co", "Roast Level": "Medium-Light", "Grind": "Whole Bean",
           "Type": "Single-Origin", "Milling Process": "", "Boldness": "3 – Medium-bodied", "Bitterness": "4 – Slight",
           "Sweetness": "3 – Noticeable", "Aftertaste": "3 – Pleasant", "Smoothness": "4 – Very smooth", "Aroma": "3 – Decent",
           "Overall Enjoyment": "6 – Pretty good", "Buy Again?": "2 - Would Consider"}),
]


def write_csv(path, header, rows):
    with open(path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(header)
        writer.writerows(rows)


class Fixture(unittest.TestCase):
    """One analysis over the fixture, computed once for the whole class (L286)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.csv_path = Path(cls.tmp.name) / "Coffee Tracker - Sheet1.csv"
        write_csv(cls.csv_path, HEADER, FIXTURE_ROWS)
        cls.records = analyze.load(cls.csv_path)
        cls.result = analyze.analyze(cls.records)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()


class TestFindCsv(unittest.TestCase):
    def test_picks_newest_tracker_export_and_ignores_other_files(self):
        with tempfile.TemporaryDirectory() as d:
            old = Path(d) / "Coffee Tracker - Sheet1.csv"
            new = Path(d) / "Coffee Tracker - Sheet1 (2).csv"
            other = Path(d) / "Wine Tracker - Sheet1.csv"
            for p in (old, new, other):
                p.write_text("x")
            os.utime(old, (1_000_000, 1_000_000))
            os.utime(new, (2_000_000, 2_000_000))
            os.utime(other, (3_000_000, 3_000_000))
            self.assertEqual(analyze.find_csv(d), new)

    def test_refuses_when_no_export_present(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "Wine Tracker - Sheet1.csv").write_text("x")
            with self.assertRaises(analyze.NoExport) as ctx:
                analyze.find_csv(d)
            self.assertIn("Coffee Tracker", str(ctx.exception))
            self.assertIn(d, str(ctx.exception))


class TestLoad(unittest.TestCase):
    def test_refuses_a_renamed_column_and_names_it(self):
        header = [h if h != "Boldness" else "Body" for h in HEADER]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.csv"
            write_csv(p, header, [])
            with self.assertRaises(analyze.SchemaChanged) as ctx:
                analyze.load(p)
        self.assertIn("Boldness", str(ctx.exception))
        self.assertNotIn("Aroma", str(ctx.exception))

    def test_parses_the_leading_number_of_each_score_and_blank_as_none(self):
        self.assertEqual(analyze.score("2 – Mild, lacking body"), 2)
        self.assertEqual(analyze.score("10 – Loved it (will reorder)"), 10)
        self.assertIsNone(analyze.score(""))
        self.assertIsNone(analyze.score("Yes"))

    def test_records_carry_scores_and_trimmed_text(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.csv"
            write_csv(p, HEADER, FIXTURE_ROWS[:1])
            rec = analyze.load(p)[0]
        self.assertEqual(rec["name"], "Alpha")
        self.assertEqual(rec["enjoy"], 9)
        self.assertEqual(rec["buy"], 3)
        self.assertEqual(rec["Boldness"], 5)
        self.assertEqual(rec["roast"], "Dark")


class TestAnalyze(Fixture):
    def test_headline_counts(self):
        r = self.result
        self.assertEqual(r["n"], 11)
        self.assertEqual(r["buy"], {"yes": 4, "consider": 3, "no": 4})
        self.assertAlmostEqual(r["mean_enjoy"], 58 / 11, places=3)

    def test_attribute_correlations_and_level_means(self):
        r = self.result
        self.assertGreater(r["correlations"]["Boldness"], 0.8)
        self.assertEqual(r["correlation_n"]["Aroma"], 10)  # one blank aroma
        self.assertEqual(r["level_means"]["Boldness"]["4"]["n"], 3)
        self.assertAlmostEqual(r["level_means"]["Boldness"]["4"]["mean"], 22 / 3, places=3)

    def test_groups_report_blank_counts_separately(self):
        proc = self.result["groups"]["process"]
        self.assertEqual(proc["blank"], 7)
        self.assertEqual(proc["values"]["Fully Washed"]["n"], 4)
        roast = self.result["groups"]["roast"]
        self.assertEqual(roast["blank"], 1)
        self.assertEqual(roast["values"]["Dark"], {"n": 3, "mean": 23 / 3, "yes": 2, "no": 0})

    def test_confound_names_the_roaster_that_carries_a_group(self):
        flags = self.result["confounds"]
        ml = [f for f in flags if f["group"] == "roast" and f["value"] == "Medium-Light"]
        self.assertEqual(len(ml), 1)
        self.assertEqual(ml[0]["roaster"], "Bad Co")
        self.assertAlmostEqual(ml[0]["mean_with"], 3.8)
        self.assertAlmostEqual(ml[0]["mean_without"], 6.5)
        self.assertFalse([f for f in flags if f["group"] == "roast" and f["value"] == "Dark"])

    def test_a_group_close_to_the_overall_mean_is_never_flagged(self):
        # Whole Bean averages 5.1 against an overall 5.3, so there is no
        # effect for anybody to carry, even though removing Bad Co would
        # swing the remainder to 7.0. Reporting that would be noise.
        wb = [f for f in self.result["confounds"] if f["group"] == "grind" and f["value"] == "Whole Bean"]
        self.assertEqual(wb, [])

    def test_top_and_bottom_lists(self):
        self.assertEqual([c["name"] for c in self.result["top"]], ["Alpha", "Bravo", "Charlie", "Golf", "Hotel"])
        self.assertEqual([c["name"] for c in self.result["bottom"]], ["Delta", "Echo", "Foxtrot", "Juliet", "India"])

    def test_roasters_split_into_liked_and_not(self):
        self.assertEqual(self.result["roasters"]["liked"], ["Good Co", "Mid Co"])
        self.assertEqual(self.result["roasters"]["all"], ["Bad Co", "Good Co", "Mid Co"])
        self.assertEqual(self.result["coffees_logged"][:2], ["Alpha", "Bravo"])


class TestPreviousRun(unittest.TestCase):
    def test_first_run_has_no_previous_and_second_run_reports_the_shift(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.csv"
            write_csv(p, HEADER, FIXTURE_ROWS[:10])
            first = analyze.run(p, state_dir=d)
            self.assertIsNone(first["previous"])
            write_csv(p, HEADER, FIXTURE_ROWS)
            second = analyze.run(p, state_dir=d)
            self.assertEqual(second["previous"]["n"], 10)
            self.assertEqual(second["n"], 11)
            self.assertEqual(second["new_coffees"], ["Kilo"])
            saved = json.loads((Path(d) / "last-run.json").read_text())
            self.assertEqual(saved["n"], 11)

    def test_a_corrupt_state_file_is_reported_not_treated_as_no_previous_run(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.csv"
            write_csv(p, HEADER, FIXTURE_ROWS)
            (Path(d) / "last-run.json").write_text("{not json")
            with self.assertRaises(analyze.StateUnreadable):
                analyze.run(p, state_dir=d)


class TestCli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SKILL / "analyze.py"), *args],
                              capture_output=True, text=True)

    def test_no_export_exits_nonzero_with_a_message_naming_the_folder(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as s:
            out = self.run_cli("--downloads", d, "--state", s)
        self.assertEqual(out.returncode, 2)
        self.assertIn("Coffee Tracker", out.stderr)
        self.assertIn(d, out.stderr)

    def test_json_output_round_trips(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as s:
            write_csv(Path(d) / "Coffee Tracker - Sheet1.csv", HEADER, FIXTURE_ROWS)
            out = self.run_cli("--downloads", d, "--state", s, "--json")
        self.assertEqual(out.returncode, 0, out.stderr)
        data = json.loads(out.stdout)
        self.assertEqual(data["n"], 11)
        self.assertIn("confounds", data)


class TestFirstExport(unittest.TestCase):
    def test_pins_the_numbers_the_first_profile_reported(self):
        """The 2026-09-14 profile said these; a change here changes that page's claims."""
        with tempfile.TemporaryDirectory() as s:
            r = analyze.run(FIRST_EXPORT, state_dir=s)
        self.assertEqual(r["n"], 34)
        self.assertAlmostEqual(r["correlations"]["Boldness"], 0.72, places=2)
        self.assertAlmostEqual(r["correlations"]["Aftertaste"], 0.72, places=2)
        self.assertAlmostEqual(r["mean_enjoy"], 5.29, places=2)
        self.assertEqual(r["buy"], {"yes": 11, "consider": 11, "no": 12})
        self.assertEqual(r["groups"]["process"]["blank"], 19)
        flagged = {(f["group"], f["value"], f["roaster"]) for f in r["confounds"]}
        self.assertEqual(flagged, {("roast", "Medium-Light", "Tandem Coffee Roasters"),
                                   ("process", "Fully Washed", "Tandem Coffee Roasters")})


if __name__ == "__main__":
    unittest.main()
