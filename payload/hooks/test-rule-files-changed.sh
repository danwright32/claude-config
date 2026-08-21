#!/usr/bin/env bash
# Tests for rule-files-changed.sh, the notice that this session's rule files have
# changed underneath it (claude-config#84).
#
# The thing worth proving is not that it can speak, but that it can stay quiet:
# a check that fires on every prompt is indistinguishable from one that has
# noticed something, and it would be ignored within a day (L36). So every scenario
# here asserts both states, and the silent ones run in the same fixture as the
# loud ones rather than in a tree where nothing could have been detected (L159).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/rule-files-changed.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# The baselines go in this run's own directory. Left in the shared temp dir they
# outlive the run, and the NEXT run of this suite would inherit them: its "first
# prompt is silent" check would then be answered by a baseline recorded minutes
# ago by a different process, which is a test passing for a reason nobody chose.
# Caught by running the suite twice (L2).
export CLAUDE_RULES_STATE_DIR="$TMPROOT/state"

RULES="$TMPROOT/dot-claude"
mkdir -p "$RULES"
cat > "$RULES/CLAUDE.md" <<'MD'
@RTK.md
@LESSONS-INDEX.md

# global rules
MD
printf 'rtk one\n' > "$RULES/RTK.md"
printf 'index one\n' > "$RULES/LESSONS-INDEX.md"

prompt() { # prompt <session-id>  -> runs the hook as a UserPromptSubmit would
  python3 - "${1:-session-one}" <<'PY' | CLAUDE_RULES_DIR="$RULES" bash "$HOOK" 2>/dev/null
import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": ".", "prompt": "carry on"}))
PY
}

# ---------------------------------------------------------------------------
# The first prompt of a session takes the baseline and says nothing. There is
# nothing to report yet, and a notice here would fire in every session ever.
# ---------------------------------------------------------------------------
out1="$(prompt session-one)"
[ -z "$out1" ] \
  && check "the first prompt of a session is silent" ok \
  || check "the first prompt of a session is silent" "said: $out1"

# ---------------------------------------------------------------------------
# A rule file edited underneath the session is named, and only that one.
# ---------------------------------------------------------------------------
printf 'index two, with a new lesson\n' > "$RULES/LESSONS-INDEX.md"
out2="$(prompt session-one)"
printf '%s' "$out2" | grep -q "LESSONS-INDEX.md" \
  && check "an edited rule file is reported" ok \
  || check "an edited rule file is reported" "said: $out2"
printf '%s' "$out2" | grep -q "RTK.md" \
  && check "a file that did not change is not named" "named RTK.md too: $out2" \
  || check "a file that did not change is not named" ok
printf '%s' "$out2" | grep -q "new session" \
  && check "the notice says what to do about it" ok \
  || check "the notice says what to do about it" "said: $out2"

# ---------------------------------------------------------------------------
# ...once. The same divergence must not be reported again on the next prompt,
# and with nothing further changing the hook must be silent, which is what shows
# it distinguishes the two states rather than always firing.
# ---------------------------------------------------------------------------
out3="$(prompt session-one)"
[ -z "$out3" ] \
  && check "the same change is not reported twice" ok \
  || check "the same change is not reported twice" "said again: $out3"

# ...and a SECOND change still speaks, so being quiet above is not the hook
# having switched itself off for the session.
printf 'rtk two\n' > "$RULES/RTK.md"
out4="$(prompt session-one)"
printf '%s' "$out4" | grep -q "RTK.md" \
  && check "a later change is reported in its turn" ok \
  || check "a later change is reported in its turn" "said: $out4"

# ---------------------------------------------------------------------------
# A newly IMPORTED file, and a file that goes away, are both changes. Skipping a
# missing one would make its disappearance read exactly like nothing happening.
# ---------------------------------------------------------------------------
printf 'extra one\n' > "$RULES/EXTRA.md"
printf '@EXTRA.md\n%s\n' "$(cat "$RULES/CLAUDE.md")" > "$RULES/CLAUDE.md.new"
mv "$RULES/CLAUDE.md.new" "$RULES/CLAUDE.md"
out5="$(prompt session-one)"
printf '%s' "$out5" | grep -q "EXTRA.md" \
  && printf '%s' "$out5" | grep -q "CLAUDE.md" \
  && check "a newly imported file is reported with the file that imported it" ok \
  || check "a newly imported file is reported with the file that imported it" "said: $out5"

rm -f "$RULES/EXTRA.md"
out6="$(prompt session-one)"
printf '%s' "$out6" | grep -q "EXTRA.md" \
  && check "a rule file that disappears is reported" ok \
  || check "a rule file that disappears is reported" "said: $out6"

# ---------------------------------------------------------------------------
# Two sessions open at once each get their own baseline. A shared one would make
# the second session's first prompt report everything the first session saw.
# ---------------------------------------------------------------------------
out7="$(prompt session-two)"
[ -z "$out7" ] \
  && check "another session starts with its own baseline" ok \
  || check "another session starts with its own baseline" "said: $out7"
printf 'index three\n' > "$RULES/LESSONS-INDEX.md"
out8="$(prompt session-two)"
printf '%s' "$out8" | grep -q "LESSONS-INDEX.md" \
  && check "and is told about a change after its own start" ok \
  || check "and is told about a change after its own start" "said: $out8"

# ---------------------------------------------------------------------------
# A payload with nothing to identify the session cannot tell a first prompt from
# a later one, so it says nothing to the person and says why on stderr, rather
# than inventing an answer in either direction.
# ---------------------------------------------------------------------------
noid_out="$(printf '{"cwd":"."}' | CLAUDE_RULES_DIR="$RULES" bash "$HOOK" 2>/dev/null)"
noid_err="$(printf '{"cwd":"."}' | CLAUDE_RULES_DIR="$RULES" bash "$HOOK" 2>&1 >/dev/null)"
[ -z "$noid_out" ] \
  && check "an unidentifiable session gets no notice" ok \
  || check "an unidentifiable session gets no notice" "said: $noid_out"
printf '%s' "$noid_err" | grep -q "neither a session id nor a transcript path" \
  && check "and it says why, rather than passing as a clean check" ok \
  || check "and it says why, rather than passing as a clean check" "stderr: $noid_err"

# ---------------------------------------------------------------------------
# A config directory that is not there at all is not this hook's problem to
# report, but it must not crash the prompt either.
# ---------------------------------------------------------------------------
gone_out="$(printf '{"session_id":"s","cwd":"."}' | CLAUDE_RULES_DIR="$TMPROOT/not-here" bash "$HOOK" 2>/dev/null)"
gone_code=$?
[ "$gone_code" -eq 0 ] && [ -z "$gone_out" ] \
  && check "a missing config directory exits cleanly and quietly" ok \
  || check "a missing config directory exits cleanly and quietly" "exit=$gone_code out=$gone_out"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
