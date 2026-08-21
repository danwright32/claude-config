#!/usr/bin/env bash
# Tests for gh_issue_scan.py, the shared parser behind the `gh issue create` completeness gates
# (claude-config#124).
#
# It is exercised end to end by test-require-issue-fields.sh, which is real coverage, but nothing
# tested it DIRECTLY and its own docstrings carry three dated incidents: a create on line 3 that
# was invisible because a newline is plain whitespace to the lexer, an override on line 1 that
# silently exempted a create three lines later, and `gh issue create --help` being blocked for
# having no category. Those are the cases a change to the splitting logic would break, and they are
# the ones a gate's own suite is least likely to reach, because it asks about the gate's verdict
# rather than about what the parser saw.
#
# Both gates fail OPEN on anything unreadable, deliberately: they are completeness gates, not
# safety gates, and a false block on a command nobody could parse teaches the override habit. That
# choice is only safe if "unreadable" stays rare and loud, so it is checked as its own outcome.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-gh_issue_scan: python3 is not on PATH, so nothing was verified." >&2; exit 2; }
[ -f "$DIR/gh_issue_scan.py" ] || { echo "test-gh_issue_scan: gh_issue_scan.py is not next to this suite." >&2; exit 2; }

# Every question is asked of the module itself, through one helper, so a check reads as the
# question it is asking rather than as python.
ask() { # ask <mode> <command>  -> one line of output
  PYTHONPATH="$DIR" python3 - "$1" "$2" <<'PY'
import sys
import gh_issue_scan as g

mode, cmd = sys.argv[1], sys.argv[2]
try:
    creates = g.scan_creates(cmd)
except g.Unreadable as e:
    print("UNREADABLE:%s" % e)
    raise SystemExit

if mode == "count":
    print(len(creates))
elif mode == "milestones":
    print("|".join(",".join(g.flag_values(a, "--milestone", "-m")) for a, _ in creates))
elif mode == "labels":
    print("|".join(",".join(g.flag_values(a, "--label", "-l")) for a, _ in creates))
elif mode == "titles":
    print("|".join(",".join(g.flag_values(a, "--title", "-t")) for a, _ in creates))
elif mode == "env":
    print("|".join(",".join(e) for _, e in creates))
PY
}

# ---------------------------------------------------------------------------
# Finding the creates. Each of these is a shape a real command really takes.
# ---------------------------------------------------------------------------
[ "$(ask count 'gh issue create --title x --label bug')" = "1" ] \
  && check "a plain create is found" ok || check "a plain create is found" "got $(ask count 'gh issue create --title x --label bug')"
[ "$(ask count 'echo hi && gh issue create -t x')" = "1" ] \
  && check "one after a shell operator is found" ok || check "one after a shell operator is found" "not found"
[ "$(ask count "$(printf 'echo one\ngh issue create -t x\necho three')")" = "1" ] \
  && check "one on its own LINE is found, which a lexer alone would miss" ok \
  || check "one on its own LINE is found, which a lexer alone would miss" "not found"
[ "$(ask count "$(printf 'gh issue create -t a \\\\\n  --label bug')")" = "1" ] \
  && check "one split across a line continuation is ONE create, not two" ok \
  || check "one split across a line continuation is ONE create, not two" "got $(ask count "$(printf 'gh issue create -t a \\\\\n  --label bug')")"
[ "$(ask count "$(printf 'gh issue create -t a\ngh issue create -t b')")" = "2" ] \
  && check "two on separate lines are both found" ok \
  || check "two on separate lines are both found" "got $(ask count "$(printf 'gh issue create -t a\ngh issue create -t b')")"

# ---------------------------------------------------------------------------
# And the things that only LOOK like creates. A gate that fires on these is a gate people learn to
# override.
# ---------------------------------------------------------------------------
[ "$(ask count 'echo "run gh issue create when you are ready"')" = "0" ] \
  && check "a create quoted inside a string is not one" ok || check "a create quoted inside a string is not one" "it counted one"
[ "$(ask count "$(printf 'cat <<EOF\ngh issue create -t x\nEOF')")" = "0" ] \
  && check "a create inside a heredoc body is not one" ok || check "a create inside a heredoc body is not one" "it counted one"
[ "$(ask count 'gh issue list && gh pr create -t x')" = "0" ] \
  && check "a different gh subcommand is not one" ok || check "a different gh subcommand is not one" "it counted one"
for flag in --help -h --web -w; do
  [ "$(ask count "gh issue create $flag")" = "0" ] \
    && check "'gh issue create $flag' files nothing, so it is not a create" ok \
    || check "'gh issue create $flag' files nothing, so it is not a create" "it counted one"
