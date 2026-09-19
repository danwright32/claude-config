#!/usr/bin/env bash
# Tests for the quiet-inverted-grep detector inside check-grep-quiet-invert.sh (L645).
# Extracts the real python3 detection block out of the hook and feeds it synthetic
# diff text, so this exercises the actual code rather than a re-implementation.
#
# The banned literal never appears in this file: every fixture is ASSEMBLED from its
# flag letters, so the guard cannot flag its own test on the way out. That is the
# same trick CLAUDE.md records for the dash rule, and here it is load bearing rather
# than tidy: a test full of literal fixtures would block every push that touched it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-grep-quiet-invert.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.grepqv.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

awk '
  /^findings="\$\(printf/ { flag=1; next }
  flag && /2>\/dev\/null\)"$/ { flag=0; next }
  flag { print }
' "$HOOK" > "$WORKDIR/detector.py"
[ -s "$WORKDIR/detector.py" ] || { echo "FAIL: could not extract the detector block"; exit 1; }

detect() { printf '%s' "$1" | python3 "$WORKDIR/detector.py"; }

pass=0
fail=0
want_flag() {
  local desc="$1" diff="$2" out
  out="$(detect "$diff")"
  if [ -n "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected a finding: $desc"; fi
}
want_clean() {
  local desc="$1" diff="$2" out
  out="$(detect "$diff")"
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected no finding: $desc -> got: $out"; fi
}

# Assembled, never written literally. See the header.
Q="-q"; V="v"; QV="${Q}${V}"; VQ="-${V}q"
# The long spellings are assembled for the same reason as the short ones.
LQ="--quie""t"; LS="--silen""t"; LI="--inver""t-match"
hdr='+++ b/scripts/thing.sh'

# --- the forms it must catch ---------------------------------------------------
want_flag "the combined short flags"        "$hdr
+if some_cmd | grep $QV 'pat'; then"
want_flag "the same letters reversed"       "$hdr
+if some_cmd | grep $VQ 'pat'; then"
want_flag "the flags given separately"      "$hdr
+some_cmd | grep $Q -$V 'pat'"
want_flag "separately, other order"         "$hdr
+some_cmd | grep -$V $Q 'pat'"
want_flag "bundled with a third flag"       "$hdr
+some_cmd | grep ${QV}E 'a|b'"
want_flag "the long spellings"              "$hdr
+some_cmd | grep $LQ $LI 'pat'"
want_flag "silent, which is quiet's alias"  "$hdr
+some_cmd | grep $LS -$V 'pat'"

# --- the controls, and they are the point -------------------------------------
# Without these, a detector that flags every grep passes all seven cases above.
want_clean "quiet alone is fine"            "$hdr
+some_cmd | grep $Q 'pat'"
want_clean "invert alone is fine"           "$hdr
+some_cmd | grep -$V 'pat'"
want_clean "count and invert is the remedy" "$hdr
+n=\$(some_cmd | grep -c$V 'pat')"
# `command grep` reaches the real binary, which answers correctly. It is the
# documented remedy, so flagging it would refuse the fix.
want_clean "command grep is exempt"         "$hdr
+if some_cmd | command grep $QV 'pat'; then"
want_clean "an absolute path is exempt"     "$hdr
+if some_cmd | /usr/bin/grep $QV 'pat'; then"
# Only ADDED lines. A push that deletes one of these must not be blocked by it.
want_clean "a removed line"                 "$hdr
-if some_cmd | grep $QV 'pat'; then"
want_clean "an unchanged context line"      "$hdr
 if some_cmd | grep $QV 'pat'; then"
want_clean "the diff header itself"         "$hdr"

# --- it names the file, so a finding can be found -----------------------------
{
  out="$(detect "$hdr
+some_cmd | grep $QV 'pat'")"
  case "$out" in
    *scripts/thing.sh*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: the finding does not name its file -> $out" ;;
  esac
}

# --- the guard must not flag ITSELF or this test ------------------------------
# Both files necessarily talk about the construct they ban. If either carries the
# literal, every push touching them is blocked, which is how a guard gets disabled
# rather than fixed.
for f in "$HOOK" "${BASH_SOURCE[0]}"; do
  as_diff="+++ b/$(basename "$f")
$(sed 's/^/+/' "$f")"
  want_clean "$(basename "$f") does not trip its own rule" "$as_diff"
done

# --- a KNOWN LIMIT, recorded rather than left to be discovered ----------------
# ugrep named directly is the same broken semantics, and is deliberately not
# flagged: this guard is about the SHIM surprising somebody who wrote grep and got
# something else. Anybody typing ugrep has chosen it. Asserted so the limit is a
# decision with a test rather than an omission.
want_clean "ugrep named directly is out of scope" "$hdr
+some_cmd | ugrep $QV 'pat'"

# --- the whole hook, over a MULTI COMMIT push (claude-config#457 item 2) -------------
# The hook asked ps_merge_base with no base, which always lands on HEAD~1, so a push of three
# commits was judged on its last one only and a line added in the first went out unread.
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
R="$WORKDIR/multi"
"${G[@]}" init -q --bare "$R/origin.git" 2>/dev/null
"${G[@]}" init -q -b main "$R/work" 2>/dev/null
(
  cd "$R/work" || exit 1
  echo baseline > README.md && "${G[@]}" add README.md && "${G[@]}" commit -qm init
  "${G[@]}" remote add origin "$R/origin.git" && "${G[@]}" push -qu origin main
  printf '%s\n' "some_cmd | grep $QV 'pat'" > first.sh && "${G[@]}" add first.sh && "${G[@]}" commit -qm first
  echo two > two.txt && "${G[@]}" add two.txt && "${G[@]}" commit -qm two
  echo three > three.txt && "${G[@]}" add three.txt && "${G[@]}" commit -qm three
) >/dev/null 2>&1
hook_rc() {  # hook_rc <cwd> <command> -> the hook's exit code
  local rc=0
  HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))' \
    | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
got="$(hook_rc "$R/work" "git push")"
if [ "$got" = "2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a three commit push is judged on its first commit too (exit $got)"; fi
# The control: once that commit is on the remote, the same push has nothing of it to answer for.
( cd "$R/work" && "${G[@]}" push -q origin main && echo four > four.txt && "${G[@]}" add four.txt && "${G[@]}" commit -qm four ) >/dev/null 2>&1
got="$(hook_rc "$R/work" "git push")"
if [ "$got" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a line already on the remote is not judged again (exit $got)"; fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "test-check-grep-quiet-invert: ALL PASSED ($pass checks)"
else
  echo "test-check-grep-quiet-invert: $fail FAILED, $pass passed"
fi
# The machine readable tally, LAST, because the runner reads this rather than
# guessing a score from prose. Without it the suite is counted by inference.
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
