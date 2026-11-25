#!/usr/bin/env bash
# Tests for slack-drafts-only-gate.sh and its rule, slack_drafts_only_gate.py, the gate that leaves
# sessions only able to save Slack drafts (claude-config#2302): one Python text is read once in a
# judgement, timing the gate's phases changes no verdict, and a module python3 -m runs, a zip
# unpacked, a file a compiler builds or a Python runner runs, what a git checkout, revert, stash,
# worktree, clone or pull writes, and a package spec handed to npx and its kin are each read as
# what they are.
#
# test-slack-drafts-only-gate.sh held every check of the gate, 2,633 of them, until on 2026-11-24 it
# ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners in three runs of four,
# each time stopping the config sync between the two Macs: one piece held against a fixed deadline
# had grown to most of it (L315). Its sections are now six suites, each a run of them in their
# order, dealt by their own measured cost (claude-config#3575): -scripts, -written-files,
# -file-arguments, test-slack-drafts-only-gate.sh itself (the gate as a whole: /nudge, a payload it
# cannot read, its time budget, a crash, its wiring and its cost), -runners and -tools-cache. Every
# check is as it was, and a comment saying "above" or "below" means in whichever of the six holds it.
#
# The world they all run in (the gate under test, the throwaway folder and its judgement cache, the
# result line, and the fixtures one section makes and a section in another suite reads) is
# lib/slack-drafts-gate-harness.sh, the one place each of them takes it from. The helper functions
# are the one thing each holds a copy of, below, because the gate reads functions only where they
# are called.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/slack-drafts-gate-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/slack-drafts-gate-harness.sh is missing, so there is no gate to run and no world to run it in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

# The helpers every case is driven through, copied as they are into each of the six suites: the
# gate knows a shell function only where the text calling it defines it (lib/unknown-program.py,
# #3304), so with these in a sourced file it would read `run_bash "<a command that posts>"` as an
# unknown program running that command, and refuse a plain run of this suite.
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_tool() { run_raw "$(payload "$1" "$2")"; }
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }

# Helpers a section in an earlier suite defines, copied as they are for the same reason.
run_budget() { # run_budget <tick budget> <command>: run_bash under a test run with the step clock
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "$2")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET="$1" bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

echo "slack drafts only: one Python text is read once in a judgement (#3255)"
# Counted, which no load can move (L290), from the line the gate writes to SLACK_GATE_PHASE_LOG: how
# many times it parsed Python, and how many times it read a Python text for the endpoints it names.
# Each judgement starts from an empty cache and counts its steps and not seconds, so a slow runner
# cannot end it first.
#
# Each count is also taken on the copy of the gate that holds nothing (made in
# lib/slack-drafts-gate-harness.sh, and checked in test-slack-drafts-only-gate.sh's cost checks),
# the gate as it was before #3255, where it must come out the other way: a count that reads the same
# on both would be measuring nothing (L1). On the gate before #3255 the script below was parsed 20
# times and read for its endpoints 5 times (test-slack-drafts-only-gate.sh's own run of 2026-11-20,
# when it held this part).
mkdir -p "$T/held"
# held_judged <the wrapper to ask> <name> <command>: judge it cold, leave its phases in
# $T/held/<name>.log and what it said in <name>.out, and print the exit code.
held_judged() {
  rm -f "$T/held/$2.log"
  payload Bash "$(bash_input "$3")" "$T/held" \
    | SLACK_GATE_PHASE_LOG="$T/held/$2.log" SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/held/cold.XXXXXX")" \
      HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1000000000 bash "$1" > "$T/held/$2.out" 2>&1
  echo $?
}
# held_n <name> <phase>: how many times that phase ran in that judgement; nothing where it is not named.
held_n() {
  sed -n 's/^phases: //p' "$T/held/$1.log" 2>/dev/null | tr ';' '\n' | sed -n "s/^ *$2 self .* n \([0-9][0-9]*\)\$/\1/p" | sed -n 1p
}
# The gate's own source run as a program five ways by one script, as this suite runs it some sixty
# times: before #3255 each run parsed its 457,000 characters again for each reading of it.
{
  printf 'python3 %s < /dev/null\n' "$DIR/slack_drafts_only_gate.py"
  printf 'printf x | python3 %s\n' "$DIR/slack_drafts_only_gate.py"
  printf 'out="$(python3 %s < /dev/null)"\n' "$DIR/slack_drafts_only_gate.py"
  printf 'python3 %s < /dev/null > /dev/null 2>&1 || true\n' "$DIR/slack_drafts_only_gate.py"
  printf 'if python3 %s < /dev/null; then :; fi\n' "$DIR/slack_drafts_only_gate.py"
} > "$T/held/runs-gate.sh"
for arm in held unheld; do
  # unheld: the copy lib/slack-drafts-gate-harness.sh makes, which holds nothing.
  if [ "$arm" = held ]; then asked="$HOOK"; else asked="$unheld_made/slack-drafts-only-gate.sh"; fi
  rc="$(held_judged "$asked" "$arm-runs" "bash $T/held/runs-gate.sh")"
  parses="$(held_n "$arm-runs" py_parse)"; marks="$(held_n "$arm-runs" py_marker_read)"
  once=ok
  [ "$rc" = 0 ] || once="a script running the gate's own source five ways was refused (exit $rc): $(head -c 300 "$T/held/$arm-runs.out")"
  if [ "$once" = ok ] && { [ -z "$parses" ] || [ -z "$marks" ]; }; then once="the gate's phases name no py_parse or no py_marker_read ('$parses', '$marks'), so nothing was counted: $(head -c 300 "$T/held/$arm-runs.log" 2>&1)"; fi
  if [ "$arm" = held ]; then
    check "a script running one Python file five ways is allowed, and its parses and readings are counted (#3255)" "$once"
    [ "$once" = ok ] || continue
    # One parse: the gate's source is the one Python text that script runs.
    check "a Python file run five ways by one script is parsed once (#3255)" \
      "$(if [ "$parses" = 1 ]; then echo ok; else echo "the gate's own source was parsed $parses times in one judgement"; fi)"
    # Twice at most: as the program run, and as a module another file imports, whose docstrings
    # are read too.
    check "a Python file run five ways by one script is read for the endpoints it names twice at most (#3255)" \
      "$(if [ "$marks" -le 2 ]; then echo ok; else echo "the gate's own source was read for the endpoints it names $marks times in one judgement"; fi)"
  else
    check "a gate that holds no reading is allowed the same script, and its parses and readings are counted (#3255)" "$once"
    [ "$once" = ok ] || continue
    check "a gate that holds no reading parses that file more than once, so the count of parses can fail (#3255)" \
      "$(if [ "$parses" -gt 1 ]; then echo ok; else echo "it parsed the file $parses times, so that count reads the same whether or not a reading is held"; fi)"
    check "a gate that holds no reading reads that file for endpoints more than twice, so that count can fail (#3255)" \
      "$(if [ "$marks" -gt 2 ]; then echo ok; else echo "it read the file $marks times, so that count reads the same whether or not a reading is held"; fi)"
  fi
done

echo "slack drafts only: timing the gate's phases changes no verdict (claude-config#3170)"

# SLACK_GATE_PHASE_LOG only times: each command below is judged with it and without it, each from an
# empty cache, and the exit code, stdout and stderr the wrapper hands Claude Code must be the same.
# Allowed and refused commands of the kinds the timed phases reach: a script followed, a file
# written and then run, a heredoc, a sourced file, a send.
printf 'curl -X POST https://slack.com/api/chat.postMessage -d text=hi\n' > "$T/phase-send.sh"
printf 'echo fine\n' > "$T/phase-plain.sh"
phase_same=""
phase_unopened=""
phase_unwritten=""
phase_n=0
for c in "bash $T/phase-send.sh" "bash $T/phase-plain.sh" "python3 -c 'print(1)'" \
         "printf 'curl https://hooks.slack.com/services/x\n' > $T/w.sh && bash $T/w.sh" \
         "cat > $T/h.py <<'EOF'
