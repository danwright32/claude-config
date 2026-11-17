"""Tests for check_alert.py, the checker beside the slack-alerts skill (claude-config#3159).

Run by hooks/lib/skill-python-tests.py with every other skill's tests, so nothing registers them.
Every rule the checker names is driven to fail here at least once (L1), and a rule that no case
below fails is itself a failure, so a rule added later cannot ship unseen. The passing cases are
the shapes the standard describes, one per kind of post. The skill's own examples are run through
the checker too, because a rule is copied through its worked example (L562). Nothing here reaches
Slack.
"""
import os
import re
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, SKILL_DIR)

import check_alert  # noqa: E402

# Characters the style rules ban from source are built by code point, so this file holds none.
ARROW = chr(0x2192)
LONG_DASH = chr(0x2014)
SHORT_DASH = chr(0x2013)
SIREN = chr(0x1F6A8)
DOT = chr(0x2022) + " "
FENCE = "```"
LINK = "<https://example.com/runs/88|View run>"
MENTION = "<@U012ABCDEF>"

# name: (kind, urgent, the message)
GOOD = {
    "a plain alert": ("alert", False, "\n".join([
        "*Pull request 641 has a check stuck on pending*",
        "A CI re-run finished without reporting its result.",
        "<https://example.com/pulls/641|View pull request>",
    ])),
    "an alert with a list and an error block": ("alert", False, "\n".join([
        "*1 of 3 accounts was not created*",
        DOT + "priya.nolan@example.com",
        FENCE + 'HTTP 503 {"error":{"code":503,"message":"The service is currently unavailable."}}' + FENCE,
        "<https://example.com/onboarding/88|Open onboarding>",
    ])),
    "an alert whose error block sits on its own lines": ("alert", False, "\n".join([
        "*The sales report was not updated for October and November*",
        FENCE,
        "HTTP 503 Service Unavailable",
        FENCE,
        LINK,
    ])),
    "an urgent alert with a full list and an overflow line": ("alert", True, "\n".join([
        MENTION + " *6 times offered for 4:30 PM ET, Oct 14 have no free advisor*",
        DOT + "North team: none of its 12 advisors is free",
        DOT + "South team: nobody is on its rota",
        DOT + "East team: none of its 9 advisors is free",
        DOT + "West team: none of its 9 advisors is free",
        DOT + "Central team: none of its 9 advisors is free",
        "and 1 more",
        "<https://example.com/logs|Open slot logs>",
    ])),
    "a reminder": ("reminder", True, "\n".join([
        MENTION + " *Still open after 2 hours: 6 offered times have no free advisor*",
        "<https://example.com/logs|Open slot logs>",
    ])),
    "a recovery with no link": ("recovery", False, "*Recovered: every offered time has a free advisor*"),
    "a recovery with a time range": ("recovery", False, "\n".join([
        "*Recovered: the import workflow is back to normal speed*",
        "It ran slow from 9:45 AM to 10:16 AM ET.",
        "<https://example.com/workflows/7|Open workflow>",
    ])),
    "a digest": ("digest", False, "\n".join([
        "*3 imports were skipped last week, 1 of them for a missing column*",
        DOT + 'Orders, 2:46 PM ET, Nov 13: no column named "total"',
        DOT + "Customers, 10:12 AM ET, Nov 14: the file was empty",
        DOT + "Refunds, 4:03 PM ET, Nov 12: the file was empty",
        "<https://example.com/imports|Open import log>",
    ])),
    "a request to a person": ("request", False, "\n".join([
        MENTION + " *Priya asks you to approve a refund of $240 on order 1038*",
        '"The parcel arrived damaged." It is over the $200 she can approve herself.',
        "<https://example.com/refunds/77|Open refund>",
    ])),
    "a time given with its date": ("alert", False, "\n".join([
        "*The nightly export last ran at 3:05 PM ET, Nov 14*",
        LINK,
    ])),
}


def alert(*lines, link=LINK):
    return "\n".join(list(lines) + ([link] if link else []))


LEAD = "*Pull request 641 has a check stuck on pending*"
STILL = MENTION + " *Still open after 2 hours: 6 offered times have no free advisor*"
TOO_LONG = "A CI re-run finished without reporting its result and " + "the pull request behind it now shows a pending check " * 3 + "today."

