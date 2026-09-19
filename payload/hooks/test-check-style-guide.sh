#!/usr/bin/env bash
# Tests for the em-dash/en-dash/emoji detector inside check-style-guide.sh.
# Extracts the real python3 detection block out of the hook and feeds it
# synthetic diff text, so we exercise the actual code, not a re-implementation.
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

# The extracted detector goes in a directory of this RUN's own, never beside this file
# (claude-config#180). A fixed name in payload/hooks is one path shared by every run on the
# machine: two at once truncate and then delete each other's copy, and the second reads a half
# written file and reports that the detector found nothing. It also put a stray file inside the
# tree the sync mirrors whenever a run was killed between writing it and removing it.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.styleguide.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

# Pull the python3 -c '...' detector body out of the hook into its own file
# (the lines strictly between the opening `findings=...python3 -c '` line and
# the closing `' 2>/dev/null)"` line).
awk '
  /^findings="\$\(printf/ { flag=1; next }
  flag && /2>\/dev\/null\)"$/ { flag=0; next }
  flag { print }
' "$HOOK" > "$WORKDIR/.style-detector.tmp.py"
[ -s "$WORKDIR/.style-detector.tmp.py" ] || { echo "FAIL: could not extract detector block"; exit 1; }

detect() {
  printf '%s' "$1" | python3 "$WORKDIR/.style-detector.tmp.py"
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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