print(2)
EOF
python3 $T/h.py" "bash $DIR/lib/checkout-root.sh $DIR/.." "source $DIR/lib/checkout-root.sh; ls" \
         "curl -s -X POST https://slack.com/api/chat.postMessage -H 'Authorization: Bearer x'"; do
  SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" run_bash "$c"
  plain="$RC|$OUT|$ERR"
  had="$(grep -c '^phases: .*Judge\.line self' "$T/phase-check.log" 2>/dev/null || true)"
  SLACK_GATE_PHASE_LOG="$T/phase-check.log" SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" run_bash "$c"
  [ "$plain" = "$RC|$OUT|$ERR" ] || phase_same="$phase_same; ${c:0:60} answered ${plain:0:120} untimed and $RC|${OUT:0:60}|${ERR:0:60} timed"
  now="$(grep -c '^phases: .*Judge\.line self' "$T/phase-check.log" 2>/dev/null || true)"
  [ "${now:-0}" -eq $(( ${had:-0} + 1 )) ] 2>/dev/null || phase_unwritten="$phase_unwritten; ${c:0:60} (exit $RC) added $(( ${now:-0} - ${had:-0} )) lines"
  # A log the gate cannot open (its folder is not there) times nothing and changes nothing either.
  SLACK_GATE_PHASE_LOG="$T/no-such-folder/phase.log" SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" run_bash "$c"
  [ "$plain" = "$RC|$OUT|$ERR" ] || phase_unopened="$phase_unopened; ${c:0:60} answered ${plain:0:120} untimed and $RC|${OUT:0:60}|${ERR:0:60} with a log it cannot open"
  phase_n=$((phase_n + 1))
done
check "each of $phase_n commands is answered the same with its phases timed as without (#3170)" "${phase_same:-ok}"
if [ -e "$T/no-such-folder" ]; then phase_unopened="$phase_unopened; the gate made the log's missing folder"; fi
check "each of $phase_n commands is answered the same with a phase log the gate cannot open (#3170)" "${phase_unopened:-ok}"
check "each of the $phase_n timed runs wrote one line saying where its time went (#3170)" "${phase_unwritten:-ok}"
# The slow runner's case: a judgement that runs out of its budget is refused the same timed as
# untimed, and still writes its phases line, since that line is wanted most exactly then (#3170).
# The step clock (run_budget, one step) runs it out where the real clock would on a slow runner.
run_budget 1 "bash $T/phase-plain.sh"
oot_plain="$RC|$OUT|$ERR"
SLACK_GATE_PHASE_LOG="$T/phase-oot.log" run_budget 1 "bash $T/phase-plain.sh"
if [ "$oot_plain" != "$RC|$OUT|$ERR" ]; then
  oot="answered ${oot_plain:0:160} untimed and $RC|${OUT:0:80}|${ERR:0:80} timed"
elif [ "$RC" -ne 2 ] || [[ "$ERR" != *"ran out of time"* ]]; then
  oot="not refused for its budget: exit $RC, ${ERR:0:200}"
elif ! grep -q '^phases: ' "$T/phase-oot.log" 2>/dev/null; then
  oot="refused for its budget with no phases line written: $(head -c 200 "$T/phase-oot.log" 2>&1)"
else
  oot=ok
fi
check "a judgement out of its budget is refused the same with phases timed, and writes its phases line (#3170)" "$oot"

# The second round of #2918 cut work no verdict needs, each checked here for what it skips and for
# answering as before: sh_binds stops counting assignments once the count settles it; its patterns
# are compiled only when reached; the gate's reader splits a command into words for cd_target only
# where cd can be spelled; and the reader's shell_split answers as shlex.split does.
cat > "$T/cuts.py" <<'PY'
import importlib.util, os, random, shlex, sys
gate_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
wrong = []
# sh_binds: a name assigned 400 times is settled by the first, so only it is read for quotes.
asked = []
real_quoted = gate.sh_quoted_word_at
gate.sh_quoted_word_at = lambda t, at: asked.append(at) or real_quoted(t, at)
text = "".join("WIDE=%d\n" % i for i in range(400))
if gate.Judge.sh_binds("WIDE", text, 0) is not True or gate.Judge.sh_binds("WIDE", text, 3) is not True:
    wrong.append("sh_binds did not find WIDE assigned")
if len(asked) > 1 + 4:
    wrong.append("sh_binds read %d assignments for quotes to settle two questions that need 5" % len(asked))
asked.clear()
if gate.Judge.sh_binds("WIDE", text, 400) is not False or len(asked) != 400:
    wrong.append("sh_binds with 400 allowed answered wrong or read %d assignments, not all 400" % len(asked))
# A comment and a quoted word are still passed over before the count settles.
if gate.Judge.sh_binds("Q", "# Q=1\necho 'Q=2'\n", 0) is not False or gate.Judge.sh_binds("Q", "# Q=1\nQ=2\n", 0) is not True:
    wrong.append("sh_binds counted a comment or a quoted word, or missed the assignment after them")
gate.sh_quoted_word_at = real_quoted
# The binders pattern is compiled only for a name that reaches it.
seen = []
real_compile = gate.re.compile
gate.re.compile = lambda p, *a: seen.append(p) or real_compile(p, *a)
gate.sh_bind_pattern.cache_clear()
gate.Judge.sh_binds("SETTLED", "SETTLED=1\n", 0)
settled = len(seen)
gate.Judge.sh_binds("LATER", "read -r LATER\n", 0)
gate.re.compile = real_compile
# An assignment is found with no pattern of the name's own (sh_assign_starts), and a text holding no ((
# compiles no arithmetic pattern, so only LATER's binders pattern is compiled (#2918, a third round).
if settled != 0 or len(seen) != 1:
    wrong.append("compiled %d patterns for a name its assignment settles (want 0) and %d in all (want 1)" % (settled, len(seen)))
# cd_target: the gate's reader splits nothing that cannot spell cd, and finds every spelling.
sw = gate.load_reader()
split = []
real_join = sw.join_continuations
sw.join_continuations = lambda t: split.append(t) or real_join(t)
for t, want in (("echo hi there", None), ("git status --short", None), ("cd /tmp", "/tmp"), ("c'd' /a", "/a"),
                ('c""d /b', "/b"), ("c\\d /c", "/c"), ("c\\\nd /e", "/e"), ("if cd x", "x"), ("cd", "~")):
    got = sw.cd_target(t)
    if got != want:
        wrong.append("cd_target(%r) gave %r, not %r" % (t, got, want))
if any(t in ("echo hi there", "git status --short") for t in split):
    wrong.append("the gate's reader split %r for a cd" % split[0])
sw.join_continuations = real_join
# shell_split against shlex.split over texts made of every character either treats specially.
rnd = random.Random(2918)
chars = list("ab cd\t\r\n'\"\\$=-") + ["\x0b", "\x0c", "\x1c", "\x85", "\xa0", " ", "\x00"]
def both(t):
    out = []
    for f in (lambda: shlex.split(t, posix=True), lambda: sw.shell_split(t)):
        try:
            out.append(("ok", f()))
        except ValueError as e:
            out.append(("raised", str(e)))
    return out
for i in range(20000):
    t = "".join(rnd.choice(chars) for _ in range(rnd.randint(0, 10)))
    a, b = both(t)
    if a != b:
        wrong.append("shell_split(%r) gave %r, shlex.split %r" % (t, b, a))
        break
print("; ".join(wrong) or "ok")
PY
cuts="$(python3 -B "$T/cuts.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
check "sh_binds, its patterns, cd_target and shell_split do only the work a verdict needs, and answer as before (#2918)" "$cuts"

# A cold judgement of the claude-sync suite compiled 2,300 patterns for sh_binds, one per name and
# form, 0.15 s (measured 2026-11-15, #2918, a third round). An assignment is now found by str.find,
# and the arithmetic and binder forms are compiled only for a text holding (( or a binder's own word.
# Checked for compiling nothing where none is needed, and for finding the assignments the pattern
# finds, in order, over random texts.
cat > "$T/bindcuts.py" <<'PY'
import importlib.util, random, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
wrong = []
before = gate.sh_bind_pattern.cache_info().misses
answers = [gate.Judge.sh_binds("ROOT", 'ROOT=/x\ncd "$ROOT" && ls\n'),
           gate.Judge.sh_binds("ROOT", 'ROOT=/x\nROOT[1]=y\necho "$ROOT"\n', 1),
           gate.Judge.sh_binds("ROOT", 'echo "$ROOT"\nMYROOT=1\n'),
           gate.Judge.sh_binds("ROOT", "# ROOT=1\nx=ROOT\n")]
if answers != [True, True, False, False]:
    wrong.append("answers %r, not [True, True, False, False]" % answers)