# (what is wrong, kind, urgent, apps, the message, the rule that must fail)
BAD = [
    ("a first line that is not bold", "alert", False, (), alert("Pull request 641 has a check stuck on pending"), "first-line-bold"),
    ("a generic title as the first line", "alert", False, (), alert("*Deploy alert*", "A CI re-run finished without reporting its result."), "first-line-title"),
    ("a three word title", "alert", False, (), alert("*Workflow Execution Failed*"), "first-line-title"),
    ("the app's name opening the message", "alert", False, ("Harbor",), alert("*Harbor deploy failed on main today*"), "app-name"),
    ("an emoji character", "alert", False, (), alert(SIREN + " " + LEAD), "emoji"),
    ("an emoji shortcode", "alert", False, (), alert(":rotating_light: " + LEAD), "emoji"),
    ("wording over 200 characters", "alert", False, (), alert(LEAD, TOO_LONG), "wording-length"),
    ("two sentences under the first line", "alert", False, (), alert(LEAD, "A CI re-run finished without reporting its result. The run was started by hand."), "sentences"),
    ("a sentence under a reminder", "reminder", True, (), alert(STILL, "The same four advisors are affected."), "sentences"),
    ("an error block over 500 characters", "alert", False, (), alert(LEAD, FENCE + "x" * 501 + FENCE), "error-block"),
    ("two error blocks", "alert", False, (), alert(LEAD, FENCE + "HTTP 503" + FENCE, FENCE + "HTTP 500" + FENCE), "error-block"),
    ("an alert with no link", "alert", False, (), alert(LEAD, link=None), "link-missing"),
    ("a link that is not the last line", "alert", False, (), "\n".join([LEAD, LINK, "A CI re-run finished without reporting its result."]), "link-last"),
    ("two links", "alert", False, (), alert(LEAD, "<https://example.com/a|Open runbook>"), "link-count"),
    ("a link inside a sentence", "alert", False, (), alert(LEAD, "Start with the <https://example.com/a|runbook section>."), "link-count"),
    ("an arrow in the link label", "alert", False, (), alert(LEAD, link=f"<https://example.com/x|View execution {ARROW}>"), "link-label"),
    ("a one word link label", "alert", False, (), alert(LEAD, link="<https://example.com/x|open>"), "link-label"),
    ("a bare address", "alert", False, (), alert(LEAD, "https://example.com/actions/runs/19234567890"), "bare-url"),
    ("a month written as digits", "alert", False, (), alert("*The sales report was not updated for 2026-10 and 2026-11*"), "time-format"),
    ("a UTC timestamp", "alert", False, (), alert(LEAD, "The last run recorded was 2026-11-12T12:04:00Z."), "time-format"),
    ("seconds and a named zone", "alert", False, (), alert(LEAD, "It failed at 9:42:07 AM EST."), "time-format"),
    ("a lower case am or pm", "alert", False, (), alert(LEAD, "It failed at 4:30pm ET."), "time-format"),
    ("a 24 hour time", "alert", False, (), alert(LEAD, "It failed at 16:10 today."), "time-format"),
    ("a time with no zone", "alert", False, (), alert(LEAD, "It failed at 4:30 PM today."), "time-format"),
    ("a year beside a date", "alert", False, (), alert(LEAD, "It failed at 4:30 PM ET, Nov 17, 2026."), "time-format"),
    ("a mention on an internal alert", "alert", False, (), alert(MENTION + " " + LEAD), "mention"),
    ("an urgent alert with no mention", "alert", True, (), alert(LEAD), "mention"),
    ("a request that mentions nobody", "request", False, (), alert("*Priya asks you to approve a refund of $240 on order 1038*"), "mention"),
    ("a list of six", "alert", False, (), alert(LEAD, *[f"{DOT}Team {n}: nobody is free" for n in range(6)]), "list-length"),
    ("labelled lines in place of a sentence", "alert", False, (), alert(LEAD, "*Advisors affected:* Maya Ortiz, Sam Whitfield", "*What leads see:* times that may already be taken"), "labelled-lines"),
    ("a closing line that says nothing is needed", "recovery", False, (), "*Recovered: every offered time has a free advisor*\nNo action is needed.", "filler"),
    ("a line saying there is nothing to do yet", "alert", True, (), alert(MENTION + " " + LEAD, "Nothing to do yet."), "filler"),
    ("a sentence about how the check works", "alert", False, (), alert(LEAD, "This check fires after 3 failed runs in a row."), "filler"),
    ("a sentence about when it will post again", "alert", False, (), alert(LEAD, "It posts again at 11:26 AM ET if it is still failing."), "filler"),
    ("a machine plural", "alert", False, (), alert("*2 user(s) could not be created today*"), "machine-plural"),
    ("capitals for emphasis", "alert", False, (), alert(LEAD, "The main branch is NOT live."), "capitals"),
    ("an issue number", "alert", False, (), alert(LEAD, "It is the same fault as #628."), "issue-ref"),
    ("a long dash", "alert", False, (), alert(LEAD, f"A CI re-run finished {LONG_DASH} with no result."), "dash"),
    ("a spaced hyphen", "alert", False, (), alert(LEAD, "A CI re-run finished - with no result."), "dash"),
    ("a bare id", "alert", False, (), alert("*Order 8d41c7e2-5b9a-4f03-b6de-2c7a91e4f5b3 was skipped at step 8*"), "raw-id"),
    ("a recovery that does not open with Recovered", "recovery", False, (), "*Every offered time has a free advisor again*", "recovery-opening"),
    ("a recovery header with nothing after it", "recovery", False, (), "*Recovered*", "recovery-opening"),
    ("a reminder that does not open with Still open after", "reminder", True, (), alert(MENTION + " *6 offered times have no free advisor*"), "reminder-opening"),
    ("an empty message", "alert", False, (), "  \n", "empty"),
]


