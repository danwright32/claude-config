"""Tests for nudge.py: link parsing, the lines file, the post, and every Slack failure."""

import os
import tempfile
import unittest

import nudge


LINK = "https://example.slack.com/archives/C0123ABCDEF/p1793208433546939"
REPLY_LINK = (
    "https://example.slack.com/archives/C0123ABCDEF/p1793208999000111"
    "?thread_ts=1793208433.546939&cid=C0123ABCDEF"
)


class FakeSlack:
    """Answers chat.postMessage, and records every call made."""

    def __init__(self, answer=None):
        self.calls = []
        self.answer = answer or {"ok": True, "channel": "C0123ABCDEF", "ts": "1793300000.000100"}

    def __call__(self, method, params):
        self.calls.append((method, params))
        return self.answer


class ParseLinkTest(unittest.TestCase):
    def test_top_level_message_link(self):
        self.assertEqual(nudge.parse_link(LINK), ("example", "C0123ABCDEF", "1793208433.546939"))

    def test_link_to_a_reply_targets_the_parent_thread(self):
        self.assertEqual(nudge.parse_link(REPLY_LINK), ("example", "C0123ABCDEF", "1793208433.546939"))

    def test_surrounding_whitespace_and_angle_brackets_are_ignored(self):
        self.assertEqual(nudge.parse_link("  <" + LINK + ">\n")[1:], ("C0123ABCDEF", "1793208433.546939"))

    def test_private_channel_ids_are_accepted(self):
        self.assertEqual(nudge.parse_link(LINK.replace("C0123ABCDEF", "G01ABCDEF"))[1], "G01ABCDEF")

    def test_links_that_are_not_slack_messages_are_refused_by_name(self):
        for bad in [
            "",
            "hello",
            "https://example.com/archives/C0123ABCDEF/p1793208433546939",
            "https://example.slack.com/archives/C0123ABCDEF",
            "https://example.slack.com/archives/C0123ABCDEF/p17932084",
            "https://example.slack.com/archives/C0123ABCDEF/p1793208433546939?thread_ts=garbage",
        ]:
            with self.subTest(bad=bad):
                with self.assertRaises(nudge.NudgeError) as caught:
                    nudge.parse_link(bad)
                self.assertIn("Slack message link", str(caught.exception))


class LinesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "lines.local.txt")

    def write(self, text):
        with open(self.path, "w") as f:
            f.write(text)

    def test_blank_lines_and_comments_are_skipped(self):
        self.write("one\n\n# a comment\n  two  \n")
        self.assertEqual(nudge.load_lines(self.path), ["one", "two"])

    def test_missing_lines_file_names_the_path(self):
        with self.assertRaises(nudge.NudgeError) as caught:
            nudge.load_lines(self.path)
        self.assertIn(self.path, str(caught.exception))

    def test_empty_lines_file_is_refused(self):
        self.write("\n# only a comment\n")
        with self.assertRaises(nudge.NudgeError):
            nudge.load_lines(self.path)


class PostTest(unittest.TestCase):
    def test_posts_the_line_in_the_thread_and_returns_a_link_to_it(self):
        slack = FakeSlack()
        link = nudge.post(LINK, "Psst. @some-team can't read minds (yet).", slack)
        self.assertEqual(
            link,
            "https://example.slack.com/archives/C0123ABCDEF/p1793300000000100"
            "?thread_ts=1793208433.546939&cid=C0123ABCDEF",
        )
        method, params = slack.calls[0]
        self.assertEqual(method, "chat.postMessage")
        self.assertEqual(params["channel"], "C0123ABCDEF")
        self.assertEqual(params["thread_ts"], "1793208433.546939")
        self.assertEqual(params["text"], "Psst. @some-team can't read minds (yet).")
        self.assertFalse(params["link_names"])
        self.assertFalse(params["unfurl_links"])
        self.assertEqual(len(slack.calls), 1)

    def test_a_reply_link_posts_in_the_parent_thread(self):
        slack = FakeSlack()
        nudge.post(REPLY_LINK, "hi", slack)
        self.assertEqual(slack.calls[0][1]["thread_ts"], "1793208433.546939")

    def test_slack_control_characters_are_escaped(self):
        slack = FakeSlack()
        nudge.post(LINK, "a < b & c > d", slack)
        self.assertEqual(slack.calls[0][1]["text"], "a &lt; b &amp; c &gt; d")

    def test_each_slack_failure_gets_its_own_message(self):
        cases = {
            "invalid_auth": "token",
            "token_revoked": "token",
            "not_in_channel": "/invite @Nudge Bot",
            "channel_not_found": "/invite @Nudge Bot",
            "thread_not_found": "deleted",
            "missing_scope": "permission",
            "ratelimited": "rate limit",
            "something_new": "something_new",
        }
        for code, expected in cases.items():
            with self.subTest(code=code):
                with self.assertRaises(nudge.NudgeError) as caught:
                    nudge.post(LINK, "hi", FakeSlack({"ok": False, "error": code}))
                self.assertIn(expected, str(caught.exception))


class MainTest(unittest.TestCase):
    def setUp(self):
        self.lines = os.path.join(tempfile.mkdtemp(), "lines.local.txt")
        with open(self.lines, "w") as f:
            f.write("only line\n")

    def test_success_prints_the_line_and_link_and_exits_zero(self):
        out = []
        self.assertEqual(nudge.main([LINK], FakeSlack(), self.lines, out.append), 0)
        self.assertIn("only line", out[0])
        self.assertIn("p1793300000000100", out[1])

    def test_failure_exits_nonzero_and_says_not_posted(self):
        out = []
        slack = FakeSlack({"ok": False, "error": "channel_not_found"})
        self.assertEqual(nudge.main([LINK], slack, self.lines, out.append), 1)
        self.assertTrue(out[-1].startswith("NOT POSTED"))

    def test_anything_but_one_link_is_a_usage_error(self):
        self.assertEqual(nudge.main([], FakeSlack(), self.lines, [].append), 2)
        self.assertEqual(nudge.main([LINK, LINK], FakeSlack(), self.lines, [].append), 2)


class TokenTest(unittest.TestCase):
    def test_missing_keychain_item_says_how_to_add_it(self):
        def fail(*_args, **_kwargs):
            raise nudge.subprocess.CalledProcessError(44, "security")

        with self.assertRaises(nudge.NudgeError) as caught:
            nudge.read_token(run=fail)
        self.assertIn(nudge.KEYCHAIN_SERVICE, str(caught.exception))

    def test_a_value_that_is_not_a_bot_token_is_refused_without_echoing_it(self):
        class Done:
            stdout = "PASTE_THE_BOT_USER_OAUTH_TOKEN_ON_THIS_LINE\n"

        with self.assertRaises(nudge.NudgeError) as caught:
            nudge.read_token(run=lambda *a, **k: Done())
        self.assertNotIn("PASTE", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