made = gate.sh_bind_pattern.cache_info().misses - before
if made:
    wrong.append("%d patterns compiled for texts holding no (( and no binder's word" % made)
rnd = random.Random(2918)
chars = list("abX_1 =+[]\n#'\"$;(){}\\.") + ["ab", "X", "a.b", "read ", "((", "${"]
for i in range(20000):
    t = "".join(rnd.choice(chars) for _ in range(rnd.randint(0, 30)))
    for name in ("X", "ab", "a.b"):
        want = [m.start() for m in gate.sh_bind_pattern("assign", name).finditer(t)]
        got = list(gate.sh_assign_starts(name, t))
        if want != got:
            wrong.append("sh_assign_starts(%r, %r) gave %r, the pattern %r" % (name, t, got, want))
            break
    if len(wrong) > 2:
        break
# And three readings asked again of the same text are worked out once (#2918, the same round): a
# command's tokens, what a command reading its input is fed, and a continued command joined.
j = gate.Judge(gate.load_reader())
reads = []
real_read = j.sh_tokens_read
j.sh_tokens_read = lambda s: reads.append(s) or real_read(s)
first, again = j.sh_tokens('a "b c" >x'), j.sh_tokens('a "b c" >x')
if first != again or first != [("word", "a"), ("word", '"b c"'), ("op", ">"), ("word", "x")] or len(reads) != 1:
    wrong.append("sh_tokens gave %r then %r, reading the text %d times" % (first, again, len(reads)))
first.append("mine")
if j.sh_tokens('a "b c" >x')[-1] == "mine":
    wrong.append("sh_tokens handed out its own kept list")
whole = "cat <<EOF\nbody\nEOF\necho done\n"
was = gate.Judge.fed.cache_info().hits
if gate.Judge.fed("cat <<EOF", whole) != ("body", True) or gate.Judge.fed("cat <<EOF", whole) != ("body", True) \
        or gate.Judge.fed.cache_info().hits != was + 1:
    wrong.append("fed was not worked out once for a (text, whole) asked twice")
sw = gate.load_reader()
was = sw._joined.cache_info().misses
if sw.join_continuations("a \\\n b 'c\\\nd'") != "a  b 'c\\\nd'" or sw.join_continuations("a \\\n b 'c\\\nd'") != "a  b 'c\\\nd'" \
        or sw._joined.cache_info().misses != was + 1 or sw.join_continuations("plain") != "plain":
    wrong.append("join_continuations was not worked out once for a text asked twice, or joined it wrong")
print("; ".join(wrong) or "ok")
PY
bindcuts="$(python3 -B "$T/bindcuts.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
check "sh_binds compiles a pattern only for a form the text can hold, finds assignments as the pattern does, and tokens, feeds and joins are read once for each text (#2918)" "$bindcuts"

# Since #2912 every command of a text is asked whether it calls a function that evaluates its
# argument (sh_eval_text_reason), and the claude-sync suite's check() is one, so every one of its
# 34,000 commands was cut of its openers and searched once per such function, with a pattern built
# afresh for each: a fifth of what #2912 added to judging that suite (measured 2026-11-15, #2918).
# A command that does not hold one of the names cannot call it, so it is now passed over first, and
# the rest searched with one pattern per set of names. Checked for what it skips, and against the
# reading it replaced over every line of claude-sync and its suite.
cat > "$T/evalcuts.py" <<'PY'
import importlib.util, os, re, sys
gate_path, extra = sys.argv[1], sys.argv[2:]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
sw = gate.load_reader()
j = gate.Judge(sw)
wrong = []
evals = {"check": {2}, "ev": {1}, "hang_wait": {1, 2}, "a.b": {1}}

def before(head, evals):
    """sh_eval_call as #2912 wrote it."""
    if not evals or not any(re.search(r"(?<![\w.:-])" + re.escape(f) + r"(?![\w.:-])", head) for f in evals):
        return None
    toks = j.sh_tokens(j.sw.command_rest(j.sh_strip_openers(head))[0])
    raws, k = [], 0
    while k < len(toks):
        kind, raw = toks[k]
        if kind == "op":
            k += 2 if gate.SH_REDIRECT.fullmatch(raw) else 1
            continue
        raws.append(raw)
        k += 1
    if raws and raws[0] not in evals and raws[0] != "trap" and \
            not any(re.sub(r"""['"]""", "", w) in evals for w in raws):
        return None
    if not raws or raws[0] not in evals:
        return False
    rest = " ".join(raws[1:])
    if any(re.search(r"(?<![\w.:-])" + re.escape(f) + r"(?![\w.:-])", rest) for f in evals):
        return False
    lits = []
    for n in sorted(evals[raws[0]]):
        if n < len(raws):
            lit = j.sh_literal_word(raws[n])
            if lit is None:
                return False
            lits.append(lit)
    return lits

# A command naming none of the functions is searched by no pattern and cut of no openers.
# Both routes to a search are counted: re.search (a pattern built per call) and the pattern for the
# set of names (sh_eval_mention), so taking out the test that comes before either is seen.
searched, stripped = [], []
real_search, real_strip, real_mention = gate.re.search, j.sh_strip_openers, gate.sh_eval_mention
gate.re.search = lambda *a, **k: searched.append(a[0]) or real_search(*a, **k)
gate.sh_eval_mention = lambda names: searched.append(names) or real_mention(names)
j.sh_strip_openers = lambda t: stripped.append(t) or real_strip(t)
j.shell = dict(j.shell, known={"evals": evals})
for head in ("echo hi there", "if git status --short; then", "  ok \"it ran\""):
    if j.sh_eval_call(head, evals) is not None or j.sh_eval_text_reason(head, {}, 0) is not None:
        wrong.append("%r, which names no evaluating function, was read as calling one" % head)
# A command that does name one is still searched, so the counting above is seen to count.
before_call, before_strip = len(searched), len(stripped)
j.sh_eval_call("check 'n' 'true'", evals)
if len(searched) == before_call or len(stripped) == before_strip:
    wrong.append("a command calling check was not searched and cut, so the counts above measure nothing")
del searched[before_call:], stripped[before_strip:]
gate.re.search, j.sh_strip_openers, gate.sh_eval_mention = real_search, real_strip, real_mention
if searched or stripped:
    wrong.append("a command naming no evaluating function was searched %d times and cut of its openers %d times, not 0"
                 % (len(searched), len(stripped)))
heads = ["check 'it runs' '[ -f x ]'", "check \"it runs\" \"[ -f \\\"\\$X\\\" ]\"", "ev 'bash post.sh'", "ev \"$CMD\"",
         "trap 'ev x' EXIT", "echo 'check this'", "printf '%s' \"ev\" > f", "x=check", "if check a 'b'; then",
         "a.b 'echo hi'", "a.bc 'echo'", "-check 'x' 'y'", "check.x 1 2", "hang_wait 'sleep 1' 'true'",
         "check 'n' 'ev y'", "check 'n' 'echo' > out", "{ check 'n' 'true'; }", "! check 'n' 'false'", ""]
for path in extra:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            heads += f.read().split("\n")
    except OSError:
        pass
differ = []
for head in heads:
    for ev in (evals, {"check": {2}}, {}):
        try:
            want = ("ok", before(head, ev))
        except Exception as e:
            want = ("raised", type(e).__name__)
        try:
            got = ("ok", j.sh_eval_call(head, ev))
        except Exception as e:
            got = ("raised", type(e).__name__)
        if got != want:
            differ.append((head, sorted(ev), got, want))
if differ:
    wrong.append("sh_eval_call answered differently for %d of %d commands, first %r" % (len(differ), 3 * len(heads), differ[0]))
if len(heads) < 1000 and extra:
    wrong.append("only %d commands were compared" % len(heads))

# sh_word_end goes past the characters that only carry a word on in one step, not one at a time, and
# ends every word where it did: checked against the reading it replaced from every offset of every line.
def word_end_before(s, i):
    dq, n = False, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and not dq:
            jq = s.find("'", i + 1)
            if jq < 0:
                return n
            i = jq + 1
            continue
        if c == '"':
            dq = not dq
        elif s.startswith("$(", i):
            jq = gate.Judge.sh_close(s, i + 2)
            if jq is None:
                return n
            i = jq
        elif s.startswith("${", i):
            jq = gate.Judge.sh_brace_close(s, i + 2)
            if jq is None:
                jq = s.find("}", i)
            if jq < 0:
                return n
            i = jq
        elif not dq and (c.isspace() or c in ";&|<>()"):
            return i
        i += 1
    return n

