#!/usr/bin/env bash
# Every suite of this repository can be RUN, as far as the payload write gate is concerned
# (claude-config#3775).
#
# On 2026-11-26 a change to payload/hooks/payload-write-gate.sh went live that refused a plain run
# of 84 of the 410 suites here, and of run-all-tests.sh, from any session with no hold: the gate
# counted every script a suite runs toward a limit of 8 files and refused at the ninth. Its own
# tests passed, because none of them asked the gate about a command anybody really runs, and its
# count over a month of recorded commands had the reading of script files switched off. It was
# found by a builder whose suite had run twice that morning and was refused the third time.
#
# So this asks the gate, as it is in this checkout, about the plain run command of every suite
# found on disk (`bash <path>`, and `bash payload/hooks/run-all-tests.sh`), and fails on a refusal.
# The gate runs; no suite does. Each command is asked twice over the same tree:
#
#   A. from a primary checkout a live watcher could overwrite, the state the gate refuses in
#   B. from a linked worktree on a branch of its own, where a builder works
#
# Both are stand ins under a temporary folder, holding a copy of this checkout's files, with a
# stand in watcher that is a real process with a real command line (L52), so the answer does not
# depend on where this suite is run from or on whether this Mac has a watcher or a hold.
#
# A check never seen to fail could be passing because it reads nothing (L1, L98): before the sweep
# the fixture must refuse a plain write and a suite that links a payload folder, through the same
# asking code the sweep uses, and the sweep must have asked about every suite it listed, this one
# and the Slack drafts gate's among them.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd -P)"
HOOK="$ROOT/payload/hooks/payload-write-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
not_run(){ # not_run <why>
  echo "test-suite-runs-pass-write-gate: $1" >&2
  printf 'SUITE-NOT-RUN %s\n' "$1"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
}

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/suite-runs-write-gate.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; true' EXIT
mkdir -p "$FIX/primary" "$FIX/src/payload" "$FIX/elsewhere" "$FIX/state" "$FIX/self"

# THE REFUSALS THIS CHECK EXPECTS, from a primary checkout (form A) only. One line each: the suite,
# a tab, and why the gate refuses its run there.
#
# Dan allowed this list on 2026-11-26 (claude-config#3775): "3.93.1 List the two as expected
# (Recommended)". The gate stays exactly as strict. These two are the write gate's own suites, and
# they are still run in CI and from a worktree of a builder, where the gate lets them through. A
# refusal of any suite not listed here fails the check, and so does a listed suite that is let
# through, refused in other words, or no longer there, so the list cannot go stale. It is an
# exception list in this check only, never in the gate. Adding a line to it is Dan's to allow.
EXPECTED_REFUSED_A="payload/hooks/test-payload-write-gate-real-path.sh	its test text holds link commands beside a quoted payload path, which the gate places against the primary checkout
payload/hooks/test-payload-write-gate-script-string.sh	its test text holds link commands beside a quoted payload path, which the gate places against the primary checkout"
EXPECTED_WORDS="REFUSED a write to "

expected_reason(){ # expected_reason <form> <command> -> why, when that run is listed for that form
  local entry
  [ "$1" = A ] || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "bash ${entry%%	*}" = "$2" ]; then printf '%s' "${entry#*	}"; return 0; fi
  done <<LIST
$EXPECTED_REFUSED_A
LIST
  return 1
}

