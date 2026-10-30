#!/usr/bin/env python3
"""Reply in a Slack thread, as Nudge Bot, with a random friendly reminder from this Mac's own list.

    python3 nudge.py <slack message link>

The bot token lives in the login Keychain (service KEYCHAIN_SERVICE), never in a file. The lines
live in lines.local.txt beside this script, one per line; the sync keeps every *.local.* file on
this Mac, so the wording never reaches the shared repository. One Slack call, nothing recorded.

Exit: 0 posted, 1 not posted (the reason is printed), 2 usage.
"""

import json
import os
import random
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

LINES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lines.local.txt")
KEYCHAIN_SERVICE = "nudge-bot-slack"

LINK_RE = re.compile(r"^https://([a-z0-9-]+)\.slack\.com/archives/([A-Z0-9]+)/p(\d{10})(\d{6})(\?.*)?$")
TS_RE = re.compile(r"^\d{10}\.\d{6}$")

TOKEN_FIX = (
    "Nudge Bot's Slack token was refused ({code}). Copy the Bot User OAuth Token from the app's "
    "OAuth & Permissions page and store it again in the Keychain under " + KEYCHAIN_SERVICE + "."
)
CHANNEL_FIX = (
    "Nudge Bot can't post in that channel ({code}), which usually means it is private. Type "
    "/invite @Nudge Bot in the channel once, then run this again."
)
ERRORS = {
    "invalid_auth": TOKEN_FIX,
    "not_authed": TOKEN_FIX,
    "token_revoked": TOKEN_FIX,
    "account_inactive": TOKEN_FIX,
    "not_in_channel": CHANNEL_FIX,
    "channel_not_found": CHANNEL_FIX,
    "is_archived": "That channel is archived, so nothing can be posted in it ({code}).",
    "thread_not_found": "That message was not found ({code}). It may have been deleted, or the link is wrong.",
    "missing_scope": (
        "Nudge Bot is missing a Slack permission ({code}). Add it under OAuth & Permissions, "
        "reinstall the app, and store the new token."
    ),
    "ratelimited": "Slack's rate limit was hit ({code}). Wait a minute and try again.",
}


class NudgeError(Exception):
    pass


def parse_link(link):
    """(workspace, channel, thread ts) for a Slack message link; a reply's link names its thread."""
    text = link.strip().strip("<>")
    match = LINK_RE.match(text)
    if not match:
        raise NudgeError("That is not a Slack message link: " + repr(link))
    workspace, channel, secs, micros, query = match.groups()
    thread = secs + "." + micros
    if query:
        params = urllib.parse.parse_qs(query[1:])
        if "thread_ts" in params:
            thread = params["thread_ts"][0]
            if not TS_RE.match(thread):
                raise NudgeError("That is not a Slack message link (bad thread_ts): " + repr(link))
    return workspace, channel, thread


def load_lines(path):
    try:
        with open(path, errors="replace") as f:
            raw = f.read().splitlines()
    except FileNotFoundError:
        raise NudgeError("No lines file at " + path + ". Put one reminder per line in it.")
    lines = [l.strip() for l in raw if l.strip() and not l.strip().startswith("#")]
    if not lines:
        raise NudgeError("The lines file at " + path + " holds no lines.")
    return lines


def post(link, line, call):
    """Post `line` in the link's thread through `call(method, params)`; returns a link to the reply."""
    workspace, channel, thread = parse_link(link)
    text = line.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    answer = call("chat.postMessage", {
        "channel": channel,
        "thread_ts": thread,
        "text": text,
        "link_names": False,
        "unfurl_links": False,
        "unfurl_media": False,
    })
    if not answer.get("ok"):
        code = answer.get("error", "no error given")
        raise NudgeError(ERRORS.get(code, "Slack refused the post with {code}.").format(code=code))
    return "https://{}.slack.com/archives/{}/p{}?thread_ts={}&cid={}".format(
        workspace, answer["channel"], answer["ts"].replace(".", ""), thread, answer["channel"])


def read_token(run=subprocess.run):
    try:
        done = run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, check=True, errors="replace"
        )
    except subprocess.CalledProcessError:
        raise NudgeError("No Slack token in the Keychain under " + KEYCHAIN_SERVICE + ". Store the bot token there first.")
    token = done.stdout.strip()
    if not token.startswith("xoxb-"):
        raise NudgeError("The Keychain item " + KEYCHAIN_SERVICE + " does not hold a bot token (they start with xoxb-).")
    return token


def slack_caller(token):
    def call(method, params):
        req = urllib.request.Request(
            "https://slack.com/api/" + method, data=json.dumps(params).encode(),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json; charset=utf-8"},
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                return {"ok": False, "error": "ratelimited"}
            raise NudgeError("Slack answered " + method + " with HTTP " + str(e.code) + ".")
        except (urllib.error.URLError, TimeoutError) as e:
            raise NudgeError("Could not reach Slack: " + str(e))

    return call


def main(argv, call=None, lines_path=LINES_PATH, out=print):
    if len(argv) != 1:
        out("usage: nudge.py <slack message link>")
        return 2
    try:
        line = random.choice(load_lines(lines_path))
        if call is None:
            call = slack_caller(read_token())
        link = post(argv[0], line, call)
    except NudgeError as e:
        out("NOT POSTED: " + str(e))
        return 1
    out("POSTED: " + line)
    out(link)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