taken = [0]
class Counted(str):
    def __getitem__(self, k):
        taken[0] += 1
        return str.__getitem__(self, k)
for word in ("x" * 5000, '"%s"' % ("y z " * 1250), "a=%s$(date)%s" % ("b" * 2500, "c" * 2500)):
    taken[0] = 0
    got = j.sh_word_end(Counted(word + " next"), 0)
    if got != len(word):
        wrong.append("sh_word_end ended %r... at %d, not %d" % (word[:20], got, len(word)))
    if taken[0] > 50:
        wrong.append("sh_word_end took %d characters of a %d character word one at a time" % (taken[0], len(word)))
ends = 0
crafted = ["a b c", "x\x1cy z", "\"a b\" c", "'q r' s", "${x:-it's} y", "a\\ b c", "\"$(echo \")\") x"]
for head in heads + crafted:
    # Every offset of a crafted text; where a word starts, as sh_tokens asks, in the others.
    for i in (range(len(head)) if head in crafted else
              [k for k in range(len(head)) if k == 0 or head[k - 1].isspace()]):
        ends += 1
        if j.sh_word_end(head, i) != word_end_before(head, i):
            wrong.append("sh_word_end(%r, %d) gave %r, before %r" % (head[:60], i, j.sh_word_end(head, i), word_end_before(head, i)))
            break
if ends < 100000 and extra:
    wrong.append("sh_word_end was compared at only %d places" % ends)
print("; ".join(wrong) or "ok")
PY
evalcuts="$(python3 -B "$T/evalcuts.py" "$DIR/slack_drafts_only_gate.py" ${CS:+"$CS"} ${REPO:+"$REPO/tests/test-claude-sync.sh"} 2>&1)"
check "a command naming no function that evaluates its argument is read no further, a word's plain characters are passed in one step, and each answers as before (#2918)" "$evalcuts"

echo "slack drafts only: a module python3 -m runs, a zip unpacked past -x, and what a git checkout writes are read (claude-config#2827)"

# Three ways a file reached a program unread (measured through this wrapper on main at a2490ad,
# 2026-11-12: every shape in each refused list below passed). `python3 -m <module> <files>` read
# neither the module nor the files after it. `unzip a.zip -x n -d sub` was noted as unpacking under
# the folder it runs in, not sub. And a file a git checkout, switch, reset, merge, pull, rebase or
# cherry pick writes was read as it was on disk, since the command does not name it. Each refused
# shape has an allowed twin that differs only in whether the file posts, so a refusal here is the
# file being read and not every such command being refused. Nothing here is run.
M="$T/m2827"
mkdir -p "$M/ppkg" "$M/qpkg" "$M/tools" "$M/lib" "$M/arc"
PY_POST_2827="urllib.request.urlopen('https://slack.com/api/chat.postMessage')"
printf '%s\n' "import urllib.request" "$PY_POST_2827" > "$M/postmod.py"
printf '%s\n' "print('hi')" > "$M/quietmod.py"
printf '%s\n' "import postmod" > "$M/viapost.py"
printf '%s\n' "import quietmod" > "$M/viaquiet.py"
: > "$M/ppkg/__init__.py"
printf '%s\n' "import urllib.request" "$PY_POST_2827" > "$M/ppkg/__main__.py"
: > "$M/qpkg/__init__.py"
printf '%s\n' "print('hi')" > "$M/qpkg/__main__.py"
printf '%s\n' "import urllib.request" "$PY_POST_2827" > "$M/tools/sender.py"
printf '%s\n' "print('hi')" > "$M/tools/quiet.py"
printf '%s\n' "import urllib.request" "$PY_POST_2827" > "$M/lib/libpost.py"
printf '%s\n' "print('hi')" > "$M/lib/libquiet.py"
printf '%s\n' "import runpy, sys" "runpy.run_path(sys.argv[1])" > "$M/runner.py"
printf '%s\n' "import sys" "print(open(sys.argv[1]).read())" > "$M/reader.py"
printf '%s\n' "import urllib.request" "$PY_POST_2827" > "$M/post.py"
printf '%s\n' "print('hi')" > "$M/plain.py"
printf '%s\n' "https://slack.com/api/chat.postMessage" > "$M/hook.txt"
printf '%s\n' '{"a": 1}' > "$M/data.json"
printf '%s\n' "$POST" > "$M/arc/post-run.sh"
printf '%s\n' "echo hello" > "$M/arc/plain-run.sh"
python3 -c 'import sys, zipfile
for out, src, name in ((sys.argv[1], sys.argv[2], "post-run.sh"), (sys.argv[3], sys.argv[4], "plain-run.sh")):
    z = zipfile.ZipFile(out, "w"); z.write(src, name); z.close()' \
  "$M/post.zip" "$M/arc/post-run.sh" "$M/plain.zip" "$M/arc/plain-run.sh"
rm -rf "$M/arc"
run_m() { run_raw "$(payload Bash "$(bash_input "$1")" "$M")"; }

for runs in "python3 -m postmod" "python3 -m viapost" "python3 -m ppkg" "python3 -m tools.sender" \
  "python3 -u -m postmod" "python3 -W ignore -m postmod" "PYTHONPATH=lib python3 -m libpost" \
  "python3 -m runner hook.txt" "python3 -m runner post.py" "python3 -mpostmod" "cd tools && python3 -m sender"; do
  run_m "$runs"
  refused "a module python3 -m runs, and the files handed to it, are read: $runs"
done
for runs in "python3 -m quietmod" "python3 -m viaquiet" "python3 -m qpkg" "python3 -m tools.quiet" \
  "python3 -u -m quietmod" "python3 -W ignore -m quietmod" "PYTHONPATH=lib python3 -m libquiet" \
  "python3 -m reader hook.txt" "python3 -m runner plain.py" "python3 -mquietmod" "cd tools && python3 -m quiet" \
  "python3 -m quietmod post.py" "python3 -m reader post.py" "python3 -m nosuch_2827"; do
  run_m "$runs"
  allowed "a module python3 -m runs that does not post, and cannot run or send what it is handed, passes: $runs"
done
# A module in the standard library or installed is not read, nor are the files handed to it, as for a
# program run by bare name: py_compile and json.tool only read them, and the gate cannot tell which
# installed modules run what they are handed, so reading them would refuse checking any file naming
# an endpoint, the gate's own source among them.
for runs in "python3 -m py_compile post.py" "python3 -m json.tool hook.txt" \
  "python3 -m py_compile $DIR/slack_drafts_only_gate.py"; do
  run_m "$runs"
  allowed "a module from the standard library is handed files it only reads: $runs"
done
run_m "python3 -m ppkg"
says "the refusal names the module python3 -m runs" "python3 -m ppkg"

for runs in "unzip -o post.zip -x nothing -d sub && bash sub/post-run.sh" \
  "unzip -o post.zip -x a b -d sub; bash sub/post-run.sh" "unzip -q post.zip -x nothing -dsub && bash sub/post-run.sh"; do
  run_m "$runs"
  refused "a zip unpacked past -x into the folder -d names is read there: $runs"
done
for runs in "unzip -o plain.zip -x nothing -d sub && bash sub/plain-run.sh" \
  "unzip -o plain.zip -x a b -d sub; bash sub/plain-run.sh" "unzip -o post.zip -x nothing -d sub && bash plain.py"; do
  run_m "$runs"
  allowed "a zip unpacked past -x into the folder -d names, holding nothing that posts, passes: $runs"
done

# A repository whose branch posting changes run.sh to post and adds new.sh, which posts, and whose
# branch quiet changes both to scripts that do not. main tracks posting, so a plain pull merges it.
G="$T/g2827"
git init -q -b main "$G"
printf '%s\n' "echo hello" > "$G/run.sh"
git -C "$G" add run.sh
git -C "$G" -c user.name=t -c user.email=t@example.invalid commit -q -m base
git -C "$G" branch posting
git -C "$G" branch quiet
git -C "$G" checkout -q posting
printf '%s\n' "$POST" > "$G/run.sh"
printf '%s\n' "$POST" > "$G/new.sh"
git -C "$G" add run.sh new.sh
git -C "$G" -c user.name=t -c user.email=t@example.invalid commit -q -m posting
git -C "$G" checkout -q quiet
printf '%s\n' "echo bye" > "$G/run.sh"
printf '%s\n' "echo new" > "$G/new.sh"
git -C "$G" add run.sh new.sh
git -C "$G" -c user.name=t -c user.email=t@example.invalid commit -q -m quiet
git -C "$G" checkout -q main
git -C "$G" config branch.main.remote .
git -C "$G" config branch.main.merge refs/heads/posting
run_g() { run_raw "$(payload Bash "$(bash_input "$1")" "$G")"; }

