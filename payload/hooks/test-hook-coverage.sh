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
# ---------------------------------------------------------------------------
registration_faults(){ # registration_faults <settings file> <hooks dir> -> one fault per line
  python3 - "$1" "$2" <<'PY'
import glob, json, os, re, sys
settings, hooks_dir = sys.argv[1], sys.argv[2]
events = json.load(open(settings)).get("hooks", {})

def names(cmd):
    return {os.path.basename(t) for t in cmd.split()}

seen = {}
runs = {}  # (event, hook basename) -> matchers
for event, groups in events.items():
    for g in groups:
        matcher = g.get("matcher", "")
        for h in g.get("hooks", []):
            cmd = h.get("command", "")
            key = (event, matcher, cmd, h.get("if", ""))
            seen[key] = seen.get(key, 0) + 1
            for n in names(cmd):
                runs.setdefault((event, n), []).append(matcher)
for (event, matcher, cmd, cond), n in sorted(seen.items()):
    if n > 1:
        print(f"DUPLICATE {event} matcher={matcher!r} {cmd}{' if=' + cond if cond else ''} is registered {n} times")

def matches(matcher, tool):
    if matcher in ("", "*"):
        return True
    # A matcher that is not a valid pattern is its own fault, never scored as a match or a miss (L11).
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error as e:
        print(f"BAD MATCHER {matcher!r} is not a valid pattern ({e}), so what it runs for was not judged")
        return True

header = re.compile(r"Claude Code (PreToolUse|PostToolUse)\(([^)]*)\) hook")
for path in sorted(glob.glob(os.path.join(hooks_dir, "*.sh")) + glob.glob(os.path.join(hooks_dir, "*.py"))):
    base = os.path.basename(path)
    if base.startswith("test-"):
        continue
    with open(path, errors="replace") as f:
        head = "".join(f.readline() for _ in range(8))
    m = header.search(head)
    if not m:
        continue
    event = m.group(1)
    for tool in m.group(2).split("|"):
        if not any(matches(mt, tool) for mt in runs.get((event, base), [])):
            print(f"UNWIRED {base} declares {event}({m.group(2)}) and is not run for {tool}")
PY
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
  {"matcher": "Edit|Write", "hooks": [
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
[ -z "$sound" ] \
  && check "#400 a settings file registering each hook once, where it belongs, reports nothing" ok \
  || check "#400 a settings file registering each hook once, where it belongs, reports nothing" "it answered: [$sound]"

# The real settings: the payload copy inside the checkout, the installed copy once deployed.
SETTINGS=""
if [ -f "$DIR/../settings.hooks.json" ]; then SETTINGS="$DIR/../settings.hooks.json"
elif [ -f "$DIR/../settings.json" ]; then SETTINGS="$DIR/../settings.json"; fi
if [ -z "$SETTINGS" ]; then
  check "the settings file registering the hooks could be read" "neither settings.hooks.json nor settings.json is in $(cd "$DIR/.." && pwd), so no registration was checked"
elif ! real_faults="$(registration_faults "$SETTINGS" "$DIR" 2>&1)"; then
  check "the settings file registering the hooks could be read" "$(basename "$SETTINGS") could not be parsed: $real_faults"
else
  [ -z "$real_faults" ] \
    && check "every hook is registered once per event and matcher, for every tool its header declares" ok \
    || check "every hook is registered once per event and matcher, for every tool its header declares" "$(basename "$SETTINGS") says:
$(printf '%s\n' "$real_faults" | sed 's/^/    /')"
fi

echo "test-hook-coverage: $n_now hook(s) named by no suite, baseline says $n_base."
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
