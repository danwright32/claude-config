#!/usr/bin/env bash
#
# check-trusted-paths.sh: say when a path the auto mode classifier is told to trust is not on this
# Mac (claude-config#2491).
#
# autoMode.environment in each Mac's settings.json is a list of free text entries the auto mode
# classifier reads as its picture of the environment, and some of them name a trusted checkout by
# absolute path. Nothing checked those paths. On the work MacBook one pointed at a folder that had
# been gone for two weeks after a project move, so the classifier was told to trust a checkout that
# no longer existed while the real one went unrecognised. It is the same fault check-project-list.sh
# catches in the Projects list (a path recording where something happened to be, L153), in a file
# that check never read, so it is checked the same way: one stat per path.
#
# The sync carries neither autoMode list (README "auto mode"), so each Mac's copy is its own and is
# corrected on that Mac. That is also why this reads only the file and never writes it, and why it
# prints a path only to the session: on the work MacBook those paths name work repositories, and
# nothing here may put them in a file.
#
# An entry is free text, so only what looks like an absolute path is taken from it: a span starting
# with / or ~/ at the start of the entry, after a space, a ( or an =, or inside backticks or quotes.
# A backticked or quoted span is taken whole, spaces included. Anywhere else a path is read up to a
# space, and then again with each further word on the line (up to a backtick, quote or bracket), so a
# bare folder name holding a space is found whole: the path counts as present when any of those
# readings exists, and the shortest is named when none does (#2549). Trailing punctuation (a full
# stop, a comma) is dropped from each reading. A URL is never read as one, because
# its slashes follow a colon, and a word like read/write is not, because its slash follows a letter.
# A glob is cut back to the directory before its first wildcard. ~ is expanded against HOME.
#
# Run:  bash ~/.claude/hooks/check-trusted-paths.sh
#
# Exit 0 = every path found is there, or there is nothing to check: no settings file, no autoMode
#          block, or no path in any entry. Silent, because each of those is a normal state on a Mac
#          that has not set auto mode up.
# Exit 1 = at least one path is not on this Mac. One line per path, naming it, the line of the
#          settings file holding the entry, and the entry.
# Exit 2 = the settings file is there and is not valid JSON, so nothing in it could be checked. One
#          line, said rather than passed over, because reading nothing and finding nothing wrong
#          are indistinguishable otherwise (L98).
# Exit 3 = python3 is not on PATH, so the file could not be read at all. Its own code, because its
#          remedy is nobody else's (L11).
#
# Environment:
#   TRUSTED_PATHS_SETTINGS_FILE  read this file instead of the settings.json in CLAUDE_HOME
#                                (default ~/.claude)

set -uo pipefail

SETTINGS="${TRUSTED_PATHS_SETTINGS_FILE:-${CLAUDE_HOME:-$HOME/.claude}/settings.json}"

# No settings file is a Mac that has not set auto mode up, not a fault.
[ -f "$SETTINGS" ] || exit 0

if ! command -v python3 > /dev/null 2>&1; then
  echo "check-trusted-paths: python3 is not on PATH, so the auto mode trusted paths in $SETTINGS could not be read or checked."
  exit 3
fi

python3 - "$SETTINGS" <<'PY'
import json, os, re, sys

# A JSON string can spell a lone surrogate, which no encoder writes; replaced, the finding is still
# printed rather than lost to a traceback.
sys.stdout.reconfigure(errors="replace")

path = sys.argv[1]
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
except OSError as exc:
    print(f"check-trusted-paths: {path} could not be read ({exc.strerror}), so its auto mode trusted paths were not checked.")
    sys.exit(2)
try:
    data = json.loads(raw)
except ValueError as exc:
    where = f" at line {exc.lineno}" if hasattr(exc, "lineno") else ""
    print(f"check-trusted-paths: {path} is not valid JSON{where}, so its auto mode trusted paths were not checked.")
    sys.exit(2)

auto = data.get("autoMode") if isinstance(data, dict) else None
entries = auto.get("environment") if isinstance(auto, dict) else None
if isinstance(entries, str):
    entries = [entries]
if not isinstance(entries, list):
    sys.exit(0)