for ref in posting quiet; do
  for runs in "git checkout @ && bash run.sh" "git checkout -q @; bash new.sh" "git switch @ && bash run.sh" \
    "git switch --detach @ && bash run.sh" "git checkout -b mine @ && bash run.sh" \
    "git reset --hard @ && bash run.sh" "git merge @ && bash run.sh" "git merge --no-edit -m m @ && bash new.sh" \
    "git pull . @ && bash run.sh" "git rebase @ && bash run.sh" "git cherry-pick @ && bash new.sh" \
    "git -C . checkout @ && bash run.sh" "git checkout @ && cd . && bash run.sh"; do
    run_g "${runs//@/$ref}"
    if [ "$ref" = posting ]; then
      refused "a file a git command writes from a branch that posts is read as that branch holds it: ${runs//@/$ref}"
    else
      allowed "a file a git command writes from a branch that does not post passes: ${runs//@/$ref}"
    fi
  done
done
run_g "git pull && bash run.sh"
refused "a pull merges the branch main tracks, which posts, so run.sh is read as that branch holds it"
run_g "git checkout posting && bash run.sh"
says "the refusal says where the text came from" "git checkout posting"
for runs in "git status && bash run.sh" "git fetch . posting && bash run.sh" "git checkout nosuchref_2827 && bash run.sh" \
  "git checkout posting && bash elsewhere.sh" "git log posting && bash run.sh" "git pull . quiet && bash run.sh"; do
  run_g "$runs"
  allowed "a git command that writes nothing that posts, or a ref that names nothing, leaves run.sh as it is on disk: $runs"
done

echo "slack drafts only: a file a compiler builds, one a Python runner runs, and what a revert, stash, worktree, clone or pull writes are read (claude-config#2844)"

# Routes by which a command ran a file the gate never read (measured through this wrapper on main at
# d7d723f, 2026-11-12: every shape in each refused list below passed). A file tsc or esbuild builds
# and the command then runs was read as it was on disk, or not at all where it was not there yet; a
# script or module handed to a runner from the standard library or installed (runpy, pdb, cProfile,
# profile, trace, unittest, pytest) was not read; nor was a file a revert, a stash pop or apply, a new
# linked worktree or a clone writes; and a pull was read against its branch as last fetched. Each
# refused shape has an allowed twin that differs only in whether the file posts. Nothing here is run.
# A refusal here must be the file read, never the gate failing to judge the call: a word it could not
# work out once reached git as a NUL, and the crash refused the call as unjudgeable, which reads the
# same as a refusal to a check that looks only at the exit code.
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
# The runners and builders are read by lib/program-runs.py, a base of the gate's Judge as
# lib/program-writes.py is; a copy of it anywhere else would leave the gate on the old reading.
cat > "$T/program-runs-check.py" <<'PY'
import os, sys
sys.dont_write_bytecode = True  # the gate is carried by the sync: leave no cache beside it (#2919)
sys.path.insert(0, sys.argv[1])
import slack_drafts_only_gate as gate
where = {os.path.basename(getattr(gate.Judge, n).__code__.co_filename) for n in ("py_runner", "note_build", "built_from")}
print("ok" if where == {"program-runs.py"} else "the Judge's runners and builders are from %r, not lib/program-runs.py" % where)
PY
check "the gate reads runners and builds with lib/program-runs.py" "$(python3 "$T/program-runs-check.py" "$DIR" 2>&1)"
C="$T/c2844"
mkdir -p "$C/src" "$C/qsrc" "$C/esrc"
printf '%s\n' 'import { send } from "./lib/send.js";' 'send();' > "$C/src/main.ts"
mkdir -p "$C/src/lib"
printf '%s\n' "export function send() { fetch('https://slack.com/api/chat.postMessage'); }" > "$C/src/lib/send.ts"
printf '%s\n' 'import { say } from "./lib/say.js";' 'say();' > "$C/qsrc/main.ts"
mkdir -p "$C/qsrc/lib"
printf '%s\n' "export function say() { console.log('hi'); }" > "$C/qsrc/lib/say.ts"
printf '%s\n' '{' '  // where the build goes' '  "compilerOptions": { "outDir": "dist", "rootDir": "src", },' '  "include": ["src"]' '}' > "$C/tsconfig.json"
printf '%s\n' '{ "compilerOptions": { "outDir": "qdist" }, "include": ["qsrc/**/*"] }' > "$C/tsconfig.quiet.json"
printf '%s\n' "fetch('https://slack.com/api/chat.postMessage');" > "$C/esrc/post.ts"
printf '%s\n' "console.log('hi');" > "$C/esrc/quiet.ts"
printf '%s\n' "console.log('hi');" > "$C/qsrc/x.js"
run_c() { run_raw "$(payload Bash "$(bash_input "$1")" "$C")"; }

for runs in "tsc && node dist/main.js" "npx tsc && node dist/lib/send.js" "tsc -p . && node dist/main.js" \
  "tsc --outDir out src/main.ts && node out/main.js" "tsc src/main.ts && node src/main.js" \
  "esbuild src/main.ts --bundle --outdir=build && node build/main.js" \
  "esbuild esrc/post.ts esrc/quiet.ts --outdir=build && node build/post.js" "tsc; node dist/main.js" \
  "npx tsc --outDir out src/main.ts && node out/main.js"; do
  run_c "$runs"
  read_refused "a file a compiler builds from a source that posts is read as that source: $runs"
done
for runs in "tsc -p tsconfig.quiet.json && node qdist/main.js" "tsc --outDir out qsrc/main.ts && node out/main.js" \
  "npx tsc --outDir out qsrc/main.ts && node out/main.js" \
  "tsc --outDir qsrc qsrc/main.ts && node qsrc/x.js" \
  "tsc qsrc/main.ts && node qsrc/main.js" "esbuild qsrc/main.ts --bundle --outdir=build && node build/main.js" \
  "esbuild esrc/post.ts esrc/quiet.ts --outdir=build && node build/quiet.js" "tsc && node elsewhere.js" \
  "tsc --noEmit && node dist/main.js"; do
  run_c "$runs"
  allowed "a file a compiler builds from a source that does not post passes: $runs"
done
run_c "tsc && node dist/main.js"
says "the refusal names the source the compiler builds from" "src/main.ts"
# Dan chose on 2026-11-12 (#2844) to stop two false refusals: esbuild's --outfile= was refused as a
# file it may write whatever its source held, and bun build's entries were read as a script bun runs,
# so building code that names an endpoint was refused though nothing ran it. Both are now read by
# what they build, and only where the same command runs it.
for runs in "esbuild esrc/post.ts --bundle --outfile=out.js && node out.js" \
  "npx esbuild esrc/post.ts --outfile=out.js && node out.js" "bun build esrc/post.ts --outfile out.js && node out.js" \
  "bun build esrc/post.ts --outfile=out.js && node out.js" "bun build esrc/post.ts --outdir bout && node bout/post.js" \
  "bun build --compile esrc/post.ts --outfile app2844 && ./app2844" "bun build src/main.ts --outdir bout && node bout/main.js" \
  "bun build esrc/post.ts --outdir bout --entry-naming '[name]-x.[ext]' && node bout/post-x.js"; do
  run_c "$runs"
  read_refused "a file esbuild or bun builds from a source that posts, and the command runs, is read as that source: $runs"
done
for runs in "esbuild esrc/quiet.ts --bundle --outfile=out.js && node out.js" \
  "npx esbuild esrc/quiet.ts --outfile=out.js && node out.js" "bun build esrc/quiet.ts --outfile out.js && node out.js" \
  "bun build esrc/post.ts" "bun build esrc/post.ts --outfile out.js" "bun build esrc/post.ts --outdir bout" \
  "bun build --compile esrc/quiet.ts --outfile app2844 && ./app2844" "bun build qsrc/main.ts --outdir bout && node bout/main.js"; do
  run_c "$runs"
  allowed "a build whose output is quiet, or that nothing in the command runs, passes: $runs"