def rules_failed(text, kind, urgent=False, apps=()):
    return [rule for rule, _ in check_alert.check(text, kind, urgent=urgent, apps=apps)]


def method_name(prefix, words):
    return prefix + re.sub(r"[^a-z0-9]+", "_", words.lower()).strip("_")


class GoodMessages(unittest.TestCase):
    """The shapes the standard describes pass with no failure at all."""


class BadMessages(unittest.TestCase):
    """Each message breaks one rule, and the checker names that rule."""


def _good(kind, urgent, text):
    def test(self):
        self.assertEqual(check_alert.check(text, kind, urgent=urgent), [])
    return test


def _bad(kind, urgent, apps, text, rule):
    def test(self):
        self.assertIn(rule, rules_failed(text, kind, urgent, apps))
    return test


for _name, (_kind, _urgent, _text) in GOOD.items():
    setattr(GoodMessages, method_name("test_passes_", _name), _good(_kind, _urgent, _text))
for _what, _kind, _urgent, _apps, _text, _rule in BAD:
    setattr(BadMessages, method_name(f"test_fails_{_rule.replace('-', '_')}_on_", _what), _bad(_kind, _urgent, _apps, _text, _rule))


class Coverage(unittest.TestCase):
    def test_no_two_cases_share_a_method_name(self):
        good = [name for name in vars(GoodMessages) if name.startswith("test_")]
        bad = [name for name in vars(BadMessages) if name.startswith("test_")]
        self.assertEqual(len(good), len(GOOD))
        self.assertEqual(len(bad), len(BAD))

    def test_every_rule_the_checker_names_has_a_case_that_fails_it(self):
        seen = {rule for _, kind, urgent, apps, text, rule in BAD if rule in rules_failed(text, kind, urgent, apps)}
        self.assertEqual(sorted(set(check_alert.RULES) - seen), [])

    def test_every_rule_a_case_names_is_one_the_checker_declares(self):
        self.assertEqual(sorted({rule for *_, rule in BAD} - set(check_alert.RULES)), [])

    def test_nothing_inside_the_error_block_is_judged_as_wording(self):
        # That text is the other system's own, so no wording rule reads it.
        inside = alert(LEAD, FENCE + f"2026-11-12T12:04:00Z NOT FOUND {LONG_DASH} see #628 8d41c7e2-5b9a-4f03-b6de-2c7a91e4f5b3 https://example.com/x user(s)" + FENCE)
        self.assertEqual(check_alert.check(inside, "alert"), [])

    def test_the_length_failure_states_the_measured_length_and_the_limit(self):
        # A refusal can then be acted on without rereading the standard.
        said = dict(check_alert.check(alert(LEAD, TOO_LONG), "alert")).get("wording-length", "")
        self.assertIn("200", said)
        self.assertTrue(any(ch.isdigit() for ch in said.replace("200", "")), said)

    def test_an_unknown_kind_is_refused_by_the_function_too(self):
        with self.assertRaises(ValueError):
            check_alert.check(LEAD, "banner")


def run(args, text):
    return subprocess.run([sys.executable, "-I", os.path.join(SKILL_DIR, "check_alert.py")] + args, input=text, capture_output=True, text=True)


