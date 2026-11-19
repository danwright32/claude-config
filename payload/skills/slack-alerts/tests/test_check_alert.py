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
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
sys.path.insert(0, SKILL_DIR)
# The skill folder is carried to both Macs by the sync, so loading the checker leaves no bytecode
# folder behind in it (claude-config#2600).
sys.dont_write_bytecode = True

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
# The default mention on an urgent alert and its reminder (Dan, 2026-11-17: "@here").
HERE_MENTION = "<!here>"

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
        HERE_MENTION + " *6 times offered for 4:30 PM ET, Oct 14 have no free advisor*",
        DOT + "North team: none of its 12 advisors is free",
        DOT + "South team: nobody is on its rota",
        DOT + "East team: none of its 9 advisors is free",
        DOT + "West team: none of its 9 advisors is free",
        DOT + "Central team: none of its 9 advisors is free",
        "and 1 more",
        "<https://example.com/logs|Open slot logs>",
    ])),
    "a reminder": ("reminder", True, "\n".join([
        HERE_MENTION + " *Still open after 2 hours: 6 offered times have no free advisor*",
        "<https://example.com/logs|Open slot logs>",
    ])),
    "an urgent alert mentioning the person a project's CLAUDE.md names": ("alert", True, "\n".join([
        MENTION + " *3 of 40 invoices were not sent this morning*",
        "<https://example.com/invoices|View failed invoices>",
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
    # Several links, each to a different page the reader must visit (Dan, 18 Nov 2026, #3226).
    "an alert naming four bookings each linked to its own page": ("alert", False, "\n".join([
        "*4 bookings for Nov 21 have no advisor assigned*",
        DOT + "<https://example.com/bookings/1041|Booking 1041>, Ridgeway Dental",
        DOT + "<https://example.com/bookings/1042|Booking 1042>, Corner Bakery",
        DOT + "<https://example.com/bookings/1047|Booking 1047>, Elm Street Books",
        DOT + "<https://example.com/bookings/1050|Booking 1050>, Harbor Florist",
    ])),
    "an alert naming three people each linked to their own page": ("alert", False, "\n".join([
        "*3 advisors have no shifts set for next week*",
        DOT + "<https://example.com/people/12|Maya Ortiz>",
        DOT + "<https://example.com/people/31|Sam Whitfield>",
        DOT + "<https://example.com/people/47|Priya Nolan>",
    ])),
    "linked list lines and a closing link to a different page": ("alert", False, "\n".join([
        "*2 advisors have no shifts set for next week*",
        DOT + "<https://example.com/people/12|Maya Ortiz>",
        DOT + "<https://example.com/people/31|Sam Whitfield>",
        "<https://example.com/rota|Open rota>",
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
    # Two links once failed whatever they opened. Dan reversed that on 18 Nov 2026 (#3226): several
    # links are fine when each opens a different page, so two to the same page is what fails now.
    ("two links to the same page", "alert", False, (), alert(LEAD, "<https://example.com/runs/88/|Open run log>"), "link-repeat"),
    ("two links on one list line", "alert", False, (), alert(LEAD, DOT + "<https://example.com/p/1|Maya Ortiz> and <https://example.com/p/2|Sam Whitfield>"), "link-count"),
    ("a link in the first line beside a closing link", "alert", False, (), alert("*Pull request <https://example.com/pulls/641|641> has a check stuck on pending*"), "link-count"),
    ("a single link on a list line", "alert", False, (), alert(LEAD, DOT + "<https://example.com/p/1|Maya Ortiz>", link=None), "link-count"),
    ("a sentence after two closing links", "alert", False, (), "\n".join([LEAD, "<https://example.com/rota|Open rota>", LINK, "A CI re-run finished without reporting its result."]), "link-last"),
    ("a one word label on the first of two closing links", "alert", False, (), alert(LEAD, "<https://example.com/rota|rota>"), "link-label"),
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

    def test_the_urgent_mention_failure_names_here_as_the_default(self):
        # Dan, 2026-11-17, asked who an urgent alert mentions: "@here". The failure says so, so the
        # fix it prompts is the default rather than a hunt for one person.
        for kind in ("alert", "reminder"):
            text = alert(STILL.split(" ", 1)[1]) if kind == "reminder" else alert(LEAD)
            said = dict(check_alert.check(text, kind, urgent=True)).get("mention", "")
            self.assertIn(HERE_MENTION, said, kind)
            self.assertIn("CLAUDE.md", said, kind)

    def test_the_request_mention_failure_names_the_person_asked_not_here(self):
        # A request still goes to the person asked (Dan, 2026-11-17).
        text = alert("*Priya asks you to approve a refund of $240 on order 1038*")
        said = dict(check_alert.check(text, "request")).get("mention", "")
        self.assertIn("person asked", said)
        self.assertNotIn(HERE_MENTION, said)

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

    def with_record(self, record_text, extra, message):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "slack-alerts-record.txt")
            with open(path, "w", encoding="utf-8", errors="strict") as handle:
                handle.write(record_text)
            return run(["--kind", "alert", "--record", path] + extra, message)

    def test_takes_a_record_and_the_alert_a_message_is(self):
        keys = ["--alert-keys", ",".join(KEYS)]
        done = self.with_record(ALL_THREE, ["--alert", "time-off-note"] + keys, time_off("MT"))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        done = self.with_record(ALL_THREE, ["--alert", "nightly-export"] + keys, time_off("MT"))
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("time-format", done.stdout)

    def test_a_malformed_record_exits_2_naming_the_file_and_line(self):
        record = ALL_THREE + "\n2026-11-18 page-watch exempt bare-urls"
        done = self.with_record(record, ["--alert", "page-watch", "--alert-keys", ",".join(KEYS)], time_off("ET"))
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertIn("slack-alerts-record.txt", done.stderr)
        self.assertIn("line 6", done.stderr)
        self.assertNotIn("Traceback", done.stderr)

    def test_a_record_that_cannot_be_read_exits_2(self):
        done = run(["--kind", "alert", "--record", os.path.join(HERE, "no-such-record.txt"),
                    "--alert", "page-watch", "--alert-keys", "page-watch"], time_off("ET"))
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertIn("no-such-record.txt", done.stderr)
        self.assertNotIn("Traceback", done.stderr)

    def test_a_record_and_an_alert_go_together(self):
        keys = ["--alert-keys", ",".join(KEYS)]
        given = [
            self.with_record(ALL_THREE, keys, time_off("ET")),
            self.with_record(ALL_THREE, ["--alert", "page-watch"], time_off("ET")),
            run(["--kind", "alert", "--alert", "page-watch"] + keys, time_off("ET")),
            self.with_record(ALL_THREE, ["--alert", "not-posted"] + keys, time_off("ET")),
        ]
        for done in given:
            self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
            # Refused for the pairing, by name, never as an option the checker does not know.
            self.assertNotIn("unrecognized arguments", done.stderr)
            self.assertNotIn("Traceback", done.stderr)
        self.assertIn("not-posted", given[3].stderr)

    def test_a_byte_that_is_not_utf8_is_judged_and_quoted_back_not_raised(self):
        # A message can carry any byte. It is still judged on its rules, and the failure line that
        # quotes it back must print, from standard input and from a file alike.
        message = b"*Deploy \xff alert*\n<https://example.com/pulls/641|View pull request>\n"
        command = [sys.executable, "-I", os.path.join(SKILL_DIR, "check_alert.py"), "--kind", "alert"]
        piped = subprocess.run(command, input=message, capture_output=True)
        # Written here, not kept as a fixture, so the repository holds no file with such a byte.
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "message.txt")
            with open(path, "wb") as handle:
                handle.write(message)
            filed = subprocess.run(command + [path], capture_output=True)
        for done in (piped, filed):
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            self.assertIn(b"first-line-title", done.stdout)
            self.assertNotIn(b"Traceback", done.stderr)


# A project's record (claude-config#3226). Every key, date and message below is invented; no real
# project's record is held here, since each entry is the owner's to add with his own date.
KEYS = ("time-off-note", "queue-backlog", "page-watch", "nightly-export")
ALL_THREE = "\n".join([
    "# date      alert key       what it allows",
    "2026-11-18  time-off-note   own-zone",
    "",
    "2026-11-18  queue-backlog   labelled-id",
    "2026-11-18  page-watch      exempt bare-url",
])
UUID = "8d41c7e2-5b9a-4f03-b6de-2c7a91e4f5b3"
QUEUE_LEAD = "*2 queue rows were not picked up in an hour*"
PAGE_LEAD = "*The status page stopped answering at 3:05 PM ET*"


def time_off(zone_text):
    return alert("*Maya Ortiz is off on Nov 20*", f"She is away from 9:00 AM to 1:00 PM {zone_text}.")


def recorded(text=ALL_THREE, keys=KEYS):
    return check_alert.parse_record(text, keys)


def judged(text, alert_key, record_text=ALL_THREE, kind="alert"):
    return rules_failed_with(text, kind, recorded(record_text), alert_key)


def rules_failed_with(text, kind, record, alert_key):
    return [rule for rule, _ in check_alert.check(text, kind, record=record, alert=alert_key)]


# (what is wrong with the record, its text, words the error must carry)
BAD_RECORDS = [
    ("an allowance the checker does not know", "2026-11-18 time-off-note any-zone", "line 1"),
    ("an exemption naming a rule that does not exist", "2026-11-18 page-watch exempt bare-urls", "bare-urls"),
    ("an exemption naming no rule", "2026-11-18 page-watch exempt", "line 1"),
    ("an exemption from saying anything at all", "2026-11-18 page-watch exempt empty", "line 1"),
    ("a file that is not text", "2026-11-18 page-watch exempt bare-url\n" + chr(0) + "x", "line 2"),
    ("an exemption naming two rules", "2026-11-18 page-watch exempt bare-url link-count", "line 1"),
    ("a key the project does not post", "# a comment first\n2026-11-18 page-wacth exempt bare-url", "line 2"),
    ("an entry with no date", "page-watch exempt bare-url", "line 1"),
    ("a date that is not a day on the calendar", "2026-11-31 page-watch exempt bare-url", "2026-11-31"),
    ("a date written another way", "Nov 18 page-watch exempt bare-url", "line 1"),
    ("an own zone carrying a zone of its own", "2026-11-18 time-off-note own-zone MT", "line 1"),
    ("a labelled id carrying a word after it", "2026-11-18 queue-backlog labelled-id always", "line 1"),
    ("a date with nothing after it", "2026-11-18", "line 1"),
    ("a wildcard in place of a key", "2026-11-18 * exempt bare-url", "line 1"),
    ("the same entry twice", "2026-11-18 page-watch exempt bare-url\n2026-11-19 page-watch exempt bare-url", "line 2"),
]


class ProjectRecord(unittest.TestCase):
    """A project records, each with the owner's date, the alerts that take an own zone, a labelled
    id or an exemption from one rule (claude-config#3226). Each is accepted only in its narrow form,
    and only on the alert keys the record names."""

    def test_a_project_that_records_nothing_is_refused_exactly_as_before(self):
        # Every refusing case, judged with an empty record and a key, fails exactly as it does
        # with no record at all: nothing is allowed until the owner records it.
        empty = recorded("", ("any-alert",))
        for what, kind, urgent, apps, text, rule in BAD:
            with self.subTest(case=what):
                self.assertEqual(
                    check_alert.check(text, kind, urgent=urgent, apps=apps, record=empty, alert="any-alert"),
                    check_alert.check(text, kind, urgent=urgent, apps=apps),
                )

    def test_the_three_forms_are_refused_without_a_record(self):
        self.assertIn("time-format", rules_failed(time_off("MT"), "alert"))
        self.assertIn("raw-id", rules_failed(alert(QUEUE_LEAD, DOT + "Queue row: " + UUID), "alert"))
        self.assertIn("bare-url", rules_failed(alert(PAGE_LEAD, "https://status.example.com/health"), "alert"))

    def test_an_own_zone_passes_on_a_recorded_alert(self):
        for zone in check_alert.OWN_ZONES:
            with self.subTest(zone=zone):
                self.assertEqual(judged(time_off(zone), "time-off-note"), [])

    def test_the_own_zones_are_the_ones_the_owner_chose(self):
        # Issue #3226 and its comment, 18 Nov 2026: CT, MT, PT, AKT and HST, and AZ for Arizona.
        self.assertEqual(sorted(check_alert.OWN_ZONES), ["AKT", "AZ", "CT", "HST", "MT", "PT"])

    def test_et_still_passes_on_an_own_zone_alert(self):
        self.assertEqual(judged(time_off("ET"), "time-off-note"), [])

    def test_a_zone_the_list_does_not_hold_fails_on_an_own_zone_alert(self):
        for zone in ("CET", "AEST", "MST", "PDT", "UTC", "Mountain"):
            with self.subTest(zone=zone):
                self.assertIn("time-format", judged(time_off(zone), "time-off-note"))

    def test_an_own_zone_fails_on_an_alert_the_record_does_not_name_for_it(self):
        self.assertIn("time-format", judged(time_off("MT"), "nightly-export"))
        self.assertIn("time-format", judged(time_off("MT"), "queue-backlog"))

    def test_a_labelled_id_on_its_own_list_line_passes_on_a_recorded_alert(self):
        for label in ("Queue row", "Job", "Batch id"):
            with self.subTest(label=label):
                text = alert(QUEUE_LEAD, f"{DOT}{label}: {UUID}", "- Queue row: 0b7e4d11-2c3a-4e5f-8a9b-1c2d3e4f5a6b")
                self.assertEqual(judged(text, "queue-backlog"), [])

    def test_an_id_outside_that_narrow_form_fails_on_a_recorded_alert(self):
        shapes = {
            "an id with no label": alert(QUEUE_LEAD, DOT + UUID),
            "an id in a sentence": alert(QUEUE_LEAD, f"Row {UUID} was retried."),
            "an id in the first line": alert(f"*Row {UUID} was not picked up in an hour*"),
            "a labelled id with more words after it": alert(QUEUE_LEAD, f"{DOT}Queue row: {UUID}, retried twice"),
            "a label that is not a word": alert(QUEUE_LEAD, f"{DOT}#: {UUID}"),
            "a labelled id that is not a list line": alert(QUEUE_LEAD, f"Queue row: {UUID}"),
        }
        for what, text in shapes.items():
            with self.subTest(shape=what):
                self.assertIn("raw-id", judged(text, "queue-backlog"))

    def test_a_short_number_needs_no_record(self):
        # The skill says so: only a long id is refused, so "Queue row: 4817" passes as it is.
        self.assertEqual(check_alert.check(alert(QUEUE_LEAD, DOT + "Queue row: 4817"), "alert"), [])

    def test_a_labelled_id_fails_on_an_alert_the_record_does_not_name_for_it(self):
        text = alert(QUEUE_LEAD, DOT + "Queue row: " + UUID)
        self.assertIn("raw-id", judged(text, "page-watch"))

    def test_a_bare_address_passes_on_an_alert_exempted_from_that_rule(self):
        text = alert(PAGE_LEAD, "https://status.example.com/health")
        self.assertEqual(judged(text, "page-watch"), [])

    def test_a_bare_address_fails_on_an_alert_that_is_not_exempted(self):
        text = alert(PAGE_LEAD, "https://status.example.com/health")
        for key in ("nightly-export", "time-off-note", "queue-backlog"):
            with self.subTest(key=key):
                self.assertIn("bare-url", judged(text, key))

    def test_an_exemption_lifts_that_one_rule_and_no_other(self):
        # An unlabelled link inside a sentence breaks link-count as well as bare-url, and the
        # exemption from bare-url leaves link-count in force.
        text = alert(PAGE_LEAD, "It answers at <https://status.example.com/health>.")
        failed = judged(text, "page-watch")
        self.assertNotIn("bare-url", failed)
        self.assertIn("link-count", failed)

    def test_a_malformed_record_is_an_error_naming_the_line(self):
        for what, text, words in BAD_RECORDS:
            with self.subTest(record=what):
                with self.assertRaises(check_alert.RecordError) as raised:
                    recorded(text)
                self.assertIn(words, str(raised.exception))

    def test_a_malformed_record_never_allows_anything(self):
        # One bad line refuses the whole record, so a record half read never passes a message.
        text = ALL_THREE + "\n2026-11-18 page-watch exempt everything"
        with self.assertRaises(check_alert.RecordError):
            recorded(text)

    def test_a_record_with_only_comments_allows_nothing(self):
        record = recorded("# nothing recorded yet\n\n", KEYS)
        self.assertIn("time-format", rules_failed_with(time_off("MT"), "alert", record, "time-off-note"))

    def test_judging_with_a_record_needs_the_alert_it_is(self):
        with self.assertRaises(ValueError):
            check_alert.check(time_off("MT"), "alert", record=recorded())
        with self.assertRaises(ValueError):
            check_alert.check(time_off("MT"), "alert", alert="time-off-note")
        with self.assertRaises(ValueError):
            check_alert.check(time_off("MT"), "alert", record=recorded(), alert="not-a-posted-alert")

    def test_the_calls_an_older_project_makes_still_work(self):
        # A project's copy is refreshed byte for byte, so its existing calls must keep working.
        text = GOOD["a plain alert"][2]
        self.assertEqual(check_alert.check(text, "alert"), [])
        self.assertEqual(check_alert.check(text, "alert", False, ("Shop Admin",)), [])
        self.assertEqual(check_alert.check(text, "alert", urgent=False, apps=()), [])


OWNER_ON_LINKS = ("Multiple links are fine if they genuinely link to different pages and I have to go "
                  "to each of them to fix the problem.")


class SeveralLinks(unittest.TestCase):
    """Several links pass when each opens a different page (Dan, 18 Nov 2026, #3226). Whether each is
    a page the reader must act on is the writer's to judge: the checker sees only the targets."""

    def test_the_repeat_failure_names_the_target_after_trimming_a_slash_and_a_fragment(self):
        for second in ("https://example.com/runs/88/", "https://example.com/runs/88#logs", "https://example.com/runs/88/#logs"):
            with self.subTest(second=second):
                said = dict(check_alert.check(alert(LEAD, f"<{second}|Open run log>"), "alert")).get("link-repeat", "")
                self.assertIn("https://example.com/runs/88", said)

    def test_a_different_query_or_path_is_a_different_page(self):
        text = alert(LEAD, "<https://example.com/runs/88?attempt=2|Open second attempt>",
                     "<https://example.com/runs/89|View next run>")
        self.assertEqual(check_alert.check(text, "alert"), [])

    def test_a_bare_address_still_fails_beside_several_links(self):
        text = "\n".join([GOOD["an alert naming three people each linked to their own page"][2],
                          DOT + "https://example.com/people/52"])
        self.assertIn("bare-url", rules_failed(text, "alert"))

    def test_the_owners_words_sit_beside_the_rule_in_the_checker(self):
        with open(os.path.join(SKILL_DIR, "check_alert.py"), encoding="utf-8", errors="strict") as handle:
            source = " ".join(line.strip().lstrip("#").strip() for line in handle)
        self.assertTrue(OWNER_ON_LINKS in source, "the checker does not quote the owner's words")
        self.assertTrue("18 Nov 2026" in source)

    def test_the_checker_says_it_checks_only_that_the_targets_differ(self):
        self.assertIn("only that their targets differ", " ".join(check_alert.__doc__.split()))


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

    def test_its_urgent_examples_open_with_here_and_its_request_with_the_person_asked(self):
        # The examples teach the rule (L562): an urgent alert and its reminder show the default,
        # <!here>, and a request shows a mention of one person.
        examples = skill_examples(self.skill)
        urgent = [text for heading, text in examples if heading.startswith("Urgent") or "`reminder`" in heading]
        requests = [text for heading, text in examples if "`request`" in heading]
        self.assertGreaterEqual(len(urgent), 2)
        self.assertEqual([text.split("\n")[0] for text in urgent if not text.startswith(HERE_MENTION + " ")], [])
        self.assertEqual(len(requests), 1)
        self.assertRegex(requests[0], r"^<@U[A-Z0-9]+> ")

    def test_it_says_an_alert_rewrite_merges_on_its_checks_without_coming_back_to_dan(self):
        # Dan, 2026-11-17: a rewrite of a repo's existing alerts needs no approval from him.
        # Read with its line breaks folded, so rewrapping the paragraph does not fail it, and with
        # assertTrue, not assertIn, so a failure does not print the whole skill (L445).
        flat = " ".join(self.skill.split())
        for words in ("merges when its checks and the lessons review pass", "without me"):
            self.assertTrue(words in flat, f'the skill does not say "{words}"')

    def test_it_quotes_the_owner_on_several_links_and_leaves_the_judgement_to_the_writer(self):
        flat = " ".join(self.skill.split())
        for words in (OWNER_ON_LINKS, "18 Nov 2026", "only that their targets differ"):
            self.assertTrue(words in flat, f'the skill does not say "{words}"')
        self.assertFalse("one link straight to" in flat, "the skill still says one link")

    def test_it_says_how_a_project_records_each_allowance(self):
        # The record is the one place a project names them, so the skill must teach its form.
        flat = " ".join(self.skill.split())
        for words in ("--record", "--alert", "--alert-keys", "own-zone", "labelled-id", "exempt",
                      ", ".join(check_alert.OWN_ZONES)):
            self.assertTrue(words in flat, f'the skill does not say "{words}"')

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