done
# The control: the same command WITHOUT the non filing flag is a create, so the checks above are
# not satisfied by a parser that stopped finding anything (L159).
[ "$(ask count 'gh issue create')" = "1" ] \
  && check "the control: a bare create still counts" ok || check "the control: a bare create still counts" "it counted none"

# ---------------------------------------------------------------------------
# Reading the flags off one create. All four forms gh accepts, because a gate reading only two of
# them refuses commands that were complete.
# ---------------------------------------------------------------------------
[ "$(ask milestones 'gh issue create --milestone Ungrouped')" = "Ungrouped" ] \
  && check "--flag value is read" ok || check "--flag value is read" "got $(ask milestones 'gh issue create --milestone Ungrouped')"
[ "$(ask milestones 'gh issue create --milestone=Ungrouped')" = "Ungrouped" ] \
  && check "--flag=value is read" ok || check "--flag=value is read" "got $(ask milestones 'gh issue create --milestone=Ungrouped')"
[ "$(ask milestones 'gh issue create -m Ungrouped')" = "Ungrouped" ] \
  && check "-f value is read" ok || check "-f value is read" "got $(ask milestones 'gh issue create -m Ungrouped')"
[ "$(ask milestones 'gh issue create -mUngrouped')" = "Ungrouped" ] \
  && check "-fvalue attached is read" ok || check "-fvalue attached is read" "got $(ask milestones 'gh issue create -mUngrouped')"
[ "$(ask labels 'gh issue create --label bug --label tech-debt')" = "bug,tech-debt" ] \
  && check "a flag given twice yields both values" ok || check "a flag given twice yields both values" "got $(ask labels 'gh issue create --label bug --label tech-debt')"
# `--label` must not be swallowed by the `-l` short form, which shares its first letter.
[ "$(ask labels 'gh issue create --label bug')" = "bug" ] \
  && check "a long flag is not mistaken for its own short form plus a value" ok \
  || check "a long flag is not mistaken for its own short form plus a value" "got $(ask labels 'gh issue create --label bug')"
# A flag with nothing after it, or another flag after it, contributes nothing: an EMPTY value must
# never satisfy a gate that is checking the field was filled in (L67).
[ -z "$(ask milestones 'gh issue create --milestone')" ] \
  && check "a flag with no value at all yields nothing" ok || check "a flag with no value at all yields nothing" "got something"
[ -z "$(ask milestones 'gh issue create --milestone --label bug')" ] \
  && check "a flag followed by another flag yields nothing" ok || check "a flag followed by another flag yields nothing" "got something"

# A '#' in a title must not swallow the rest of the command, or the flags after it vanish and a
# complete create is reported as missing everything.
[ "$(ask labels 'gh issue create --title "fixes #12 properly" --label bug')" = "bug" ] \
  && check "a hash inside a title does not eat the flags after it" ok \
  || check "a hash inside a title does not eat the flags after it" "got $(ask labels 'gh issue create --title "fixes #12 properly" --label bug')"

# ---------------------------------------------------------------------------
# An override belongs to the ONE command it prefixes. Reading it across the whole call is how an
# unmilestoned create slipped through on 2026-07-29.
# ---------------------------------------------------------------------------
two_seg="$(printf 'SKIP_MILESTONE_CHECK=1 gh issue create -t a\ngh issue create -t b')"
[ "$(ask env "$two_seg")" = "SKIP_MILESTONE_CHECK=1|" ] \
  && check "an override on the first create does not reach the second" ok \
  || check "an override on the first create does not reach the second" "got $(ask env "$two_seg")"
[ "$(ask env 'FOO=1 BAR=2 gh issue create -t a')" = "FOO=1,BAR=2" ] \
  && check "several env assignments in front of one create are all kept" ok \
  || check "several env assignments in front of one create are all kept" "got $(ask env 'FOO=1 BAR=2 gh issue create -t a')"

# ---------------------------------------------------------------------------
# Unreadable is its own answer, not zero creates. Zero means "nothing to gate" and lets the command
# through silently; unreadable is a fact the gate has to be able to act on (L11).
# ---------------------------------------------------------------------------
case "$(ask count 'gh issue create --title "unbalanced')" in
  UNREADABLE*) check "a command with unbalanced quotes is reported as unreadable" ok ;;
  *) check "a command with unbalanced quotes is reported as unreadable" "it answered $(ask count 'gh issue create --title "unbalanced') instead" ;;
esac
[ "$(ask count '')" = "0" ] \
  && check "an empty command is zero creates, not unreadable" ok || check "an empty command is zero creates, not unreadable" "got $(ask count '')"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