class CommandLine(unittest.TestCase):
    def test_exits_0_and_reports_the_wording_used_on_a_pass(self):
        done = run(["--kind", "alert"], GOOD["a plain alert"][2])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("of 200", done.stdout)

    def test_exits_1_and_names_the_rule_on_a_failure(self):
        done = run(["--kind", "alert"], alert("*Deploy alert*"))
        self.assertEqual(done.returncode, 1)
        self.assertIn("first-line-title", done.stdout)

    def test_exits_2_when_no_kind_is_given(self):
        self.assertEqual(run([], GOOD["a plain alert"][2]).returncode, 2)

    def test_exits_2_on_a_kind_the_standard_does_not_have(self):
        self.assertEqual(run(["--kind", "banner"], GOOD["a plain alert"][2]).returncode, 2)

    def test_an_empty_message_exits_1_never_0(self):
        self.assertEqual(run(["--kind", "alert"], "   \n").returncode, 1)

    def test_takes_the_app_name_and_fails_a_message_that_opens_with_it(self):
        done = run(["--kind", "alert", "--app", "Harbor"], alert("*Harbor deploy failed on main today*"))
        self.assertEqual(done.returncode, 1)
        self.assertIn("app-name", done.stdout)

    def test_takes_the_urgent_flag(self):
        done = run(["--kind", "reminder", "--urgent"], GOOD["a reminder"][2])
        self.assertEqual(done.returncode, 0, done.stdout)

    def test_reads_the_message_from_a_file(self):
        path = os.path.join(HERE, "fixture-plain-alert.txt")
        done = run(["--kind", "alert", path], "")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_a_file_that_cannot_be_read_exits_2_and_says_so(self):
        # Exit 1 means the message broke a rule, so a file that is not there must not share it.
        done = run(["--kind", "alert", os.path.join(HERE, "no-such-message.txt")], "")
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertIn("no-such-message.txt", done.stderr)
        self.assertNotIn("Traceback", done.stderr)


def skill_text():
    path = os.path.join(SKILL_DIR, "SKILL.md")
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def skill_examples(skill):
    """(the line that introduces it, the example) for each indented block under Examples."""
    found = []
    section = skill.split("\n## Examples\n")[1].split("\n## ")[0] if "\n## Examples\n" in skill else ""
    heading, block = "", []
    for line in section.split("\n") + ["end:"]:
        if line.startswith("    "):
            block.append(line[4:])
        elif line.strip():
            if block:
                found.append((heading, "\n".join(block)))
            heading, block = line, []
    return found


class TheSkill(unittest.TestCase):
    """The skill is found by the words a session would use, and agrees with the checker it ships."""

    def setUp(self):
        self.skill = skill_text()
        self.front = self.skill.split("---")[1] if self.skill.startswith("---") else ""

    def test_its_name_and_description_are_the_ones_a_session_finds_it_by(self):
        self.assertIn("\nname: slack-alerts\n", self.front)
        self.assertIn("\ndescription: Use when", self.front)
        self.assertTrue(0 < len(self.front) <= 1024, f"{len(self.front)} characters of frontmatter")

    def test_it_tells_the_session_to_run_the_checker(self):
        self.assertIn("check_alert.py", self.skill)

    def test_it_describes_every_kind_the_checker_takes(self):
        self.assertEqual([kind for kind in check_alert.KINDS if f"`{kind}`" not in self.skill], [])

    def test_it_states_the_limits_the_checker_enforces(self):
        self.assertIn(f"{check_alert.WORDING_LIMIT} characters", self.skill)
        self.assertIn(f"{check_alert.ERROR_LIMIT} characters", self.skill)
        self.assertIn(f"{check_alert.LIST_LIMIT} lines", self.skill)

    def test_it_holds_no_long_dash(self):
        self.assertNotIn(SHORT_DASH, self.skill)
        self.assertNotIn(LONG_DASH, self.skill)

    def test_it_shows_an_example_of_every_kind(self):
        headings = [heading for heading, _ in skill_examples(self.skill)]
        self.assertEqual([kind for kind in check_alert.KINDS if not any(f"`{kind}`" in h for h in headings)], [])

    def test_every_example_it_shows_passes_the_checker(self):
        examples = skill_examples(self.skill)
        self.assertGreaterEqual(len(examples), len(check_alert.KINDS))
        for heading, text in examples:
            with self.subTest(example=heading):
                kind = next((k for k in check_alert.KINDS if f"`{k}`" in heading), None)
                self.assertIsNotNone(kind, "the line above the example names no kind")
                urgent = heading.startswith("Urgent") or kind == "reminder"
                self.assertEqual(check_alert.check(text, kind, urgent=urgent, apps=("Shop Admin",)), [])


if __name__ == "__main__":
    unittest.main()