done
# Two builds of each other's output end, rather than reading each other until the gate crashes.
printf '%s\n' "console.log('x');" > "$C/esrc/x.js"
printf '%s\n' "console.log('y');" > "$C/esrc/y.js"
run_c "esbuild esrc/x.js --outfile=esrc/y.js && esbuild esrc/y.js --outfile=esrc/x.js && node esrc/x.js"
allowed "two builds of each other's quiet output pass, judged rather than crashed"
# tsc --outFile bundles into one file this does not follow, so what it names keeps the mark #2772 gave
# any program's named file: running that bundle is refused as unreadable, however quiet its source.
run_c "tsc --outFile bundle.js qsrc/main.ts && node bundle.js"
read_refused "a bundle tsc --outFile writes is not followed, so it stays unreadable"
says "the refusal says the bundle may be written by tsc" "may be written earlier in this command by tsc"

P="$T/p2844"
mkdir -p "$P/tp" "$P/tq" "$P/tc" "$P/deep/pkg"
PY_POST_2844="urllib.request.urlopen('https://slack.com/api/chat.postMessage')"
printf '%s\n' "import urllib.request" "$PY_POST_2844" > "$P/post.py"
printf '%s\n' "print('hi')" > "$P/plain.py"
printf '%s\n' "import urllib.request" "$PY_POST_2844" > "$P/postmod.py"
printf '%s\n' "print('hi')" > "$P/quietmod.py"
printf '%s\n' "import unittest, postmod" "class T(unittest.TestCase):" "    def test_a(self): pass" > "$P/test_post.py"
printf '%s\n' "import unittest, quietmod" "class T(unittest.TestCase):" "    def test_a(self): pass" > "$P/test_quiet.py"
: > "$P/tp/__init__.py"
: > "$P/tq/__init__.py"
printf '%s\n' "import unittest, postmod" "def test_a(): pass" > "$P/tp/test_send.py"
printf '%s\n' "import unittest, quietmod" "def test_a(): pass" > "$P/tq/test_say.py"
printf '%s\n' "import urllib.request" "$PY_POST_2844" > "$P/tc/conftest.py"
printf '%s\n' "def test_a(): pass" > "$P/tc/test_c.py"
: > "$P/deep/pkg/__init__.py"
printf '%s\n' "import postmod" "def test_a(): pass" > "$P/deep/pkg/check_post.py"
printf '%s\n' "https://slack.com/api/chat.postMessage" > "$P/hook.txt"
run_p() { run_raw "$(payload Bash "$(bash_input "$1")" "$P")"; }

for runs in "python3 -m runpy postmod" "python3 -m pdb post.py" "python3 -m pdb -c continue post.py" \
  "python3 -m pdb -m postmod" "python3 -m cProfile post.py" "python3 -m cProfile -o prof.out -s cumtime post.py" \
  "python3 -m cProfile -m postmod" "python3 -m profile post.py" "python3 -m trace --count post.py" \
  "python3 -m trace --trace --module postmod" "python3 -m unittest test_post" "python3 -m unittest test_post.T.test_a" \
  "python3 -m unittest test_post.py" "python3 -m unittest -v tp.test_send" "python3 -m unittest discover -s tp -t ." \
  "python3 -m unittest discover" "python3 -m unittest" "python3 -m unittest discover -p 'check_*.py' -s deep -t deep" \
  "python3 -m pytest tp" "python3 -m pytest tp/test_send.py::test_a" "pytest tp" "pytest -q -k test_a tp/test_send.py" \
  "pytest tc" "cd tp && pytest" "uv run pytest tp" "python3 -m pytest"; do
  run_p "$runs"
  read_refused "a file a Python runner from the standard library or installed runs is read: $runs"
done
for runs in "python3 -m runpy quietmod" "python3 -m pdb plain.py" "python3 -m pdb -c continue plain.py" \
  "python3 -m pdb -m quietmod" "python3 -m cProfile plain.py" "python3 -m cProfile -o prof.out -s cumtime plain.py" \
  "python3 -m cProfile -m quietmod" "python3 -m profile plain.py" "python3 -m trace --count plain.py" \
  "python3 -m trace --trace --module quietmod" "python3 -m unittest test_quiet" "python3 -m unittest test_quiet.T.test_a" \
  "python3 -m unittest test_quiet.py" "python3 -m unittest discover -s tq -t ." "python3 -m pytest tq" \
  "pytest tq/test_say.py::test_a" "pytest tq" "cd tq && pytest" "python3 -m unittest nosuch_2844" \
  "python3 -m cProfile plain.py hook.txt" "python3 -m timeit 'x = 1'" "python3 -m json.tool hook.txt" \
  "pytest --ignore tp tq" "python3 -m unittest discover -s tq"; do
  run_p "$runs"
  allowed "a file a Python runner runs that does not post passes: $runs"
done
run_p "python3 -m cProfile post.py"
says "the refusal names the runner" "cProfile"
# sqlite3 cannot send a request or run code unless the code turns on extension loading (Dan chose
# this on 2026-11-12, #2844, after a read only Lightroom catalog query was refused): code importing it
# may be handed a file written earlier in the command, whose text cannot be read, as code importing
# json may. The shape below is the one refused that day, its paths shortened.
SQ_READ="import sqlite3, sys
ids = open(sys.argv[1]).read().split()
con = sqlite3.connect('file:' + sys.argv[2] + '?mode=ro&immutable=1', uri=True)
print(len(ids), con.execute('select count(*) from t').fetchone())"
SQ_EXT="import sqlite3, sys
ids = open(sys.argv[1]).read().split()
con = sqlite3.connect(sys.argv[2])
con.enable_load_extension(True)
print(len(ids))"
SQ_SQL_EXT="import sqlite3, sys
ids = open(sys.argv[1]).read().split()
con = sqlite3.connect(sys.argv[2])
con.execute('select load_extension(?)', ('x',))
print(len(ids))"
SQ_POST="import urllib.request, sys
urllib.request.urlopen(open(sys.argv[1]).read().strip())"
SQ_FIRST="sqlite3 -readonly 'file:cat.lrcat?mode=ro' 'select id_local from Adobe_images' > ids.txt"
run_p "$SQ_FIRST && python3 -I -c \"$SQ_READ\" ids.txt other.db"
allowed "code importing sqlite3, handed a file sqlite3 wrote earlier in the command, passes"
for code in "$SQ_EXT" "$SQ_SQL_EXT" "$SQ_POST"; do
  run_p "$SQ_FIRST && python3 -I -c \"$code\" ids.txt other.db"
  read_refused "code that can load an extension or send a request, handed a file written earlier, is refused: ${code:0:60}"
done
# Two false refusals the #2847 builder found on 2026-11-12, which Dan chose to stop (#2844). A script
# importing mod-kit's writes.ts, handed a file naming an endpoint, was refused: the word from inside
# the string '--files-from' read as an import of ', ', and eval, got and chmod written as strings, in
# regular expressions and as an object's keys read as code that runs or writes. And a Python script
# naming an endpoint in a regular expression's pattern, which looks for it and posts nothing.
printf "import { readWrites } from '%s'\nconsole.log(readWrites)\n" "$(cd "$DIR/../mods/mod-kit/hooks" && pwd)/writes.ts" > "$P/usewrites.mjs"
printf '%s\n' "const table = new Set(['--files-from', '--include-from'])" "export const f = () => fetch(process.argv[2])" > "$P/fromfetch.mjs"
printf '%s\n' "const keys = { chmod: 1, run: ['eval'], re: /eval\\s*\\(|require\\(/ }" "console.log(keys)" > "$P/keys.mjs"
printf '%s\n' "const k = { chmod: 1 }" "globalThis['eval'](process.argv[2])" > "$P/subscript.mjs"
run_p "node usewrites.mjs hook.txt"
allowed "a script importing mod-kit's writes.ts, handed a file naming an endpoint, passes"
run_p "node keys.mjs hook.txt"
allowed "words naming a write or eval as keys, strings or a regex literal run nothing"
for runs in "node fromfetch.mjs hook.txt" "node subscript.mjs hook.txt"; do
  run_p "$runs"
  read_refused "a script that fetches, or runs eval by a bracketed name, handed a file naming an endpoint, is refused: $runs"
done
printf '%s\n' "import re, sys" "MARK = re.compile(r'chat[._]postMessage|slack_webhook|hooks\\.slack\\.com')" \
  "print(bool(MARK.search(open(sys.argv[1]).read())))" > "$P/regex_ok.py"
