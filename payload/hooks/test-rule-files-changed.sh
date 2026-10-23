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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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
grep -q "LESSONS-INDEX.md" <<< "$out2" \
  && check "an edited rule file is reported" ok \
  || check "an edited rule file is reported" "said: $out2"
grep -q "RTK.md" <<< "$out2" \
  && check "a file that did not change is not named" "named RTK.md too: $out2" \
  || check "a file that did not change is not named" ok
grep -q "new session" <<< "$out2" \
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
grep -q "RTK.md" <<< "$out4" \
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
grep -q "EXTRA.md" <<< "$out5" \
  && grep -q "CLAUDE.md" <<< "$out5" \
  && check "a newly imported file is reported with the file that imported it" ok \
  || check "a newly imported file is reported with the file that imported it" "said: $out5"

rm -f "$RULES/EXTRA.md"
out6="$(prompt session-one)"
grep -q "EXTRA.md" <<< "$out6" \
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
grep -q "LESSONS-INDEX.md" <<< "$out8" \
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
grep -q "neither a session id nor a transcript path" <<< "$noid_err" \
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

# ---------------------------------------------------------------------------
# MODS (claude-config#1535). A session names its mods once, at its start, from
# CLAUDE_CODE_PLUGIN_DIRS, so a mod that arrives on disk later is not loaded in
# it until a new session. Claude Code itself reloads a CHANGED mod in a running
# session and says so in the transcript ("hooks.json changed, reloaded", or that
# the earlier version is still running when a reload fails), so a code change is
# not this hook's to report: saying it would repeat Claude Code's own line on
# every pull that touches a mod, and claim staleness that the reload has already
# cured (L11, L36). What it reports is the set of mods: one added or removed.
# ---------------------------------------------------------------------------
MODHOME="$TMPROOT/mods-home"
mkdir -p "$MODHOME"
printf '# global rules\n' > "$MODHOME/CLAUDE.md"
mkmod() { # mkmod <name>: a mod folder as the sync names it, a manifest under .claude-plugin
  mkdir -p "$MODHOME/mods/$1/.claude-plugin" "$MODHOME/mods/$1/hooks"
  printf '{ "name": "%s" }\n' "$1" > "$MODHOME/mods/$1/.claude-plugin/plugin.json"
  printf 'export const register = () => {}\n' > "$MODHOME/mods/$1/hooks/register.ts"
}
mkmod alpha-mod
modprompt() { # modprompt <session-id>
  python3 - "$1" <<'PY' | CLAUDE_RULES_DIR="$MODHOME" bash "$HOOK" 2>/dev/null
import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": ".", "prompt": "carry on"}))
PY
}

m1="$(modprompt mod-session)"
[ -z "$m1" ] \
  && check "#1535 the first prompt of a session with mods is silent" ok \
  || check "#1535 the first prompt of a session with mods is silent" "said: $m1"

# A change to a mod this session already loaded: Claude Code reloads it and says
# so itself, so this hook stays quiet rather than announcing it a second time.
printf 'export const register = () => { return 2 }\n' > "$MODHOME/mods/alpha-mod/hooks/register.ts"
m2="$(modprompt mod-session)"
[ -z "$m2" ] \
  && check "#1535 an edit to a mod the session loaded is left to Claude Code's own reload line" ok \
  || check "#1535 an edit to a mod the session loaded is left to Claude Code's own reload line" "said: $m2"

# A mod that arrives after the session started is not loaded in it.
mkmod beta-mod
m3="$(modprompt mod-session)"
grep -q "beta-mod" <<< "$m3" \
  && check "#1535 a mod added after the session started is named" ok \
  || check "#1535 a mod added after the session started is named" "said: $m3"
grep -q "alpha-mod" <<< "$m3" \
  && check "#1535 and a mod that was there all along is not" "named alpha-mod too: $m3" \
  || check "#1535 and a mod that was there all along is not" ok
grep -q "not loaded" <<< "$m3" && grep -q "new session" <<< "$m3" \
  && check "#1535 the notice says this session has not loaded it and a new session does" ok \
  || check "#1535 the notice says this session has not loaded it and a new session does" "said: $m3"
grep -q "rule files" <<< "$m3" \
  && check "#1535 and it is not worded as a rule file change" "said: $m3" \
  || check "#1535 and it is not worded as a rule file change" ok

m4="$(modprompt mod-session)"
[ -z "$m4" ] \
  && check "#1535 the same added mod is not reported twice" ok \
  || check "#1535 the same added mod is not reported twice" "said again: $m4"

# A folder with no manifest is not a mod: the sync does not name it in
# CLAUDE_CODE_PLUGIN_DIRS either, so no session would load it.
mkdir -p "$MODHOME/mods/half-made/hooks"
printf 'x\n' > "$MODHOME/mods/half-made/hooks/register.ts"
m5="$(modprompt mod-session)"
[ -z "$m5" ] \
  && check "#1535 a folder with no manifest is not reported as a mod" ok \
  || check "#1535 a folder with no manifest is not reported as a mod" "said: $m5"

# A mod removed from disk is named too, in words of its own.
rm -rf "$MODHOME/mods/alpha-mod"
m6="$(modprompt mod-session)"
grep -q "alpha-mod" <<< "$m6" && grep -q "removed" <<< "$m6" \
  && check "#1535 a mod removed from disk is named as removed" ok \
  || check "#1535 a mod removed from disk is named as removed" "said: $m6"

# A rule file and a mod changing before one prompt are both said, each in its own words.
mkmod gamma-mod
printf '# global rules, edited\n' > "$MODHOME/CLAUDE.md"
m7="$(modprompt mod-session)"
grep -q "gamma-mod" <<< "$m7" && grep -q "CLAUDE.md" <<< "$m7" \
  && check "#1535 a rule file and a mod changing together are both reported" ok \
  || check "#1535 a rule file and a mod changing together are both reported" "said: $m7"

# A config directory with no mods folder at all has nothing to report and must not crash.
nomods="$(printf '{"session_id":"no-mods","cwd":"."}' | CLAUDE_RULES_DIR="$RULES" bash "$HOOK" 2>&1)"
nomods_code=$?
[ "$nomods_code" -eq 0 ] && [ -z "$nomods" ] \
  && check "#1535 a config directory with no mods folder is quiet" ok \
  || check "#1535 a config directory with no mods folder is quiet" "exit=$nomods_code out=$nomods"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
