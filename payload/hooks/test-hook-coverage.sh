#!/usr/bin/env bash
# A ratchet on hooks that no test suite names (claude-config#124).
#
# Eleven of them had nothing, including subagent-digest.py, whose own docstring spells out a three
# way contract and explains exactly why the three have to stay apart. Nothing anywhere reported the
# gap: a hook with no suite looks identical to one whose suite passes (L98), and the number was
# never written down, so it could grow without anybody noticing it had.
#
# So the list is written down and compared against what the files actually say. It fails in BOTH
# directions on purpose. Growing means a hook arrived without a suite. Shrinking without the file
# being edited means a name here is stale, and a ratchet nobody has to tighten quietly becomes a
# permanent excuse rather than a measurement (L182).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="${HOOK_COVERAGE_BASELINE:-$DIR/uncovered-hooks.txt}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# The predicate, in one place, so the baseline records an answer this produced rather than a second
# definition of the question drifting beside it (L107).
# The whole NAME, not a substring of a line (claude-config#268). `grep -lF "$b"` reported a hook
# whose name is a suffix of another hook's name as covered by every suite that mentions the longer
# one: `spool.sh` was answered for by five suites that all say `issue-spool.sh` and none of which
# mention a hook by that name. No such pair existed in the tree, which is why it would have gone
# unnoticed until it mattered.
#
# The boundary excludes the characters a hook name is made of, so `/`, a quote or a space before
# the name still matches and a `-` does not. claude-sync's send_suites_covering asks the same
# question in the same shape, deliberately, so a send verifies the set the ratchet calls covered
# (L263); each side has its own check that the suffix case is refused, because a shared NAME is
# read as evidence of shared BEHAVIOUR and nothing otherwise compares them.
hook_name_pattern(){   # $1 = a hook basename -> an ERE matching it as a whole name
  local esc
  esc="$(printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\]/\\&/g')"
  printf '(^|[^A-Za-z0-9_-])%s([^A-Za-z0-9_-]|$)' "$esc"
}