printf '%s\n' "import re, sys" "# page one$(printf '\f')" "# page two" "print(re.findall(pattern='slack_webhook', string=sys.argv[1]))" > "$P/regex_kw.py"
printf '%s\n' "import re, urllib.request" "MARK = re.compile(r'slack_webhook')" "$PY_POST_2844" > "$P/regex_post.py"
printf '%s\n' "import re, sys" "print(re.sub(r'x', 'https://hooks.slack.com/services/T/B/C', sys.argv[1]))" > "$P/regex_repl.py"
for runs in "python3 regex_ok.py hook.txt" "python3 regex_kw.py x"; do
  run_p "$runs"
  allowed "a Python script naming an endpoint only in a regular expression's pattern passes: $runs"
done
for runs in "python3 regex_post.py" "python3 regex_repl.py x"; do
  run_p "$runs"
  read_refused "a Python script naming an endpoint outside a pattern is still refused: $runs"
done
# A project whose pytest config puts its root on the import path (pythonpath) and names its tests
# (testpaths), as PostRoll's does: its tests import the project's own modules, which bare pytest
# finds only through that setting, and an import the gate cannot find is refused as unfollowable.
mkdir -p "$P/pp/lib2844" "$P/pp/tests" "$P/pp/tests2"
printf '%s\n' '[tool.pytest.ini_options]' 'testpaths = ["tests"]' 'pythonpath = ["."]' > "$P/pp/pyproject.toml"
printf '%s\n' "print('hi')" > "$P/pp/lib2844/say.py"
printf '%s\n' "import urllib.request" "$PY_POST_2844" > "$P/pp/lib2844/send.py"
printf '%s\n' "import lib2844.say" "def test_a(): pass" > "$P/pp/tests/test_say.py"
printf '%s\n' "import lib2844.send" "def test_a(): pass" > "$P/pp/tests2/test_send.py"
run_raw "$(payload Bash "$(bash_input "pytest")" "$P/pp")"
allowed "pytest with no paths runs its testpaths, with its pythonpath on the import path, which import nothing that posts"
run_raw "$(payload Bash "$(bash_input "pytest tests2")" "$P/pp")"
read_refused "pytest handed a folder whose tests import, through its pythonpath, a module that posts"

# A repository whose latest commit made run.sh post (so a revert of it leaves the quiet text) and
# whose commit before that made it quiet over a posting one (so a revert of that leaves the posting
# text); a stash holding a run.sh that posts and one holding a run.sh that does not; and a bare remote
# whose main has moved past what the clone last fetched to a run.sh that posts.
R="$T/r2844"
git init -q -b main "$R"
gc() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
printf '%s\n' "$POST" > "$R/run.sh"
gc add run.sh; gc commit -q -m posting
printf '%s\n' "echo quiet" > "$R/run.sh"
gc add run.sh; gc commit -q -m quieted
printf '%s\n' "echo hello" > "$R/other.sh"
gc add other.sh; gc commit -q -m other
QUIETED="$(git -C "$R" rev-parse HEAD~1)"
OTHER="$(git -C "$R" rev-parse HEAD)"
printf '%s\n' "$POST" > "$R/run.sh"
gc stash push -q -m posting
printf '%s\n' "echo stashed" > "$R/run.sh"
gc stash push -q -m quiet
gc branch posted "$QUIETED~1"
run_r() { run_raw "$(payload Bash "$(bash_input "$1")" "$R")"; }

for runs in "git revert --no-edit $QUIETED && bash run.sh" "git revert -n $QUIETED; bash run.sh" \
  "git stash pop stash@{1} && bash run.sh" "git stash apply 1 && bash run.sh" \
  "git worktree add ../w2844 $QUIETED~1 && bash ../w2844/run.sh" \
  "git worktree add -b b2844 ../w2844b $QUIETED~1 && cd ../w2844b && bash run.sh" \
  "git clone -q -b posted . ../k2844 && bash ../k2844/run.sh"; do
  run_r "$runs"
  read_refused "a file a revert, stash, worktree or clone writes from text that posts is read as git holds it: $runs"
done
for runs in "git revert --no-edit $OTHER && bash run.sh" "git stash pop && bash run.sh" "git stash apply stash@{0} && bash run.sh" \
  "git worktree add ../w2844 && bash ../w2844/run.sh" "git worktree add --detach ../w2844 $OTHER && bash ../w2844/other.sh" \
  "git clone -q . ../k2844 && bash ../k2844/run.sh" "git stash list && bash run.sh" "git worktree add ../w2844 && bash run.sh" \
  'for n in a b; do git worktree add -q --detach "wt/$n" HEAD; done; bash run.sh' \
  'git worktree add ../w2844 "$NOPE_2844" && bash ../w2844/run.sh' 'git stash branch b2844 "$NOPE_2844" && bash run.sh'; do
  run_r "$runs"
  allowed "a file a revert, stash, worktree or clone writes from text that does not post passes: $runs"
done
run_r "git clone -q https://example.invalid/r2844.git ../k2844 && bash ../k2844/run.sh"
read_refused "a file a clone of a remote writes is downloaded, so what it holds cannot be read"
says "the refusal names the clone" "git clone"
run_r "git clone -q https://example.invalid/r2844.git ../k2844 && bash run.sh"
allowed "a file outside what a clone writes is read as it is on disk"
run_r "git stash pop stash@{1} && bash run.sh"
says "the refusal says where the text came from" "git stash"

# A pull is read against what it fetches: the remote's main moves on to a run.sh that posts after the
# clone last fetched it, and a second remote's main moves on to one that does not.
B="$T/b2844.git"; B2="$T/b2844q.git"; L="$T/l2844"
git init -q --bare -b main "$B"
git -C "$R" push -q "$B" "$OTHER:refs/heads/main"
git clone -q "$B" "$L" 2>/dev/null
git clone -q "$B" "$T/u2844" 2>/dev/null
printf '%s\n' "$POST" > "$T/u2844/other.sh"
git -C "$T/u2844" -c user.name=t -c user.email=t@example.invalid commit -q -am moved
git -C "$T/u2844" push -q origin main
git clone -q --bare "$B" "$B2" 2>/dev/null
git -C "$B2" update-ref refs/heads/main "$OTHER"
git -C "$L" remote add quiet "$B2"
run_l() { run_raw "$(payload Bash "$(bash_input "$1")" "$L")"; }
L_BEFORE="$(git -C "$L" for-each-ref; ls "$L/.git")"
for runs in "git pull && bash other.sh" "git pull origin main && bash other.sh" "git pull -q --ff-only && bash other.sh" \
  "git pull origin && bash other.sh"; do
  run_l "$runs"
  read_refused "a file a pull brings from the remote, which posts, is read as the remote holds it: $runs"
done
for runs in "git pull quiet main && bash other.sh" "git pull && bash run.sh" "git fetch && bash other.sh"; do
  run_l "$runs"
  allowed "a pull that brings nothing that posts passes: $runs"
done
# A fetch and then a checkout, reset or merge of the branch it fetched (Dan, 2026-11-12, on #2844):
# the branch is read as the fetch leaves it, not as it was last fetched.
for runs in "git fetch && git checkout origin/main && bash other.sh" \
  "git fetch origin && git reset --hard origin/main && bash other.sh" \
  "git fetch -q origin main && git merge origin/main && bash other.sh" \
  "git fetch --all; git switch --detach origin/main && bash other.sh"; do
  run_l "$runs"
  read_refused "a branch a fetch brings, which posts, is read as the fetch leaves it: $runs"
done
for runs in "git fetch quiet && git checkout quiet/main && bash other.sh" "git checkout origin/main && bash other.sh" \
  "git fetch origin && git checkout origin/main && bash run.sh" "git fetch quiet && git checkout origin/main && bash other.sh"; do
  run_l "$runs"
  allowed "a branch fetched quiet, or one no fetch in the command touches, is read as it is held: $runs"
