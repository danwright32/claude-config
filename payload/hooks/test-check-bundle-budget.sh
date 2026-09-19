#!/usr/bin/env bash
# Tests for check-bundle-budget.sh and its measurer lib/bundle-budget.py (claude-config#432).
#
# Drives the REAL hook with a payload on stdin against fixture repositories built here, each with a
# fake build tree of chunks whose sizes are known. Chunk bytes come from os.urandom so gzip cannot
# shrink them and a planted chunk weighs what it says. The record is pointed at this run's own
# scratch directory through BUNDLE_BUDGET_STATE_DIR, so nothing is ever written under the real home.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-bundle-budget.sh"
MEASURER="$DIR/lib/bundle-budget.py"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.bundlebudget.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

[ -f "$MEASURER" ] || { echo "FAIL: measurer missing at $MEASURER"; exit 1; }

pass=0
fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

# --- fixtures -----------------------------------------------------------------------------------

# A repository with an origin remote and one commit, at $1.
mk_repo(){
  local root="$1"
  mkdir -p "$root"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    echo baseline > README.md
    git -c user.name=t -c user.email=t@t add README.md
    git -c user.name=t -c user.email=t@t commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin main
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}

# Write a chunk of $3 incompressible bytes at $1/$2, with its mtime set $4 ahead of (or, when
# negative, behind) HEAD's commit time, in whole seconds, so freshness never depends on how fast this suite runs.
chunk(){  # repo relpath bytes offset
  local repo="$1" rel="$2" bytes="$3" offset="$4" head_time
  head_time="$(git -C "$repo" log -1 --format=%ct)"
  mkdir -p "$repo/$(dirname "$rel")"
  BB_PATH="$repo/$rel" BB_BYTES="$bytes" BB_T="$((head_time + offset))" python3 -c '
import os
p = os.environ["BB_PATH"]
with open(p, "wb") as fh:
    fh.write(os.urandom(int(os.environ["BB_BYTES"])))
t = int(os.environ["BB_T"])
os.utime(p, (t, t))
'
}

