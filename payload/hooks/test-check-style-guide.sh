#!/usr/bin/env bash
# Tests for the em-dash/en-dash/emoji rule check-style-guide.sh enforces at push. The rule lives in
# lib/style-scan.py, shared with the style-check mod (claude-config#609), and is driven directly,
# so the suite exercises the real code, not a re-implementation.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-style-guide.sh"

# Anything this run makes goes in a directory of its own, never beside this file
# (claude-config#180): a fixed path in payload/hooks is shared by every run on the machine, and a
# run killed part way leaves a stray file in the tree the sync mirrors.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.styleguide.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

# The detector is ONE shared script, lib/style-scan.py, which this hook and the style-check mod
# both run (claude-config#609). It is driven directly here, so the suite tests the rule itself and
# not a re-implementation of it (L52). It used to be lifted out of the hook with awk.
SCANNER="$DIR/lib/style-scan.py"
[ -f "$SCANNER" ] || { echo "FAIL: lib/style-scan.py is missing, so there is no detector to test"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

detect() {
  printf '%s' "$1" | python3 "$SCANNER"
}

pass=0
fail=0
want_flag() {
  local desc="$1" diff="$2"
  local out
  out="$(detect "$diff")"
  if [ -n "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected a finding: $desc"; fi
}
want_clean() {
  local desc="$1" diff="$2"
  local out
  out="$(detect "$diff")"
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected no finding: $desc -> got: $out"; fi
}

# --- em dash / en dash on a newly added line ---
want_flag "em dash in new copy" "+++ b/app/copy.ts
+const label = \"Loading — please wait\";"

want_flag "en dash in new copy" "+++ b/app/copy.ts
+const range = \"9–5\";"

# --- emoji on a newly added line ---
want_flag "emoji in new copy" "+++ b/app/alert.ts
+const msg = \"Deploy succeeded 🎉\";"

# --- removed lines with a dash must NOT flag (only additions matter) ---
want_clean "dash only on a removed line" "+++ b/app/copy.ts
-const label = \"Loading — please wait\";
+const label = \"Loading, please wait\";"

# --- ordinary hyphenated words must NOT flag (ASCII hyphen, not em/en dash) ---
want_clean "ascii hyphen in compound word" "+++ b/app/copy.ts
+const label = \"self-aware, well-known\";"

# --- untracked new-file block format must also be scanned ---
want_flag "em dash in a brand-new untracked file" "--- NEW FILE: app/new.ts ---
+export const x = \"a — b\";"

want_clean "plain new file with no violations" "--- NEW FILE: app/new.ts ---
+export const x = 1;"


# --- one rule, shared with the style-check mod (claude-config#609) ---
# The hook must carry no copy of the rule: a second copy is the thing that drifts (L370, L613).
if grep -q 'dash_re\|emoji_re\|U0001F300' "$HOOK"; then
  fail=$((fail+1)); echo "FAIL: check-style-guide.sh still holds its own copy of the character rule"
else pass=$((pass+1)); fi
if grep -q 'lib/style-scan.py' "$HOOK"; then pass=$((pass+1));
else fail=$((fail+1)); echo "FAIL: check-style-guide.sh does not run lib/style-scan.py"; fi

# --plain reads text as written (no diff markers), names each offending line by number, and exits
# 1 on a finding, 0 when clean: the mod refuses on the exit code and quotes the lines.
uesc() { python3 -c 'import sys,codecs; sys.stdout.write(codecs.decode(sys.argv[1], "unicode_escape"))' "$1"; }
plain() {  # $1 text, then any extra flags -> PLAIN_OUT, PLAIN_CODE
  local t="$1"; shift
  PLAIN_OUT="$(printf '%s' "$t" | python3 "$SCANNER" --plain "$@")"; PLAIN_CODE=$?
}
want_plain() {  # $1 expected code, $2 description
  if [ "$PLAIN_CODE" = "$1" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: expected exit $1, got $PLAIN_CODE ($PLAIN_OUT)"; fi
}
plain "$(printf 'fine\nalso %s fine\n' "$(uesc 'x\u2014y')")"
want_plain 1 "--plain flags a dash on line 2"
case "$PLAIN_OUT" in *"line 2:"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: --plain names the line: got $PLAIN_OUT" ;; esac
plain "$(printf '+++ b/x\n-%s\n' "$(uesc '\u2014')")"
want_plain 1 "--plain reads every line, even one that looks like a removed diff line"
plain "nothing here, self-aware and well-known"
want_plain 0 "--plain is clean on hyphens"
[ -z "$PLAIN_OUT" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: a clean --plain run prints nothing"; }
git init -q "$WORKDIR/a-repo"
plain "$(uesc 'a \u2014 b')" --path "$WORKDIR/a-repo/CLAUDE.md"
want_plain 0 "--plain honours the same excluded paths as the push (the top level CLAUDE.md)"
mkdir -p "$WORKDIR/a-repo/sub"
plain "$(uesc 'a \u2014 b')" --path "$WORKDIR/a-repo/sub/CLAUDE.md"
want_plain 1 "--plain judges a CLAUDE.md below the top, as the push does"
plain "$(uesc 'a \u2014 b')" --path "/repo/package-lock.json"
want_plain 0 "--plain honours the same excluded paths as the push (a lock file)"
plain "$(uesc 'a \u2014 b')" --path "/repo/src/a.ts"
want_plain 1 "--plain still judges an ordinary path"
# Outside any git repository the path cannot be made relative to a repository top, and a bare
# basename would excuse a CLAUDE.md anywhere on disk (lessons review): so it is judged as written.
mkdir -p "$WORKDIR/no-repo"
plain "$(uesc 'a \u2014 b')" --path "$WORKDIR/no-repo/CLAUDE.md"
want_plain 1 "--plain judges a CLAUDE.md outside any repository rather than excusing it"
plain "x" --bogus
want_plain 2 "an unknown flag is refused with its own exit code, never read as clean (L11)"

# One fixture set, two readings: the push's diff reading and the mod's --plain reading must give the
# same verdict on every case (the issue's done-when). Escapes keep this file free of the characters.
FIXTURES="$DIR/lib/style-fixtures.txt"
nfix=0
while IFS=$'\t' read -r want text; do
  case "$want" in flag|clean) ;; *) continue ;; esac
  nfix=$((nfix+1))
  body="$(uesc "$text")"
  d="$(detect "$(printf '+++ b/f.ts\n+%s\n' "$body")")"
  plain "$body"
  if [ -n "$d" ]; then dv=flag; else dv=clean; fi
  if [ "$PLAIN_CODE" = 1 ]; then pv=flag; elif [ "$PLAIN_CODE" = 0 ]; then pv=clean; else pv="exit$PLAIN_CODE"; fi
  if [ "$dv" = "$want" ] && [ "$pv" = "$want" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: fixture '$text': want $want, push reading $dv, mod reading $pv"; fi
done < "$FIXTURES"
# The count is asserted, so an unreadable or emptied fixture file cannot pass as agreement (L98).
if [ "$nfix" -ge 10 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: only $nfix fixtures were read from $FIXTURES"; fi

# --- end to end: the hook must find the repo even when the session is elsewhere -
# The payload's cwd is the SESSION's directory, not the project's. A session
# rooted somewhere else reaches a project as `cd <repo> && git push`, and reading
# the cwd alone made this check see no work tree and wave the push through with
# no style check at all, silently. The forbidden characters below are written as
# escapes so this file holds no literal one for the hook to catch.
E2E="$(mktemp -d)"
mk_style_repo() {
  # $1 = file content
  local root; root="$(mktemp -d)"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@t.t; git config user.name t
    echo baseline > README.md
    git add -A; git commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin main
    mkdir -p app
    printf '%s\n' "$1" > app/copy.ts
    git add -A; git commit -qm copy
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
run_style_hook() {
  # $1 cwd, $2 command -> sets STYLE_CODE and STYLE_MSG (what it told the reader)
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  # stderr to the capture, stdout to nowhere: the refusal is what is being read.
  STYLE_MSG="$(printf '%s' "$p" | bash "$HOOK" 2>&1 >/dev/null)"; STYLE_CODE=$?
}
want_style_code() {
  if [ "$STYLE_CODE" = "$1" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: expected exit $1, got $STYLE_CODE"; fi
}

BAD="$(python3 -c 'print("const label = \"Loading — please wait\";")')"
W="$(mk_style_repo "$BAD")"
run_style_hook "$W" "git push"
want_style_code 2 "canary: a forbidden character blocks a plain push"

W="$(mk_style_repo "$BAD")"
run_style_hook "$E2E" "cd $W && git push"
want_style_code 2 "cd-then-push from a non-repo cwd must still be checked"

W="$(mk_style_repo "$BAD")"
run_style_hook "$E2E" "git -C $W push"
want_style_code 2 "git -C push from a non-repo cwd must still be checked"

W="$(mk_style_repo 'const label = "Loading, please wait";')"
run_style_hook "$E2E" "cd $W && git push"
want_style_code 0 "clean copy pushed the same way is allowed"

# --- what the push would actually CARRY, not what happens to be lying about ----
#
# This gate is PreToolUse, so on a chained commit and push it runs BEFORE the commit
# exists and falls back to the working tree. It fell back to the WHOLE working tree,
# including files the commit was never going to take, and blocked a push naming two
# untracked planning documents belonging to another session (claude-config#350).
#
# An untracked file nobody staged cannot be pushed, so it can never introduce anything.
# Neither can a tracked file modified but not named in the add, which is the same fault
# and the one the incident did not happen to show.

says_style() {  # $1 = a LITERAL needle
  case "$STYLE_MSG" in *"$1"*) return 0 ;; *) return 1 ;; esac
}
want_says() {
  if says_style "$1"; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: message did not say [$1], said: $STYLE_MSG"; fi
}
want_silent_on() {
  if says_style "$1"; then fail=$((fail+1)); echo "FAIL: $2: message wrongly said [$1]";
  else pass=$((pass+1)); fi
}

# A repo whose committed history is CLEAN, carrying whatever pending state a case needs.
#   $1 = content for app/copy.ts, left untracked (the file a case names in its add)
#   $2 = content for stranger.md, left untracked and NEVER named
#   $3 = content to write over the tracked README.md, left modified and never named
mk_pending_repo() {
  local root; root="$(mktemp -d)"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@t.t; git config user.name t
    echo baseline > README.md
    git add README.md; git commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin main
    mkdir -p app
    printf '%s\n' "$1" > app/copy.ts
    printf '%s\n' "$2" > stranger.md
    printf '%s\n' "$3" > README.md
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}

CLEAN='const label = "Loading, please wait";'

# 1. The incident. The add names one clean file; the forbidden character is in an
#    untracked file nobody staged, so nothing this push carries introduces it.
W="$(mk_pending_repo "$CLEAN" "$BAD" baseline)"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qm copy && git push"
want_style_code 0 "an untracked file nobody staged must not block the push"

# 2. The control, in the same shape: name the file that DOES carry one and it blocks.
#    Without this, case 1 is satisfied by a gate that stopped reading pending work at all.
W="$(mk_pending_repo "$BAD" "$CLEAN" baseline)"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qm copy && git push"
want_style_code 2 "a file the add DOES name must still block"

# 3. The same fault on a TRACKED file: modified, not named, so the commit will not take
#    it. The incident showed only the untracked half; this is the other half (L30).
W="$(mk_pending_repo "$CLEAN" "$CLEAN" "$BAD")"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qm copy && git push"
want_style_code 0 "a modified tracked file nobody named must not block the push"

# 4. But an add that really does take everything, takes everything.
W="$(mk_pending_repo "$CLEAN" "$BAD" baseline)"
run_style_hook "$E2E" "cd $W && git add -A && git commit -qm copy && git push"
want_style_code 2 "git add -A stages the stranger, so it is judged"

# 5. And a commit that stages tracked changes itself takes those.
W="$(mk_pending_repo "$CLEAN" "$CLEAN" "$BAD")"
run_style_hook "$E2E" "cd $W && git commit -qam copy && git push"
want_style_code 2 "commit -a stages the tracked change, so it is judged"

# 5b. An add naming a path AND a commit -a take BOTH (claude-config#457 item 4). The shared
#     parser reported only the named path, so the tracked edit -a also commits went unread.
W="$(mk_pending_repo "$CLEAN" "$CLEAN" "$BAD")"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qam copy && git push"
want_style_code 2 "an add beside commit -a still judges the tracked change -a takes"
#     And the untracked path the add names is read as well, not dropped for the tracked reading.
W="$(mk_pending_repo "$BAD" "$CLEAN" baseline)"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qam copy && git push"
want_style_code 2 "an add beside commit -a still judges the untracked file it names"
#     The stranger nobody named stays out of it.
W="$(mk_pending_repo "$CLEAN" "$BAD" baseline)"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qam copy && git push"
want_style_code 0 "an add beside commit -a does not take an untracked file nobody named"

# 6. Content already in the INDEX is carried by a bare commit with no add at all.
W="$(mk_pending_repo "$BAD" "$CLEAN" baseline)"
( cd "$W" && git add app/copy.ts ) >/dev/null 2>&1
run_style_hook "$E2E" "cd $W && git commit -qm copy && git push"
want_style_code 2 "content already staged is judged even with no add in the chain"

# 7. A push on its own judges the COMMITS only, and never the working tree. This is the
#    property the remedy in the message rests on, so it is asserted rather than assumed.
W="$(mk_pending_repo "$BAD" "$BAD" "$BAD")"
run_style_hook "$E2E" "cd $W && git push"
want_style_code 0 "a push on its own ignores everything uncommitted"

# 8. When the add's paths cannot be worked out, the gate must NOT narrow to nothing.
#    Reading no content and reporting a clean run is the one outcome this change could
#    have introduced, and it is indistinguishable from a push with nothing wrong in it
#    (L98). So it falls back to the whole working tree AND says that is what it did.
W="$(mk_pending_repo "$CLEAN" "$BAD" baseline)"
run_style_hook "$E2E" "cd $W && git add does-not-exist.txt && git commit -qm copy && git push"
want_style_code 2 "an unresolvable path falls back rather than narrowing to nothing"
want_says "could not be worked out" "an unresolvable path says the reading was widened"
want_says "two separate commands" "the widened reading names the way to settle it"

# 9. The same when the command cannot be tokenised at all, which is a different route to
#    the same answer and so needs its own case (L173).
W="$(mk_pending_repo "$CLEAN" "$BAD" baseline)"
run_style_hook "$E2E" "cd $W && git add \"app/copy.ts && git commit -qm copy && git push"
want_style_code 2 "an unparseable command falls back rather than narrowing to nothing"
want_says "could not be worked out" "an unparseable command says the reading was widened"

# 10. And the widened reading is not the old behaviour by another name: with the paths
#     readable, the stranger is left alone and nothing says the reading was widened.
W="$(mk_pending_repo "$CLEAN" "$BAD" baseline)"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qm copy && git push"
want_style_code 0 "a resolvable path keeps the reading narrow"

# --- the message may claim only what it measured (L11) ------------------------
#
# It said "this push introduces an em dash", which is a claim about the push, on a
# reading taken from the working tree. A reader believes their own change is at fault
# and goes looking in the wrong place.

# Committed content: the original claim is the true one here, so it stays.
W="$(mk_style_repo "$BAD")"
run_style_hook "$E2E" "cd $W && git push"
want_style_code 2 "committed content still blocks"
want_says "this push introduces" "a committed finding"

# Pending content: true that it would ship, false that the push introduces it, because
# nothing has committed it yet.
W="$(mk_pending_repo "$BAD" "$CLEAN" baseline)"
run_style_hook "$E2E" "cd $W && git add app/copy.ts && git commit -qm copy && git push"
want_silent_on "this push introduces" "a pending finding must not claim the push carries it"
want_says "about to make" "a pending finding names the commit it read"
want_says "not been committed yet" "a pending finding says what it measured"

# --- the range, and the repo, from the shared helpers (claude-config#439, #441) ---
#
# A push written inside a subshell names its repo in the cd inside the parentheses. The helper
# wanted whitespace or a separator before the cd, so this fell through to the session directory
# and, from a directory that is not a repository, was waved through unchecked.
W="$(mk_style_repo "$BAD")"
run_style_hook "$E2E" "(cd $W && git push)"
want_style_code 2 "a push inside a subshell is checked in the repo its cd names"

# A plain push with NO upstream: the base falls through to the local main, which is the branch
# being pushed, so the merge base is HEAD. This hook kept its own copy of the range and read that
# as an empty range, so the commit carrying the character was never read and the push passed.
mk_unpushed_repo() {  # $1 = content committed in the last commit; no remote at all
  local root; root="$(mktemp -d)"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@t.t; git config user.name t
    echo baseline > README.md
    git add README.md; git commit -qm init
    mkdir -p app
    printf '%s\n' "$1" > app/copy.ts
    git add app/copy.ts; git commit -qm copy
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
W="$(mk_unpushed_repo "$BAD")"
run_style_hook "$E2E" "cd $W && git push -u origin main"
want_style_code 2 "a push with no upstream reads its most recent commit"
W="$(mk_unpushed_repo "$CLEAN")"
run_style_hook "$E2E" "cd $W && git push -u origin main"
want_style_code 0 "and the same push of clean copy is allowed"

# A command that commits before it pushes, on a branch already level with its upstream: the
# pending commit is the change, and the commit already on the remote is not this push's to answer
# for. The forbidden character sits only in that pushed commit.
W="$(mk_style_repo "$BAD")"
( cd "$W" && git push -q ) >/dev/null 2>&1
( cd "$W" && printf 'more\n' >> README.md ) >/dev/null 2>&1
run_style_hook "$E2E" "cd $W && git add README.md && git commit -qm more && git push"
want_style_code 0 "a commit then push does not answer for a commit already on the remote"

# --- the detector's own reader (claude-config#486) -----------------------------
#
# The scan above is python3, and nothing asked whether python3 was installed. On a machine without
# it the scan returned an empty string, both findings were empty, and the gate exited 0: every
# push read as style clean, with nothing said. That is the one failure indistinguishable from a
# clean run (L490, L42, L98).
. "$DIR/lib/no-python-path.sh"
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-style-guide-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"
# jq is linked in: it reads the payload, so the command stays legible and the ONLY thing missing
# is the detector's own interpreter, which is the machine this issue is about.
npp_build_bin "$NOPY" jq
# The fixture's own premise, asserted rather than assumed. A directory that still reached a python3
# would make every case below pass for the wrong reason (L70, L159).
if npp_reaches_python3 "$NOPY"; then
  fail=$((fail+1)); echo "FAIL: the bare directory really reaches no python3 (it found one, so nothing below measures its absence)"
else pass=$((pass+1)); fi

run_style_nopy() {  # $1 cwd, $2 command
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  STYLE_MSG="$(printf '%s' "$p" | ( cd "$1" && env PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1 >/dev/null ))"; STYLE_CODE=$?
}

W="$(mk_style_repo "$BAD")"
run_style_nopy "$W" "git push"
want_style_code 2 "with no python3 the push is refused rather than read as style clean"
want_says "python3" "and the refusal names the reader that is missing"

# A push of CLEAN copy is refused too, and that is the point: nothing here can tell the two apart,
# so the gate says it could not look rather than reporting on a reading it never took (L11).
W="$(mk_style_repo "$CLEAN")"
run_style_nopy "$W" "git push"
want_style_code 2 "with no python3 even a clean push is refused, because nothing could judge it"

# A command that takes nothing from the missing detector is not refused. Without this the gate
# would be refusing commands it was never about (L54, L324).
W="$(mk_style_repo "$CLEAN")"
run_style_nopy "$W" "git status"
want_style_code 0 "a command that is not a push is not refused over a detector it never needed"

# The documented override still clears it, or the refusal is a dead end nothing in the session can
# answer (L109).
W="$(mk_style_repo "$BAD")"
run_style_nopy "$W" "SKIP_STYLE_CHECK=1 git push"
want_style_code 0 "the visible override still clears the missing detector refusal"

# The control, the same clean push with python3 present: allowed. So the refusals above are the
# detector's absence rather than a fixture that refuses everything (L159).
W="$(mk_style_repo "$CLEAN")"
run_style_hook "$W" "git push"
want_style_code 0 "the control still allows a clean push with python3 present"

rm -rf "$NOPY_ROOT"

# --- a scanner that is missing or crashes refuses the push by name (lessons review of #609) ---
# The rule used to be inline and could not go missing. Now that it is a file, its absence must not
# read as a clean diff: with every finding empty the push would pass with nothing said (L490).
NOSCAN="$WORKDIR/noscan-hooks"; mkdir -p "$NOSCAN/lib"
cp "$HOOK" "$NOSCAN/check-style-guide.sh"
for f in "$DIR"/lib/*; do [ "$(basename "$f")" = style-scan.py ] || cp "$f" "$NOSCAN/lib/"; done
run_style_hook_at() {  # $1 hooks dir, $2 cwd, $3 command
  local p
  p="$(HK_CMD="$3" HK_CWD="$2" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  STYLE_MSG="$(printf '%s' "$p" | bash "$1/check-style-guide.sh" 2>&1 >/dev/null)"; STYLE_CODE=$?
}
W="$(mk_style_repo "$CLEAN")"
run_style_hook_at "$NOSCAN" "$W" "git push"
want_style_code 2 "with lib/style-scan.py missing, even a clean push is refused"
case "$STYLE_MSG" in *style-scan.py*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: the refusal names the missing scanner: $STYLE_MSG" ;; esac
printf 'import sys\nsys.exit(3)\n' > "$NOSCAN/lib/style-scan.py"
run_style_hook_at "$NOSCAN" "$W" "git push"
want_style_code 2 "a scanner that crashes refuses the push rather than reading as clean"
run_style_hook_at "$NOSCAN" "$W" "SKIP_STYLE_CHECK=1 git push"
want_style_code 0 "the visible override still clears a broken scanner refusal"
# A scanner that reads diffs but cannot list its excluded paths would leave the exclusions empty
# with nothing said (lessons review): refused by name as well.
printf 'import sys\nsys.exit(3 if "--excludes" in sys.argv else 0)\n' > "$NOSCAN/lib/style-scan.py"
run_style_hook_at "$NOSCAN" "$W" "git push"
want_style_code 2 "a scanner that cannot list its excluded paths refuses the push"
case "$STYLE_MSG" in *excluded*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: that refusal names the excluded paths: $STYLE_MSG" ;; esac


echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