uncovered_now() { # uncovered_now <hooks dir>  -> one basename per line, sorted
  local d="${1%/}" f b
  # The suites are collected FIRST, and only ones that exist are passed to grep. Handed a path
  # that is not there, grep exits 2, and a caller testing only for non-zero reads that error as
  # "found no mention" and reports every hook as uncovered. It did exactly that here, against a
  # fixture whose whole point was one covered file (L184: judge by what the command measured, not
  # by a non-zero exit that could be either answer).
  local suites=()
  for f in "$d"/test-*.sh "$d"/../../tests/test-*.sh; do
    [ -f "$f" ] && suites+=("$f")
  done
  # No suites at all is not "everything is uncovered", it is a derivation that read nothing, and
  # the caller has to be able to tell those apart (L98).
  [ "${#suites[@]}" -gt 0 ] || return 3
  # hooks/lib/*.py is in the list since claude-config#246. It was the one combination the glob
  # missed, so a lib Python file with no suite at all was reported as fully covered, which is the
  # exact failure the ratchet exists to prevent, and invisible because the guard passed (L96).
  for f in "$d"/*.sh "$d"/*.py "$d"/lib/*.sh "$d"/lib/*.py; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in test-*|run-all-tests.sh) continue ;; esac
    if ! grep -lE "$(hook_name_pattern "$b")" "${suites[@]}" >/dev/null 2>&1; then
      printf '%s\n' "$b"
    fi
  done | sort -u
}
read_baseline() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed 's/[[:space:]]*$//' | sort -u; }

[ -f "$BASELINE" ] || { echo "test-hook-coverage: no baseline at $BASELINE, so there is nothing to compare against and nothing was verified." >&2; exit 2; }

# ---------------------------------------------------------------------------
# The derivation has to be able to see BOTH answers before the real comparison is trusted, or a
# predicate that matched nothing would report a perfectly covered tree (L98, L1).
# ---------------------------------------------------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.hookcov.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-hook-coverage: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT
FIX="$TMPROOT/hooks"; mkdir -p "$FIX/lib"
printf '#!/usr/bin/env bash\n' > "$FIX/covered.sh"
printf '#!/usr/bin/env bash\n' > "$FIX/naked.sh"
# A lib Python file with no suite (claude-config#246). The glob covered shell and Python in
# hooks/ and shell in hooks/lib/, but not Python in hooks/lib/, so review-reason.py sat outside
# the ratchet entirely, as inject-spool.py had before it. Nothing was broken in the tree; the
# defect was in the guard, and a guard that passes while blind is the failure it exists to
# prevent (L96).
printf '#!/usr/bin/env python3\n' > "$FIX/lib/naked-lib.py"
printf '#!/usr/bin/env python3\n' > "$FIX/lib/covered-lib.py"
# A hook whose name is a SUFFIX of another hook's name (claude-config#268). The predicate was
# `grep -lF "$b"`, a substring test, so `spool.sh` was reported as covered by every suite that
# merely says `issue-spool.sh`. Measured 2026-09-02: five suites in this tree match `spool.sh`
# and not one of them mentions a hook by that name. No such pair existed, which is exactly why
# it would have gone unnoticed.
printf '#!/usr/bin/env bash\n' > "$FIX/spool.sh"
printf '#!/usr/bin/env bash\n' > "$FIX/issue-spool.sh"
printf '#!/usr/bin/env bash\nbash "$DIR/covered.sh"\npython3 "$DIR/lib/covered-lib.py"\nbash "$DIR/issue-spool.sh"\n' > "$FIX/test-covered.sh"
got="$(uncovered_now "$FIX")"
want="$(printf 'naked-lib.py\nnaked.sh\nspool.sh\n' | sort -u)"
[ "$got" = "$want" ] \
  && check "the derivation names every hook no suite mentions, and only those" ok \
  || check "the derivation names every hook no suite mentions, and only those" "it answered: [$got], wanted: [$want]"
# Named separately as well as counted, because a single equality check that fails says only that
# the set is wrong and sends the reader to work out which member moved (L11).
case "
$got" in *"
naked-lib.py"*) check "#246 a lib Python file with no suite is seen at all" ok ;;
  *) check "#246 a lib Python file with no suite is seen at all" "the glob does not reach hooks/lib/*.py" ;;
esac
case "
$got" in *"
spool.sh"*) check "#268 a hook whose name is a suffix of another is not called covered" ok ;;
  *) check "#268 a hook whose name is a suffix of another is not called covered" "a suite naming only issue-spool.sh answered for it" ;;
esac
case "
$got" in *"
issue-spool.sh"*) check "#268 and the hook the suite really does name is still covered" "it was reported uncovered" ;;
  *) check "#268 and the hook the suite really does name is still covered" ok ;;
esac
case "
$got" in *"
covered-lib.py"*) check "#246 and a lib Python file a suite names is covered" "it was reported uncovered" ;;
  *) check "#246 and a lib Python file a suite names is covered" ok ;;
esac

# ---------------------------------------------------------------------------
# The comparison itself, both directions, against a fixture before the real tree.
# ---------------------------------------------------------------------------
# Reading no suites at all is its own answer, not "every hook is uncovered". A directory holding
# hooks and no suites is what a half-copied tree looks like, and reporting nine uncovered hooks
# there is a measurement nobody could act on.
NOSUITES="$TMPROOT/nosuites"; mkdir -p "$NOSUITES/lib"
printf '#!/usr/bin/env bash\n' > "$NOSUITES/lonely.sh"
uncovered_now "$NOSUITES" >/dev/null 2>&1
[ "$?" -eq 3 ] \
  && check "a directory with no suites at all is refused, not reported as all-uncovered" ok \
  || check "a directory with no suites at all is refused, not reported as all-uncovered" "it answered instead of refusing"

printf 'naked-lib.py\nnaked.sh\nspool.sh\nsomething-that-left.sh\n' > "$TMPROOT/stale-baseline.txt"
stale="$(comm -13 <(uncovered_now "$FIX") <(read_baseline "$TMPROOT/stale-baseline.txt"))"
[ "$stale" = "something-that-left.sh" ] \
  && check "a baseline naming something no longer uncovered is spotted" ok \
  || check "a baseline naming something no longer uncovered is spotted" "it spotted: [$stale]"
printf '# nothing\n' > "$TMPROOT/empty-baseline.txt"
grew="$(comm -23 <(uncovered_now "$FIX") <(read_baseline "$TMPROOT/empty-baseline.txt"))"
[ "$grew" = "$want" ] \
  && check "a hook missing from the baseline is spotted" ok \
  || check "a hook missing from the baseline is spotted" "it spotted: [$grew], wanted: [$want]"

# ---------------------------------------------------------------------------
# The real tree.
# ---------------------------------------------------------------------------
now="$(uncovered_now "$DIR")"
base="$(read_baseline "$BASELINE")"
n_now="$(printf '%s\n' "$now" | grep -c . || true)"
n_base="$(printf '%s\n' "$base" | grep -c . || true)"

# NOT "the baseline is non empty". It is allowed to reach zero, and reaching zero is the point of a
# ratchet. What must stay true is that the derivation can still SEE an uncovered hook, and that is
# proved above against a fixture built to hold one, every run, whatever the real tree says. A count
# at zero read as proof the thing cannot happen is exactly how a ratchet stops being a measurement
# (L182), so the proof lives in the fixture rather than in the number.
if [ "${n_base:-0}" -eq 0 ]; then
  echo "test-hook-coverage: the baseline is empty, so every hook is named by some suite. The"
  echo "  derivation was still watched finding one, against the fixture above."
fi

new_gaps="$(comm -23 <(printf '%s\n' "$now") <(printf '%s\n' "$base") | grep -v '^$' || true)"
case "$new_gaps" in
  *[![:space:]]*)
    check "no hook has arrived without a suite" "these are named by no test-*.sh and are not in $(basename "$BASELINE"):
$(printf '%s\n' "$new_gaps" | sed 's/^/    /')
  Write it a suite, or add the name to the baseline and say why in the same change." ;;
  *) check "no hook has arrived without a suite" ok ;;
esac

closed="$(comm -13 <(printf '%s\n' "$now") <(printf '%s\n' "$base") | grep -v '^$' || true)"
case "$closed" in
  *[![:space:]]*)
    check "the baseline has been tightened as suites were written" "these are covered now, or gone, and are still listed in $(basename "$BASELINE"):
$(printf '%s\n' "$closed" | sed 's/^/    /')
  Remove them, so the number left keeps meaning something." ;;
  *) check "the baseline has been tightened as suites were written" ok ;;
esac

# ---------------------------------------------------------------------------
# How the hooks are REGISTERED, not only whether a suite names them (claude-config#400).
#
# A sync on 2026-09-11 (e702974) folded the Edit|Write groups into the Bash groups beside them. The
# result was payload-write-gate.sh listed twice under PreToolUse Bash, so it ran twice on every
# Bash call, and registered for NO edit tool at all, so the gate written to refuse an Edit or Write
# the watcher would revert stopped seeing Edit and Write. lesson-entry-check.sh, whose header says
# PostToolUse(Edit|Write|MultiEdit), was moved under Bash the same way. Every suite stayed green,
# because each one runs its hook directly and none asks what the settings file does with it (L3).
#
# Two questions, one pass over the settings:
#   DUPLICATE  one command registered twice under the same event and matcher. The key includes the
#              entry's `if`, because the same hook scoped to two different commands is deliberate.
#   UNWIRED    a hook whose header declares `Claude Code <Event>(<tools>) hook` is not run for
#              one of those tools under that event. The header is the hook's own statement of
#              where it belongs, so the settings are compared against it rather than a second
#              list written here (L41).
#   EXTRA      such a hook is ALSO run for a tool its header does not declare (claude-config#413).
#              The 2026-09-17 incident put the Playwright gate in the Edit and Write group, and a
#              copy there beside a correct group would have passed UNWIRED alone.
# ---------------------------------------------------------------------------
# The question itself lives in lib/hook-registration.py (claude-config#413), because claude-sync's
# send asks it too, before publishing a hooks block, and one rule in two copies drifts (L41, L370).
# It exits 0 when it judged the file clean, 1 when it printed faults, and anything else when it
# could not judge at all.
registration_faults(){ # registration_faults <settings file> <hooks dir> -> one fault per line
  python3 "$DIR/lib/hook-registration.py" "$1" "$2"
}

REG="$TMPROOT/registration"; mkdir -p "$REG/hooks"
printf '#!/usr/bin/env bash\n#\n# gate.sh\n# Claude Code PreToolUse(Bash|Edit) hook: a fixture.\n' > "$REG/hooks/gate.sh"
printf '#!/usr/bin/env bash\n# Claude Code PreToolUse hook: declares no tools, so nothing is asked of it.\n' > "$REG/hooks/quiet.sh"
# The shape e702974 left behind: the gate twice under Bash and nowhere under Edit.
cat > "$REG/folded.json" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"},
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/quiet.sh", "if": "Bash(git *)"},
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/quiet.sh", "if": "Bash(gh *)"},
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"}
  ]}
]}}
JSON
cat > "$REG/sound.json" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"},
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/quiet.sh", "if": "Bash(git *)"},
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/quiet.sh", "if": "Bash(gh *)"}
  ]},
  {"matcher": "Edit", "hooks": [
    {"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"}
  ]}
]}}
JSON
folded="$(registration_faults "$REG/folded.json" "$REG/hooks" 2>&1)"
case "$folded" in
  *"DUPLICATE PreToolUse matcher='Bash' __CLAUDE_HOME__/hooks/gate.sh is registered 2 times"*)
    check "#400 a command registered twice under one event and matcher is reported" ok ;;
  *) check "#400 a command registered twice under one event and matcher is reported" "it answered: [$folded]" ;;
esac
case "$folded" in
  *"UNWIRED gate.sh declares PreToolUse(Bash|Edit) and is not run for Edit"*)
    check "#400 a hook not run for a tool its header declares is reported" ok ;;
  *) check "#400 a hook not run for a tool its header declares is reported" "it answered: [$folded]" ;;
esac
case "$folded" in
  *quiet.sh*) check "#400 one hook scoped by two different ifs is not a duplicate" "it answered: [$folded]" ;;
  *) check "#400 one hook scoped by two different ifs is not a duplicate" ok ;;
esac
printf '{"hooks": {"PreToolUse": [{"matcher": "Edit(", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"}]}]}}\n' > "$REG/broken.json"
broken="$(registration_faults "$REG/broken.json" "$REG/hooks" 2>&1)"
case "$broken" in
  *"BAD MATCHER 'Edit(' is not a valid pattern"*)
    check "#400 a matcher that is not a valid pattern is reported as such, not judged" ok ;;
  *) check "#400 a matcher that is not a valid pattern is reported as such, not judged" "it answered: [$broken]" ;;
esac
sound="$(registration_faults "$REG/sound.json" "$REG/hooks" 2>&1)"
sound_rc=$?
[ -z "$sound" ] && [ "$sound_rc" -eq 0 ] \
  && check "#400 a settings file registering each hook once, where it belongs, reports nothing" ok \
  || check "#400 a settings file registering each hook once, where it belongs, reports nothing" "it answered: [$sound], exit $sound_rc"

# EXTRA (claude-config#413). A hook declaring a PATTERN, as the Playwright gate does, is judged by
# the same line: registered under that pattern is right, and the same group widened to Edit, or a
# second registration under the other tool event, is not.
printf '#!/usr/bin/env bash\n#\n# pwfix.sh\n# Claude Code PreToolUse(mcp__pw__.*|mcp__other_pw__.*) hook: a fixture.\n' > "$REG/hooks/pwfix.sh"
cat > "$REG/extra.json" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"}]},
  {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"}]},
  {"matcher": "mcp__pw__.*|mcp__other_pw__.*|Edit", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/pwfix.sh"}]}
 ],
 "PostToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/gate.sh"}]}
]}}
JSON
extra="$(registration_faults "$REG/extra.json" "$REG/hooks" 2>&1)"
extra_rc=$?
case "$extra" in
  *"EXTRA gate.sh declares PreToolUse(Bash|Edit) and is also run for Write"*)
    check "#413 a hook also run for a tool its header does not declare is reported" ok ;;
  *) check "#413 a hook also run for a tool its header does not declare is reported" "it answered: [$extra]" ;;
esac
case "$extra" in
  *"EXTRA gate.sh declares PreToolUse(Bash|Edit) and is also run under PostToolUse for Bash"*)
    check "#413 a hook also run under the other tool event is reported" ok ;;
  *) check "#413 a hook also run under the other tool event is reported" "it answered: [$extra]" ;;
esac
case "$extra" in
  *"EXTRA pwfix.sh declares PreToolUse(mcp__pw__.*|mcp__other_pw__.*) and is also run for Edit"*)
    check "#413 a hook declaring a pattern, widened to another tool, is reported" ok ;;
  *) check "#413 a hook declaring a pattern, widened to another tool, is reported" "it answered: [$extra]" ;;
esac
case "$extra" in
  *"UNWIRED pwfix"*|*"for mcp__"*) check "#413 and the patterns it does declare are not reported" "it answered: [$extra]" ;;
  *) check "#413 and the patterns it does declare are not reported" ok ;;
esac
[ "$extra_rc" -eq 1 ] \
  && check "#413 faults are answered with exit 1, so a caller can tell them from a clean file" ok \
  || check "#413 faults are answered with exit 1, so a caller can tell them from a clean file" "exit $extra_rc"
registration_faults "$REG/missing.json" "$REG/hooks" >/dev/null 2>&1
missing_rc=$?
[ "$missing_rc" -ne 0 ] && [ "$missing_rc" -ne 1 ] \
  && check "#413 a settings file that cannot be read is neither clean nor faulty" ok \
  || check "#413 a settings file that cannot be read is neither clean nor faulty" "exit $missing_rc"

# The real settings: the payload copy inside the checkout, the installed copy once deployed.
SETTINGS=""
if [ -f "$DIR/../settings.hooks.json" ]; then SETTINGS="$DIR/../settings.hooks.json"
elif [ -f "$DIR/../settings.json" ]; then SETTINGS="$DIR/../settings.json"; fi
if [ -z "$SETTINGS" ]; then
  check "the settings file registering the hooks could be read" "neither settings.hooks.json nor settings.json is in $(cd "$DIR/.." && pwd), so no registration was checked"
else
  real_faults="$(registration_faults "$SETTINGS" "$DIR" 2>&1)"
  real_rc=$?
  if [ "$real_rc" -ne 0 ] && [ "$real_rc" -ne 1 ]; then
    check "the settings file registering the hooks could be read" "$(basename "$SETTINGS") could not be judged (exit $real_rc): $real_faults"
  elif [ "$real_rc" -eq 0 ]; then
    check "every hook is registered once per event and matcher, for exactly the tools its header declares" ok
  else
    check "every hook is registered once per event and matcher, for exactly the tools its header declares" "$(basename "$SETTINGS") says:
$(printf '%s\n' "$real_faults" | sed 's/^/    /')"
  fi
fi

echo "test-hook-coverage: $n_now hook(s) named by no suite, baseline says $n_base."
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