# judge <form> <what the form is> <file of answers>
# One line a finding: OK, EXPECTED or BAD, a tab, what was judged, and for BAD a tab and why. It
# counts nothing itself, so it can be run on made up answers below before it is believed about the
# gate's (L1).
judge(){
  local form="$1" what="$2" answers line verdict rest cmdline said why entry
  answers="$(cat "$3" 2>/dev/null || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verdict="${line%%	*}"; rest="${line#*	}"; cmdline="${rest%%	*}"; said="${rest#*	}"
    if why="$(expected_reason "$form" "$cmdline")"; then
      case "$verdict" in
        REFUSED)
          case "$said" in
            *"$EXPECTED_WORDS"*/payload/*) printf 'EXPECTED\tform %s, %s: %s is refused, as listed: %s\n' "$form" "$what" "$cmdline" "$why" ;;
            *) printf 'BAD\tform %s, %s: %s is refused for the reason it is listed for\tthe gate refused it in other words: %s\n' "$form" "$what" "$cmdline" "$said" ;;
          esac ;;
        ALLOWED) printf 'BAD\tform %s, %s: %s is still refused, as the list of expected refusals says\tthe gate lets it through now, so take it off the list\n' "$form" "$what" "$cmdline" ;;
        *) printf 'BAD\tform %s, %s: %s is asked about\tthe gate could not be asked: %s\n' "$form" "$what" "$cmdline" "$said" ;;
      esac
      continue
    fi
    case "$verdict" in
      ALLOWED) printf 'OK\tform %s, %s: %s is let through\n' "$form" "$what" "$cmdline" ;;
      REFUSED) printf 'BAD\tform %s, %s: %s is let through\tthe gate refused it: %s\n' "$form" "$what" "$cmdline" "$said" ;;
      *)       printf 'BAD\tform %s, %s: %s is let through\tthe gate could not be asked: %s\n' "$form" "$what" "$cmdline" "$said" ;;
    esac
  done <<ANSWERS
$answers
ANSWERS
  [ "$form" = A ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "
$answers
" in
      *"	bash ${entry%%	*}	"*) ;;
      *) printf 'BAD\tform %s, %s: bash %s, a listed refusal, is asked about\tno answer came back for it, so the suite is gone or renamed: take it off the list\n' "$form" "$what" "${entry%%	*}" ;;
    esac
  done <<LIST
$EXPECTED_REFUSED_A
LIST
}
bad_in(){ printf '%s\n' "$1" | grep -c '^BAD	' || true; }
# bad_line_has <findings> <text> [<text later on the same line>]
# Whether one BAD finding holds the text, and the second text after it when one is given. The
# findings are read a line at a time from a here document and matched with `case`, never piped into
# a reader that leaves on its first match: under pipefail that kills the writer and the pipeline
# reports a failure that never happened (L183, payload/hooks/test-pipefail-shortcircuit.sh).
bad_line_has(){
  local line
  while IFS= read -r line; do
    case "$line" in $'BAD\t'*"$2"*"${3:-}"*) return 0 ;; esac
  done <<FINDINGS
$1
FINDINGS
  return 1
}
# first_bad <findings> -> the first BAD finding, at most 200 characters of it, or nothing
first_bad(){
  local line
  while IFS= read -r line; do
    case "$line" in $'BAD\t'*) printf '%s\n' "${line:0:200}"; return 0 ;; esac
  done <<FINDINGS
$1
FINDINGS
  return 0
}

echo "the judging, on made up answers"

REAL_PATH=payload/hooks/test-payload-write-gate-real-path.sh
SCRIPT_STRING=payload/hooks/test-payload-write-gate-script-string.sh
SAID_WRITE="claude-sync: REFUSED a write to /somewhere/primary/payload/LESSONS.md."
SAID_COUNT="claude-sync: REFUSED a command that runs more than 8 script files."
answers(){ # answers <file> <verdict for the real path suite> <verdict for the script string suite> [more lines]
  { printf 'ALLOWED\tbash tests/test-one.sh\t\n'
    [ "$2" = none ] || printf '%s\tbash %s\t%s\n' "$2" "$REAL_PATH" "$( [ "$2" = ALLOWED ] || printf '%s' "${4:-$SAID_WRITE}")"
    [ "$3" = none ] || printf '%s\tbash %s\t%s\n' "$3" "$SCRIPT_STRING" "$( [ "$3" = ALLOWED ] || printf '%s' "$SAID_WRITE")"
    printf 'ALLOWED\tbash payload/hooks/run-all-tests.sh\t\n'; } > "$1"
}
answers "$FIX/self/two.txt" REFUSED REFUSED
J="$(judge A "made up" "$FIX/self/two.txt")"
if [ "$(bad_in "$J")" -eq 0 ] && [ "$(printf '%s\n' "$J" | grep -c '^EXPECTED	' || true)" -eq 2 ]; then check "judging: the two listed suites refused from a primary checkout are expected, and nothing fails" ok
else check "judging: the two listed suites refused from a primary checkout are expected, and nothing fails" "$(bad_in "$J") failures: $(first_bad "$J")"; fi
case "$J" in *"is refused, as listed: its test text holds"*) check "judging: each expected refusal is printed with its reason" ok ;;
  *) check "judging: each expected refusal is printed with its reason" "no line gave a reason" ;; esac
answers "$FIX/self/third.txt" REFUSED REFUSED
printf 'REFUSED\tbash tests/test-third.sh\t%s\n' "$SAID_WRITE" >> "$FIX/self/third.txt"
J="$(judge A "made up" "$FIX/self/third.txt")"
if [ "$(bad_in "$J")" -eq 1 ] && bad_line_has "$J" "bash tests/test-third.sh is let through"; then check "judging: a third suite refused fails the check" ok
else check "judging: a third suite refused fails the check" "$(bad_in "$J") failures, where 1 naming tests/test-third.sh was expected"; fi
answers "$FIX/self/allowed.txt" ALLOWED REFUSED
J="$(judge A "made up" "$FIX/self/allowed.txt")"
if [ "$(bad_in "$J")" -eq 1 ] && bad_line_has "$J" "bash $REAL_PATH is still refused" "take it off the list"; then check "judging: a listed suite that is let through fails the check" ok
else check "judging: a listed suite that is let through fails the check" "$(bad_in "$J") failures, where 1 saying to take it off the list was expected"; fi
answers "$FIX/self/words.txt" REFUSED REFUSED "$SAID_COUNT"
J="$(judge A "made up" "$FIX/self/words.txt")"
if [ "$(bad_in "$J")" -eq 1 ] && bad_line_has "$J" "bash $REAL_PATH " "in other words"; then check "judging: a listed suite refused in other words than a write to a payload path fails the check" ok
else check "judging: a listed suite refused in other words than a write to a payload path fails the check" "$(bad_in "$J") failures, where 1 was expected"; fi
answers "$FIX/self/gone.txt" none REFUSED
J="$(judge A "made up" "$FIX/self/gone.txt")"
if [ "$(bad_in "$J")" -eq 1 ] && bad_line_has "$J" "bash $REAL_PATH, a listed refusal" "take it off the list"; then check "judging: a listed suite that was never asked about fails the check" ok
else check "judging: a listed suite that was never asked about fails the check" "$(bad_in "$J") failures, where 1 was expected"; fi
answers "$FIX/self/worktree.txt" REFUSED REFUSED
J="$(judge B "made up" "$FIX/self/worktree.txt")"
if [ "$(bad_in "$J")" -eq 2 ]; then check "judging: the list is for a primary checkout only, so both fail when refused from a worktree" ok
else check "judging: the list is for a primary checkout only, so both fail when refused from a worktree" "$(bad_in "$J") failures, where 2 were expected"; fi
answers "$FIX/self/unasked.txt" REFUSED REFUSED
printf 'UNASKED\tbash tests/test-slow.sh\tthe gate gave no answer in 240 seconds\n' >> "$FIX/self/unasked.txt"
J="$(judge A "made up" "$FIX/self/unasked.txt")"
if [ "$(bad_in "$J")" -eq 1 ] && bad_line_has "$J" "could not be asked"; then check "judging: an ask the gate did not answer fails the check" ok
else check "judging: an ask the gate did not answer fails the check" "$(bad_in "$J") failures, where 1 was expected"; fi

[ -f "$HOOK" ] || not_run "needs payload/hooks/payload-write-gate.sh in the checkout it is in"
command -v git >/dev/null 2>&1 || not_run "needs git, to list the files of this checkout"
command -v python3 >/dev/null 2>&1 || not_run "needs python3"

# The files of this checkout: what git tracks and what is new and not ignored, so a suite written
# a minute ago is asked about before it is committed. Nothing under .claude/, where other
# checkouts of this repository live.
git -C "$ROOT" ls-files -z --cached --others --exclude-standard > "$FIX/files.z" 2>/dev/null \
  || not_run "git could not list the files of $ROOT"
python3 - "$ROOT" "$FIX/files.z" "$FIX/primary" "$FIX/suites.txt" <<'PY' || not_run "the files of this checkout could not be copied into the fixture"
import os, shutil, sys
root, listing, dest, suites = sys.argv[1:5]
names = [n for n in open(listing, "rb").read().decode("utf-8", "surrogateescape").split("\0") if n]
found = []
for n in names:
    if n.startswith(".claude/") or "/.claude/" in n:
        continue
    src = os.path.join(root, n)
    if not os.path.isfile(src) or os.path.islink(src):
        continue
    out = os.path.join(dest, n)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    shutil.copy2(src, out)
    base = n.rsplit("/", 1)[-1]
    if base.startswith("test-") and base.endswith(".sh"):
        found.append(n)
with open(suites, "w") as f:
    f.write("".join(s + "\n" for s in sorted(found)))
PY
LISTED="$(grep -c '' "$FIX/suites.txt" 2>/dev/null || true)"
case "$LISTED" in ''|*[!0-9]*) LISTED=0 ;; esac
[ "$LISTED" -gt 0 ] || not_run "no test-*.sh was found in $ROOT, so nothing would be asked about"

# The two checkouts. The primary one is where the copy is first; its tree is moved into the linked
# worktree for the second sweep, so the fixture holds one copy of the files, never two.
: > "$FIX/src/claude-sync"
git init -q "$FIX/primary" 2>/dev/null
git init -q "$FIX/src" 2>/dev/null
GG(){ git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "${@:2}"; }
GG "$FIX/primary" symbolic-ref HEAD refs/heads/main
GG "$FIX/primary" commit -q --allow-empty -m seed 2>/dev/null
GG "$FIX/primary" worktree add -q -b a-builder-branch "$FIX/worktree" 2>/dev/null
[ -e "$FIX/primary/.git" ] && [ -e "$FIX/src/.git" ] && [ -e "$FIX/worktree/.git" ] \
  || not_run "the fixture checkouts could not be made git checkouts"
[ -f "$FIX/primary/claude-sync" ] && [ -d "$FIX/primary/payload/hooks" ] \
  || not_run "the copy of this checkout holds no claude-sync or no payload/hooks, so the gate would not take it for a checkout"

# The stand in watcher, running from the other clone. It sleeps longer than this suite is allowed
# to run (SUITE_WALL_DEFAULT, a limit lib/suite-deadline.sh sets and not a measurement, is 1200
# seconds), so it cannot die partway and turn every answer after it into allowed; the last check
# below confirms it lived to the end.
HOLD="$FIX/hold"
PIDF="$FIX/watch.pid"
( bash -c 'exec -a "'"$FIX"'/src/claude-sync watch" sleep 1500' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$PIDF" ) </dev/null >/dev/null 2>&1
WPID="$(cat "$PIDF" 2>/dev/null)"
watcher_alive(){ case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in *claude-sync*watch*) return 0 ;; esac; return 1; }
for _ in $(seq 1 200); do watcher_alive && break; done
watcher_alive || not_run "the fixture watcher process could not be started with a readable command line"

unset CLAUDE_CODE_SESSION_ID

# ask <directory> <file of commands, one a line> <file for the answers>
# One line an answer: ALLOWED, REFUSED or UNASKED, a tab, the command, a tab, the first line the
# gate said. Four asks at a time, each with a limit of its own that stops its whole process group.
ask(){
  SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" \
  python3 - "$HOOK" "$1" "$2" "$3" <<'PY'
import json, os, signal, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
hook, cwd, commands, answers = sys.argv[1:5]

def one(command):
    body = json.dumps({"tool_name": "Bash", "session_id": "", "cwd": cwd, "tool_input": {"command": command}})
    p = subprocess.Popen(["bash", hook], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, cwd=cwd, start_new_session=True)
    try:
        out, _ = p.communicate(body.encode(), timeout=240)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return "UNASKED\t%s\tthe gate gave no answer in 240 seconds" % command
    said = out.decode("utf-8", "replace").strip()
    first = said.split("\n", 1)[0]
    if p.returncode == 0 and not said:
        return "ALLOWED\t%s\t" % command
    if p.returncode == 2:
        return "REFUSED\t%s\t%s" % (command, first)
    return "UNASKED\t%s\texit %s, said: %s" % (command, p.returncode, first[:200])

todo = [l.rstrip("\n") for l in open(commands) if l.strip()]
with ThreadPoolExecutor(max_workers=4) as pool:
    done = list(pool.map(one, todo))
with open(answers, "w") as f:
    f.write("".join(d + "\n" for d in done))
PY
}
count(){ grep -c "^$1	" "$2" 2>/dev/null || true; }

# The commands asked about: each suite's plain run, and the whole run's.
sed 's/^/bash /' "$FIX/suites.txt" > "$FIX/commands.txt"
printf 'bash payload/hooks/run-all-tests.sh\n' >> "$FIX/commands.txt"
EXPECTED=$((LISTED + 1))
for known in tests/test-suite-runs-pass-write-gate.sh payload/hooks/test-slack-drafts-only-gate.sh payload/hooks/test-payload-write-gate.sh; do
  if grep -qx "bash $known" "$FIX/commands.txt"; then check "the list of suites holds $known" ok
  else check "the list of suites holds $known" "it does not, so the list is not every suite"; fi
done

# sweep <A or B> <directory> <what it is>
sweep(){
  local form="$1" dir="$2" what="$3" out="$FIX/answers-$1.txt" asked allowed refused unasked line judged expected
  ask "$dir" "$FIX/commands.txt" "$out"
  asked="$(grep -c '' "$out" 2>/dev/null || true)"; allowed="$(count ALLOWED "$out")"
  refused="$(count REFUSED "$out")"; unasked="$(count UNASKED "$out")"
  if [ "${asked:-0}" -eq "$EXPECTED" ]; then check "form $form: all $EXPECTED run commands were asked about" ok
  else check "form $form: all $EXPECTED run commands were asked about" "${asked:-0} answers came back"; fi
  # Judged into a variable first, so the loop is fed by no child this shell never waits for (#2040).
  judged="$(judge "$form" "$what" "$out")"
  expected=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      OK*) pass=$((pass + 1)) ;;
      EXPECTED*) expected=$((expected + 1)); pass=$((pass + 1)); echo "expected refusal: ${line#*	}" ;;
      *) line="${line#*	}"; check "${line%%	*}" "${line#*	}" ;;
    esac
  done <<JUDGED
$judged
JUDGED
  echo "form $form ($what): $EXPECTED asked, ${allowed:-0} let through, ${refused:-0} refused ($expected of them expected), ${unasked:-0} could not be asked"
}

echo "form A: a primary checkout a watcher could overwrite"

# The fixture is only a fixture if this asking code can see a refusal there: a plain write, and a
# stand in suite that links the payload folder, which is what the gate reads a script file for.
printf 'ln -s %s %s\n' "$FIX/primary/payload/hooks" "$FIX/elsewhere/l1" > "$FIX/primary/payload/hooks/control-links-payload.sh"
printf 'echo x > payload/hooks/control-new-file.sh\nbash payload/hooks/control-links-payload.sh\necho hello\n' > "$FIX/controls.txt"
ask "$FIX/primary" "$FIX/controls.txt" "$FIX/controls-A.txt"
if [ "$(sed -n 1p "$FIX/controls-A.txt" | cut -f1)" = REFUSED ]; then check "control, form A: a plain write under payload/ is refused" ok
else check "control, form A: a plain write under payload/ is refused" "the answer was: $(sed -n 1p "$FIX/controls-A.txt")"; fi
if [ "$(sed -n 2p "$FIX/controls-A.txt" | cut -f1)" = REFUSED ]; then check "control, form A: a run of a script file that links the payload folder is refused" ok
else check "control, form A: a run of a script file that links the payload folder is refused" "the answer was: $(sed -n 2p "$FIX/controls-A.txt")"; fi
if [ "$(sed -n 3p "$FIX/controls-A.txt" | cut -f1)" = ALLOWED ]; then check "control, form A: a command that writes nothing is let through" ok
else check "control, form A: a command that writes nothing is let through" "the answer was: $(sed -n 3p "$FIX/controls-A.txt")"; fi
rm -f "$FIX/primary/payload/hooks/control-links-payload.sh"

sweep A "$FIX/primary" "from a primary checkout"

echo "form B: a linked worktree on a branch of its own"

# The same tree, moved, never copied a second time.
moved=ok
for entry in "$FIX/primary"/* "$FIX/primary"/.[!.]*; do
  [ -e "$entry" ] || continue
  case "${entry##*/}" in .git) continue ;; esac
  mv "$entry" "$FIX/worktree/" 2>/dev/null || moved="${entry##*/} could not be moved"
done
[ "$moved" = ok ] && [ -f "$FIX/worktree/claude-sync" ] && [ -d "$FIX/worktree/payload/hooks" ] \
  || not_run "the tree could not be moved into the linked worktree ($moved)"
ask "$FIX/worktree" "$FIX/controls.txt" "$FIX/controls-B.txt"
if [ "$(sed -n 1p "$FIX/controls-B.txt" | cut -f1)" = ALLOWED ]; then check "control, form B: a plain write under payload/ is let through in a worktree of its own" ok
else check "control, form B: a plain write under payload/ is let through in a worktree of its own" "the answer was: $(sed -n 1p "$FIX/controls-B.txt")"; fi

sweep B "$FIX/worktree" "from a linked worktree"

if watcher_alive; then check "the stand in watcher lived to the end of the sweeps" ok
else check "the stand in watcher lived to the end of the sweeps" "it had gone, so answers after that were given with no watcher and prove nothing"; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
