#!/usr/bin/env bash
#
# style-sweep.sh: report the em dashes, en dashes and emoji already sitting in the payload.
#
# check-style-guide.sh blocks a push that INTRODUCES one, which is the right shape for a gate and
# means text that never changes is never inspected. The session reflection instruction carried 17
# em dashes while itself telling Claude never to use dashes as punctuation, and it survived because
# it lived untouched inside a hook. It was caught in August 2026 only because moving it into its own
# file made every line new and the gate then refused the push (claude-config#247, L223).
#
# A rule contradicted by the prose around it loses to the demonstration (L270), and every file here
# is loaded into a session as instruction, so this is the backlog the push gate was never going to
# see. It REPORTS. It is not a gate, and the push gate is correct as it stands.
#
# Usage:
#   tools/style-sweep.sh [<dir>]      default: the payload of the repo this script is in
#
# Exit codes:
#   0  nothing to report
#   1  violations found (they are listed)
#   2  it could not read what it was asked to read, so it reports nothing rather than "clean"
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$HERE" && git rev-parse --show-toplevel 2>/dev/null || true)/payload"
fi
[ -d "$ROOT" ] || { echo "style-sweep: no such directory: $ROOT" >&2; exit 2; }

exec python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]

# Written as escapes, never as the characters themselves. The push gate cannot tell a line that
# BANS one from a line that uses one, and it is right not to try: it refused this very file
# until the regex was written this way.
DASH = re.compile("[\\u2014\\u2013]")
# COPIED from check-style-guide.sh, character for character. A sweep that used its own idea of an
# emoji would report a backlog the gate does not refuse and, worse, would go quiet on one it does:
# the first version here added the arrow block and reported 60 legitimate "input -> output" lines as
# violations, which is a report nobody can act on (L11, L36).
EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "\u2934\u2935\u2b05-\u2b07\u2b1b\u2b1c\u2b50\u2b55]"
)

# What this deliberately does NOT report, each with the reason it is exempt. An entry carrying no
# reason beside neighbours that each carry one is evidence it was never reasoned about (L233).
def why_skipped(path, rel):
    if "/.git/" in path:
        return "not payload"
    base = os.path.basename(path)
    if base in ("check-style-guide.sh", "test-check-style-guide.sh"):
        # They have to NAME the characters in order to refuse them. That is the gate working, not
        # a violation of it.
        return "it is the gate that refuses these characters, so it has to name them"
    if base == "no-ai-tells-detect.py" or rel.startswith("skills/no-ai-tells/"):
        return "it detects these characters, so it has to name them"
    if rel.startswith("skills/reel-plan/"):
        # The star is a decision the skill states outright: "it is the ONLY symbol allowed", marking
        # the one shot to get before any other. It is on a card read on a phone at a venue in the
        # dark, where a mark on the line is the whole point. The rule bans emoji unless Dan asks for
        # them, and this is him asking (L233: an exclusion with no reason beside it reads as one
        # nobody thought about).
        return "the star is a marker the skill deliberately specifies for a printed field card"
    return None

# A skill that carries a license is somebody else's work. Rewriting its prose puts this repo in
# conflict with every future version of it, and its text is not output this repo generates.
def licensed_skills(root):
    out = set()
    sk = os.path.join(root, "skills")
    if not os.path.isdir(sk):
        return out
    for name in sorted(os.listdir(sk)):
        f = os.path.join(sk, name, "SKILL.md")
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                head = [next(fh, "") for _ in range(20)]
        except OSError:
            continue
        if any(re.match(r"\s*license:", line, re.I) for line in head):
            out.add(name)
    return out

LICENSED = licensed_skills(root)

TEXTY = (".md", ".sh", ".py", ".js", ".mjs", ".json", ".txt", ".gs", ".yml", ".yaml")

hits = []
skipped = {}
licensed_hits = 0
scanned = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "__pycache__")]
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        if not name.endswith(TEXTY):
            continue
        parts = rel.split(os.sep)
        if len(parts) >= 2 and parts[0] == "skills" and parts[1] in LICENSED:
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if DASH.search(line) or EMOJI.search(line):
                            licensed_hits += 1
            except OSError as e:
                # SAID. Swallowing this would subtract from the count below with nothing anywhere
                # recording that it had, so a file nobody could read would make the licensed total
                # look smaller rather than unknown (L11, L215).
                print("style-sweep: could not read %s, so it is missing from the licensed count: %s"
                      % (rel, e), file=sys.stderr)
            continue
        reason = why_skipped(path, rel)
        if reason:
            skipped.setdefault(reason, []).append(rel)
            continue
        scanned += 1
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    kinds = []
                    if DASH.search(line):
                        kinds.append("dash")
                    if EMOJI.search(line):
                        kinds.append("emoji")
                    if kinds:
                        hits.append((rel, n, "+".join(kinds), line.rstrip()[:120]))
        except OSError as e:
            print("style-sweep: could not read %s: %s" % (rel, e), file=sys.stderr)

# Reading nothing and reading everything clean look identical otherwise (L98).
if scanned == 0:
    print("style-sweep: found no text files under %s, so nothing was read. Refusing to report a "
          "clean sweep of nothing." % root, file=sys.stderr)
    sys.exit(2)

by_file = {}
for rel, n, kind, text in hits:
    by_file.setdefault(rel, []).append((n, kind, text))

for rel in sorted(by_file):
    print("%s (%d)" % (rel, len(by_file[rel])))
    for n, kind, text in by_file[rel]:
        print("  %5d  %-9s %s" % (n, kind, text))

print()
print("style-sweep: %d line(s) in %d of %d file(s) scanned under %s"
      % (len(hits), len(by_file), scanned, root))
for reason, files in sorted(skipped.items()):
    print("  not counted, %s: %s" % (reason, ", ".join(sorted(files))))
if LICENSED:
    # SAID rather than silently dropped: these are real violations of the same rule, they are just
    # not this repo's to fix, and a count of nothing would read as a payload with none in it (L11).
    print("  not counted, a skill carrying its own license is somebody else's work: %d line(s) in %s"
          % (licensed_hits, ", ".join(sorted(LICENSED))))
sys.exit(1 if hits else 0)
PY