STATE="$WORKDIR/state"
OUT=""; ERR=""; RC=0
run_hook(){  # cwd command
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  OUT="$(printf '%s' "$p" | BUNDLE_BUDGET_STATE_DIR="$STATE" bash "$HOOK" 2>"$WORKDIR/err")"; RC=$?
  ERR="$(cat "$WORKDIR/err")"
}
want_rc(){ if [ "$RC" = "$1" ]; then ok; else bad "$2: expected exit $1, got $RC (stdout: $OUT) (stderr: $ERR)"; fi }
says(){ case "$OUT$ERR" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
want_says(){ if says "$1"; then ok; else bad "$2: did not say [$1]; stdout: $OUT; stderr: $ERR"; fi }
want_silent_on(){ if says "$1"; then bad "$2: wrongly said [$1]"; else ok; fi }

# The one record a repository has, read the way the measurer writes it.
record_total(){  # repo -> the total: line's number, or empty
  local remote f
  remote="$(git -C "$1" remote get-url origin)"
  f="$STATE/$(BB_R="$remote" python3 -c 'import hashlib,os; print(hashlib.sha256(os.environ["BB_R"].encode()).hexdigest())').txt"
  [ -f "$f" ] && sed -n 's/^total: *//p' "$f"
}
records(){ find "$STATE" -name '*.txt' 2>/dev/null | wc -l | tr -d ' '; }

# --- no build output: one skip line, nothing recorded -------------------------------------------
W="$(mk_repo "$WORKDIR/none")"
run_hook "$W" "git push"
want_rc 0 "no build output lets the push through"
want_says "no client build output" "no build output says what it could not measure"
want_says "Run the build before pushing" "and says the build has to have run"
[ "$(records)" = "0" ] && ok || bad "no build output must record nothing"

# --- an unrecognised shape is refused by name, not guessed at -----------------------------------
W="$(mk_repo "$WORKDIR/cra")"
chunk "$W" "build/static/js/main.js" 40000 60
run_hook "$W" "git push"
want_rc 0 "an unknown build shape lets the push through"
want_says "build/ (Create React App" "the unknown shape is named"
want_says "not a build shape this guard reads" "and refused rather than measured"
want_silent_on "first measurement" "an unknown shape is never recorded as a budget"

W="$(mk_repo "$WORKDIR/dist-bare")"
chunk "$W" "dist/index.js" 40000 60
run_hook "$W" "git push"
want_rc 0 "a dist/ that is not a Vite build lets the push through"
want_says "dist/ with no assets/*.js" "a bare dist/ is named as not the Vite shape"

# --- first measurement records and passes, saying so --------------------------------------------
W="$(mk_repo "$WORKDIR/next")"
chunk "$W" ".next/static/chunks/main-abc.js" 120000 60
chunk "$W" ".next/static/chunks/app/page-def.js" 60000 60
chunk "$W" ".next/static/chunks/styles.css" 50000 60     # not a chunk this measures
run_hook "$W" "git push"
want_rc 0 "the first measurement passes"
want_says "first measurement" "the first measurement says it is one"
want_says ".next/static/chunks" "and names the shape it read"
want_says "2 chunks" "and counts only the js chunks, not the css beside them"
first="$(record_total "$W")"
[ -n "$first" ] && ok || bad "the first measurement must write a total: line"
# Incompressible bytes gzip to a little MORE than raw, so the total sits just above 180,000.
if [ -n "$first" ] && [ "$first" -ge 180000 ] && [ "$first" -le 181000 ]; then ok; else bad "recorded total should be about 180,000 for two incompressible chunks, got '$first'"; fi

# --- growth inside the margin passes and leaves the record where it was -------------------------
chunk "$W" ".next/static/chunks/small-ghi.js" 3000 60     # +1.7%, under 10 KB
run_hook "$W" "git push"
want_rc 0 "growth inside the margin passes"
want_says "inside the margin" "and says the growth was inside the margin"
[ "$(record_total "$W")" = "$first" ] && ok || bad "growth inside the margin must not move the record (was $first, now $(record_total "$W"))"

# --- the POSITIVE CONTROL: a planted dependency past both margins fails and names the culprits --
chunk "$W" ".next/static/chunks/luxon-jkl.js" 24000 60    # about Luxon's gzipped weight
run_hook "$W" "git push"
want_rc 2 "growth past both margins blocks the push"
want_says "PUSH BLOCKED" "the refusal is a refusal"
want_says "luxon-jkl.js" "the refusal names the planted chunk"
want_says "main-abc.js" "and the largest existing chunk"
want_says "five largest" "as the five largest"
want_says "ACCEPT_BUNDLE_GROWTH=1" "and offers the acceptance hatch"
want_says "explain to the user" "and tells the reader to explain before overriding"
want_says "$(printf '%s' "$first" | sed 's/\([0-9]\)\([0-9]\{3\}\)$/\1,\2/')" "and names the recorded total it grew from"
[ "$(record_total "$W")" = "$first" ] && ok || bad "a refused push must not move the record"

# Both margins must be exceeded, not one: a large bundle growing by a lot of bytes but a small
# share passes, and a tiny bundle growing by a large share but few bytes passes.
W2="$(mk_repo "$WORKDIR/big")"
chunk "$W2" ".next/static/chunks/big.js" 900000 60
run_hook "$W2" "git push"
chunk "$W2" ".next/static/chunks/added.js" 15000 60       # 15 KB but +1.7%
run_hook "$W2" "git push"
want_rc 0 "over the absolute margin but under the percentage passes"
W3="$(mk_repo "$WORKDIR/tiny")"
chunk "$W3" ".next/static/chunks/tiny.js" 20000 60
run_hook "$W3" "git push"
chunk "$W3" ".next/static/chunks/added.js" 5000 60        # +25% but 5 KB
run_hook "$W3" "git push"
want_rc 0 "over the percentage but under the absolute margin passes"

# --- the acceptance hatch records the new total and says so ------------------------------------
run_hook "$W" "ACCEPT_BUNDLE_GROWTH=1 git push"
want_rc 0 "accepted growth passes"
want_says "accepted growth" "and says it was accepted"
accepted="$(record_total "$W")"
if [ -n "$accepted" ] && [ "$accepted" -gt "$first" ]; then ok; else bad "acceptance must raise the record (was $first, now '$accepted')"; fi
run_hook "$W" "git push"
want_rc 0 "the same bundle passes against the accepted record"
want_says "unchanged" "and reads as unchanged"

# --- the skip hatch judges nothing and records nothing ------------------------------------------
chunk "$W" ".next/static/chunks/more-mno.js" 30000 60
run_hook "$W" "SKIP_BUNDLE_BUDGET_CHECK=1 git push"
want_rc 0 "the skip hatch lets the push through"
[ -z "$OUT$ERR" ] && ok || bad "the skip hatch says nothing: $OUT $ERR"
[ "$(record_total "$W")" = "$accepted" ] && ok || bad "the skip hatch must not move the record"
run_hook "$W" "git push"
want_rc 2 "the growth the skip let past is still there for the next push"

# --- a shrink lowers the record -----------------------------------------------------------------
rm "$W/.next/static/chunks/more-mno.js" "$W/.next/static/chunks/luxon-jkl.js"
run_hook "$W" "git push"
want_rc 0 "a smaller bundle passes"
want_says "shrank" "and says it shrank"
lowered="$(record_total "$W")"
if [ -n "$lowered" ] && [ "$lowered" -lt "$accepted" ]; then ok; else bad "a shrink must lower the record (was $accepted, now '$lowered')"; fi

# --- a stale build is reported and not judged ---------------------------------------------------
W="$(mk_repo "$WORKDIR/stale")"
chunk "$W" ".next/static/chunks/main.js" 100000 60
run_hook "$W" "git push"                                   # records 100 KB
chunk "$W" ".next/static/chunks/main.js" 300000 -60        # tripled, but older than HEAD
run_hook "$W" "git push"
want_rc 0 "a stale build does not block"
want_says "is stale" "a stale build is called stale"
want_says "nothing was judged" "and says nothing was judged"
want_silent_on "PUSH BLOCKED" "a stale build is never judged as growth"
if [ "$(record_total "$W")" -lt 110000 ]; then ok; else bad "a stale build must not move the record"; fi
# The control for the stale case: the SAME tripled chunk, fresh, is caught.
chunk "$W" ".next/static/chunks/main.js" 300000 60
run_hook "$W" "git push"
want_rc 2 "the same growth on a fresh build is caught"

# --- the OpenNext copy is the Next shape, and two copies are never summed -------------------------
W="$(mk_repo "$WORKDIR/opennext")"
chunk "$W" ".open-next/assets/_next/static/chunks/main.js" 100000 60
run_hook "$W" "git push"
want_rc 0 "the OpenNext output is read"
want_says ".open-next/assets/_next/static/chunks" "and named as the source"
on_total="$(record_total "$W")"
W="$(mk_repo "$WORKDIR/both")"
chunk "$W" ".next/static/chunks/main.js" 100000 60
chunk "$W" ".open-next/assets/_next/static/chunks/main.js" 100000 120
run_hook "$W" "git push"
both_total="$(record_total "$W")"
[ "$both_total" = "$on_total" ] && ok || bad "two copies of one bundle must weigh as one (one copy $on_total, both present $both_total)"
want_says ".open-next/" "the newer of the two copies is the one read"

# --- Vite -------------------------------------------------------------------------------------------
W="$(mk_repo "$WORKDIR/vite")"
chunk "$W" "dist/assets/index-a1b2.js" 80000 60
chunk "$W" "dist/assets/index-a1b2.css" 9000 60
run_hook "$W" "git push"
want_rc 0 "a Vite build records"
want_says "dist/assets" "and names the Vite shape"
want_says "1 chunks" "counting the js only"
chunk "$W" "dist/assets/vendor-c3d4.js" 30000 60
run_hook "$W" "git push"
want_rc 2 "a planted Vite dependency past both margins blocks"
want_says "vendor-c3d4.js" "and is named"

# --- the hook finds the repo the way its siblings do ----------------------------------------------
E2E="$WORKDIR/elsewhere"; mkdir -p "$E2E"
W="$(mk_repo "$WORKDIR/cd")"
chunk "$W" ".next/static/chunks/main.js" 100000 60
run_hook "$E2E" "cd $W && git push"
want_rc 0 "cd-then-push from another cwd is measured"
want_says "first measurement" "and records"
run_hook "$E2E" "git status"
[ -z "$OUT$ERR" ] && ok || bad "a command that is not a push says nothing: $OUT $ERR"

# --- no origin remote: say so, judge nothing ----------------------------------------------------
W="$WORKDIR/noremote/work"; mkdir -p "$W"
( cd "$W" && git init -q -b main && echo x > a && git -c user.name=t -c user.email=t@t add a && git -c user.name=t -c user.email=t@t commit -qm init ) >/dev/null 2>&1
chunk "$W" ".next/static/chunks/main.js" 100000 60
run_hook "$W" "git push"
want_rc 0 "no origin remote lets the push through"
want_says "no origin remote" "and says the budget has nothing to be keyed on"

# --- an unreadable record is named, not read as zero --------------------------------------------
W="$(mk_repo "$WORKDIR/corrupt")"
chunk "$W" ".next/static/chunks/main.js" 100000 60
run_hook "$W" "git push"
remote="$(git -C "$W" remote get-url origin)"
f="$STATE/$(BB_R="$remote" python3 -c 'import hashlib,os; print(hashlib.sha256(os.environ["BB_R"].encode()).hexdigest())').txt"
printf 'total: not-a-number\n' > "$f"
run_hook "$W" "git push"
want_rc 0 "an unreadable record does not block"
want_says "could not be read" "an unreadable record is reported"
want_says "$f" "by path"
want_silent_on "first measurement" "and is not silently replaced"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