# A delimited span first, taken whole so a path with a space in it is not cut short; then a bare
# span, whose first reading ends at whitespace (MORE below adds the longer ones). Either must start
# with / or ~/ and must not start with //.
DELIMITED = re.compile(r"""[`"']((?:~/|/(?!/))[^`"'\n]+)[`"']""")
BARE = re.compile(r"""(?:^|(?<=[\s(=]))((?:~/|/(?!/))[^\s`"'()]+)""")
# A bare span can be the start of a path whose folder name holds a space: the Trusted repos entry
# lists checkouts bare, as <path> (<remote url>), so "Apps/Two Words" is read as "Apps/Two"
# (claude-config#2549). Each further word on the same line, up to a backtick, quote or bracket, gives
# one longer READING of the same path. Whitespace is kept exactly as written.
MORE = re.compile(r"""[ \t]+[^\s`"'()]+""")
TRAILING = ".,;:!?)]}"
GLOB = re.compile(r"[*?\[]")

def clean(p):
    p = p.rstrip()
    while p and p[-1] in TRAILING:
        p = p[:-1]
    g = GLOB.search(p)
    if g:
        p = p[: p.rfind("/", 0, g.start()) + 1]
    return p

def paths_in(text):
    # Each path found is a list of its readings, shortest first. A delimited span has one reading;
    # a bare one has one per word that could still belong to it.
    found = []
    spans = []
    for m in DELIMITED.finditer(text):
        found.append([m.group(1)])
        spans.append(m.span())
    for m in BARE.finditer(text):
        if any(a <= m.start(1) < b for a, b in spans):
            continue
        readings = [m.group(1)]
        end = m.end(1)
        while True:
            more = MORE.match(text, end)
            if not more:
                break
            end = more.end()
            readings.append(text[m.start(1):end])
        found.append(readings)
    out = []
    seen = set()
    for readings in found:
        rs = []
        for r in readings:
            r = clean(r)
            if r not in ("", "/", "~/") and r not in rs:
                rs.append(r)
        # Keyed on every reading, not the shortest, so "Apps/Two Words" and "Apps/Two Other" in one
        # entry stay two paths and one being present cannot answer for the other.
        if not rs or tuple(rs) in seen:
            continue
        seen.add(tuple(rs))
        out.append(rs)
    return out

def line_of(entry, token):
    # The line of the settings file holding this entry, searched from the autoMode key on so a
    # path mentioned earlier in the file (a permission rule) does not answer for it.
    start = raw.find('"autoMode"')
    start = 0 if start < 0 else start
    for needle in (json.dumps(entry, ensure_ascii=False)[1:-1], json.dumps(entry)[1:-1], token):
        i = raw.find(needle, start)
        if i >= 0:
            return raw.count("\n", 0, i) + 1
    return None

def excerpt(entry, limit=100):
    entry = " ".join(entry.split())
    return entry if len(entry) <= limit else entry[: limit - 3] + "..."

home = os.environ.get("HOME", "")
missing = []
for entry in entries:
    if not isinstance(entry, str):
        continue
    for readings in paths_in(entry):
        # Present when ANY reading exists: the longer ones are how a folder name with a space in it
        # is read whole. A reading exists only if that path is on disk, so gluing a gone path to the
        # words after it makes nothing present that is not there. When none exists, the shortest
        # is named, the span the text plainly marks as a path.
        if any(os.path.exists(home + r[1:] if r.startswith("~/") else r) for r in readings):
            continue
        token = readings[0]
        # The same gone path written twice in one entry, with different words after each, is one
        # finding, not two lines naming the same path.
        if any(t == token and e is entry for t, _, e in missing):
            continue
        missing.append((token, line_of(entry, token), entry))

if not missing:
    sys.exit(0)

name = os.path.basename(path)
for token, line, entry in missing:
    where = f"{name} line {line}" if line else name
    print(f"check-trusted-paths: auto mode is told to trust `{token}`, which is not on this Mac ({where}, entry: {excerpt(entry)}). "
          f"The classifier trusts a checkout that is gone and does not recognise where it moved to; correct the path in that entry of {path} on this Mac, since the sync does not carry it.")
sys.exit(1)
PY
