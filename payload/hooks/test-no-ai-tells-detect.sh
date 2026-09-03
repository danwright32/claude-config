#!/usr/bin/env bash
# Tests for no-ai-tells-detect.py, which decides whether a prompt is asking for PROSE and, if so,
# loads the writing skill into the turn (claude-config#124).
#
# It is a classifier over the prompt text, and both ways of being wrong are quiet. Missing a real
# writing request means the copy goes out with every AI tell the skill exists to remove. Firing on
# a coding request means a whole skill is pasted into a turn that has no use for it. It had no
# test, and a classifier with no test is a list of keywords nobody has read against the sentences
# it will actually meet (L104: a shape matcher must be checked against what it has to PRESERVE, not
# only against what it has to catch).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/no-ai-tells-detect.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-no-ai-tells-detect: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.noaitells.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-no-ai-tells-detect: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A HOME of this run's own, holding the skill from THIS REPO. The hook reads the skill out of the
# config directory, so left to the ambient HOME this suite would be asking whether the machine it
# runs on happens to have synced, not whether the hook works: it passed on a Mac where the skill is
# installed and failed every firing check on the Linux runner where it is not (L2, L504).
FAKEHOME="$TMPROOT/home"
mkdir -p "$FAKEHOME/.claude/skills/no-ai-tells"
REPO_SKILL="$DIR/../skills/no-ai-tells/SKILL.md"
[ -f "$REPO_SKILL" ] || { echo "test-no-ai-tells-detect: the skill is not in the payload at $REPO_SKILL, so there is nothing to test against." >&2; exit 2; }
cp "$REPO_SKILL" "$FAKEHOME/.claude/skills/no-ai-tells/SKILL.md"

fires() { # fires <prompt>  -> "yes" if the skill was injected, "no" if not
  local o
  o="$(python3 -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1]}))' "$1" | HOME="$FAKEHOME" python3 "$H" 2>/dev/null)"
  case "$o" in *additionalContext*) printf 'yes' ;; *) printf 'no' ;; esac
}

# ---------------------------------------------------------------------------
# What it has to CATCH. Written as sentences somebody would really type, not as the keywords.
# ---------------------------------------------------------------------------
for p in \
  "write a blog post about the new booking flow" \
  "draft the announcement for tomorrow" \
  "can you rewrite this paragraph so it sounds less stiff" \
  "polish this tagline" \
  "write the tooltip for the export button" \
  "humanize this" \
  ; do
  [ "$(fires "$p")" = "yes" ] \
    && check "it fires on: $p" ok \
    || check "it fires on: $p" "it stayed quiet"
done

# ---------------------------------------------------------------------------
# What it has to LEAVE ALONE, which is the half a keyword list gets wrong. Every one of these
# contains a writing verb.
# ---------------------------------------------------------------------------
for p in \
  "write a function that parses the config" \
  "write a test for the retry path" \
  "rewrite this component to use the new hook" \
  "draft a SQL query for the monthly totals" \
  "compose the API endpoint for saved views" \
  "refactor this module" \
  ; do
  [ "$(fires "$p")" = "no" ] \
    && check "it stays quiet on: $p" ok \
    || check "it stays quiet on: $p" "it fired"
done

# A prompt with no writing intent at all.
[ "$(fires "what time does the build finish")" = "no" ] \
  && check "and on a prompt that asks for nothing to be written" ok \
  || check "and on a prompt that asks for nothing to be written" "it fired"

# ---------------------------------------------------------------------------
# What it injects has to be the skill itself, not merely something.
# ---------------------------------------------------------------------------
out="$(python3 -c 'import json; print(json.dumps({"prompt":"write a blog post"}))' | HOME="$FAKEHOME" python3 "$H" 2>/dev/null)"
ctx="$(printf '%s' "$out" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext",""))' 2>/dev/null)"
grep -qi 'no-ai-tells' <<< "$ctx" \
  && check "what it injects is the writing skill" ok \
  || check "what it injects is the writing skill" "ctx=${ctx:0:120}"
[ "${#ctx}" -gt 400 ] \
  && check "and the whole of it, not a stub" ok \
  || check "and the whole of it, not a stub" "only ${#ctx} characters came through"

# ---------------------------------------------------------------------------
# Payloads it must survive.
# ---------------------------------------------------------------------------
out_junk="$(printf 'not json' | HOME="$FAKEHOME" python3 "$H" 2>/dev/null)"; code_junk=$?
[ -z "$out_junk" ] && [ "$code_junk" -eq 0 ] \
  && check "a payload that does not parse injects nothing and exits cleanly" ok \
  || check "a payload that does not parse injects nothing and exits cleanly" "out=$out_junk exit=$code_junk"
out_noprompt="$(printf '{}' | HOME="$FAKEHOME" python3 "$H" 2>/dev/null)"
[ -z "$out_noprompt" ] \
  && check "a payload with no prompt injects nothing" ok \
  || check "a payload with no prompt injects nothing" "out=$out_noprompt"

# ---------------------------------------------------------------------------
# The skill file it loads lives outside this repo, at a path in the config directory, so it can be
# absent on a Mac that has not synced yet. Detecting a writing request and then silently injecting
# NOTHING is the worst of the three outcomes: the copy goes out unguarded and the hook looks like
# it decided the prompt was not writing (L11, L98).
# ---------------------------------------------------------------------------
NOSKILL="$TMPROOT/home-without-the-skill"; mkdir -p "$NOSKILL"
err_missing="$(python3 -c 'import json; print(json.dumps({"prompt":"write a blog post"}))' 2>/dev/null | HOME="$NOSKILL" python3 "$H" 2>&1 >/dev/null)"
out_missing="$(python3 -c 'import json; print(json.dumps({"prompt":"write a blog post"}))' 2>/dev/null | HOME="$NOSKILL" python3 "$H" 2>/dev/null)"
[ -z "$out_missing" ] \
  && check "with the skill file absent it injects nothing" ok \
  || check "with the skill file absent it injects nothing" "out=$out_missing"
grep -qi 'no-ai-tells' <<< "$err_missing" \
  && check "and says so, rather than looking like a prompt it decided was not writing" ok \
  || check "and says so, rather than looking like a prompt it decided was not writing" "it said nothing at all"
# The control: the same absent-HOME run on a NON writing prompt must stay silent, or the check
# above is satisfied by a hook that complains on every prompt (L159).
err_quiet="$(python3 -c 'import json; print(json.dumps({"prompt":"write a function"}))' 2>/dev/null | HOME="$NOSKILL" python3 "$H" 2>&1 >/dev/null)"
[ -z "$err_quiet" ] \
  && check "and stays silent when the prompt was not asking for prose anyway" ok \
  || check "and stays silent when the prompt was not asking for prose anyway" "it said: $err_quiet"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