done
# The scratch repository borrows the objects of a repository whose path is not ASCII: its alternates
# file holds that path as the bytes git printed.
git clone -q "$B" "$T/lé2844" 2>/dev/null
git -C "$T/lé2844" reset -q --hard "$OTHER"
git -C "$T/lé2844" update-ref refs/remotes/origin/main "$OTHER"
run_raw "$(payload Bash "$(bash_input "git pull && bash other.sh")" "$T/lé2844")"
read_refused "a pull in a repository whose path is not ASCII is read as its fetch brings it"
L_AFTER="$(git -C "$L" for-each-ref; ls "$L/.git")"
if [ "$L_AFTER" = "$L_BEFORE" ]; then check "every pull and fetch read leaves the repository's refs and files as they were" ok
else check "every pull and fetch read leaves the repository's refs and files as they were" "before: $L_BEFORE, after: $L_AFTER"; fi
# A local branch with a slash in its name is not a remote's: after a fetch it is read as it is held.
git -C "$L" branch local2844/posting origin/main >/dev/null 2>&1
git -C "$T/u2844" push -q "$L" "main:refs/heads/local2844/posting" 2>/dev/null
L_BEFORE="$(git -C "$L" for-each-ref; ls "$L/.git")"
run_l "git fetch && git checkout local2844/posting && bash other.sh"
read_refused "a local branch with a slash in its name, which posts, is read as it is held after a fetch"
run_l "git fetch && git revert --no-edit origin/main && bash other.sh"
allowed "a revert of a fetched branch reads what its parent held (quiet), judged rather than crashed"
run_l "git fetch && git checkout local2844/quiet && bash other.sh"
allowed "a local branch name that holds nothing is left as it is on disk after a fetch"
L_AFTER="$(git -C "$L" for-each-ref; ls "$L/.git")"
if [ "$L_AFTER" = "$L_BEFORE" ]; then check "a pull read leaves the repository's refs and files as they were" ok
else check "a pull read leaves the repository's refs and files as they were" "before: $L_BEFORE, after: $L_AFTER"; fi

echo "slack drafts only: a package spec handed to npx, npm exec, pnpm dlx, yarn dlx or bunx is a package, not a file (claude-config#2865)"

# On 2026-11-12 (about 7:45 PM ET, the personal MacBook) this exact call was refused: `claude mcp add`
# names the package spec after its --, so the spec was marked as a file claude may write, and npx's
# `@mskalski/lightroom-mcp@0.26.0` was read as a path (it holds a /) to a script that cannot be read.
# Measured through this wrapper on main at 3ad6286: the first command below was refused, and the bare
# package handed an endpoint or a file naming one, and npm exec, pnpm dlx, yarn dlx and bunx handed one,
# all passed. A package is code the gate does not read and counts as able to act, as an imported one
# does (#2844), so it is refused where it is handed an endpoint, as a script that imports one is.
P="$T/p2865"
mkdir -p "$P/@acme"
printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$P/msg.json"
printf '%s\n' '{"text": "hi"}' > "$P/quiet.json"
run_p() { run_raw "$(payload Bash "$(bash_input "$1")" "$P")"; }
run_p 'claude mcp add --scope user lightroom -e LIGHTROOM_MCP_TOOLSETS=develop -- npx -y @mskalski/lightroom-mcp@0.26.0 | tail -3; npx -y @mskalski/lightroom-mcp@0.26.0 install-plugin | tail -5; ls -d "$HOME/Library/Application Support/Adobe/Lightroom/Modules/"*'
allowed "the call refused on 2026-11-12: claude mcp add, then npx running the package it registered"
for runs in "claude mcp add lr -- npx -y @acme/tool@1.2.0 && npx -y @acme/tool@1.2.0 quiet.json" \
  "claude mcp add-json lr '{\"command\":\"npx\"}' && npx @acme/tool@latest" "claude mcp add lr -- bash quiet.sh && bash quiet.sh" \
  "npm view @acme/tool@1.2.0 version && npx -y @acme/tool@1.2.0 install" "npx -y @acme/tool@^1.2 quiet.json" \
  "npm exec -- @acme/tool@1 install" "npm x -y tool@2.0.0 quiet.json" "pnpm dlx @acme/tool@1.2.0 serve" \
  "yarn dlx tool@1.2.0 --help" "bunx @acme/tool@1.2.0 init" "pnpx tool --version" "npx cowsay hi"; do
  printf '%s\n' 'echo quiet' > "$P/quiet.sh"
  run_p "$runs"
  allowed "a package spec run as a package, handed nothing naming an endpoint: $runs"
done
# Judged as a package, as an import of one is: handed an endpoint, or a file naming one, it is refused,
# by whichever launcher runs it, and after claude mcp add as without it.
for runs in "npx -y @acme/tool@1.2.0 msg.json" "npx tool msg.json" "npx tool --url https://hooks.slack.com/services/T0/B0/x" \
  "npx @acme/tool --method chat.postMessage" "npm exec -- @acme/tool@1 msg.json" "npm x tool@2 msg.json" \
  "pnpm dlx @acme/tool@1.2.0 msg.json" "yarn dlx tool msg.json" "bunx @acme/tool@1.2.0 msg.json" "pnpx tool msg.json" \
  "claude mcp add lr -- npx -y @acme/tool@1.2.0 && npx -y @acme/tool@1.2.0 msg.json"; do
  run_p "$runs"
  read_refused "a package spec handed an endpoint is judged as a package, as an import of one is: $runs"
done
run_p "npx -y @acme/tool@1.2.0 msg.json"
says "the refusal names the package and what it is handed" "the package @acme/tool@1.2.0, run by npx,"
run_p "claude mcp add lr -- npx -y @acme/tool@1.2.0 && npx -y @acme/tool@1.2.0 msg.json"
says "after claude mcp add the package is refused for what it is handed, not as a file claude wrote" "run by npx,"
# Each file a package is handed is judged by its own text, as a data file is, and one another program
# only may have rewritten by what is on disk: reading test files as scripts newly refused the formatter
# then test run below in the 14 day replay (2026-11-12, NurseDex), where prettier's rewrite cannot be read.
printf '%s\n' 'import { it } from "vitest";' 'it("adds", () => {});' > "$P/quiet.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'it("posts", () => fetch("https://slack.com/api/chat.postMessage"));' > "$P/post.test.ts"
run_p "npx prettier --write quiet.test.ts >/dev/null && npx vitest run quiet.test.ts"
allowed "a test file a formatter may rewrite, then handed to a test runner, is read as it is on disk"
run_p "npx prettier --write post.test.ts >/dev/null && npx vitest run post.test.ts"
read_refused "a test file naming an endpoint, handed to a package that runs it, is refused"
# A program the gate reads by its own name, named with a version, is read as that program: tsx@4 runs
# a script whose imports are followed, so a quiet script importing a module that posts is refused.
mkdir -p "$P/vsrc"
printf '%s\n' 'import { post } from "./slack";' 'post("hi");' > "$P/vsrc/main.ts"
printf '%s\n' 'export const post = (t: string) => fetch("https://slack.com/api/chat.postMessage", { body: t });' > "$P/vsrc/slack.ts"
for runs in "npx tsx@4 vsrc/main.ts" "npm exec -- tsx@4.7.0 vsrc/main.ts" "bunx bash@5 -c 'curl https://hooks.slack.com/services/T0/B0/x'"; do
  run_p "$runs"
  read_refused "a program read by its name, given a version, is still read as that program: $runs"
done
# A compiler run as a package still builds and runs nothing it is handed (#2844).
run_p "npx tsc@5 --noEmit post.test.ts"
allowed "a versioned compiler is still read by what it builds, not as a package handed a file"
# A file is still a file. A path (./x.js), and a spec naming a file this command wrote, or one on disk,
# are read as before, so a script written and run in one command is still judged by what was written.
for runs in "sometool x.js && npx ./x.js" "sometool x.js && npm exec -- ./x.js" \
  "printf '%s\\n' 'curl https://hooks.slack.com/services/T0/B0/x' > x.js && npx ./x.js" \
  "printf '%s\\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > @acme/tool && npx @acme/tool"; do
  run_p "$runs"
  read_refused "a file written earlier in the command and run through a launcher is still read as a file: $runs"
done
run_p "sometool x.js && npx ./x.js"
says "a file a program may have written is still unreadable" "may be written earlier in this command by sometool"
printf '%s\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > "$P/@acme/ondisk"
run_p "npx @acme/ondisk"
read_refused "a package shaped spec naming a script on disk is read as that script"
# claude's other commands are not settings changes: one that names a file may still have written it.
run_p "claude -p 'tidy' x.js && npx ./x.js"
read_refused "claude run on a prompt naming a file may write it, so running that file is still refused"

echo
sdg_harness_result
