#!/usr/bin/env bash
# Tests for the deferral guard (claude-config#430): check-deferrals.sh (the push gate),
# deferral-edit-check.sh (the edit time check) and the one detector they share, lib/deferrals.py.
#
# The REAL hooks are driven with payload JSON on stdin against fixture repositories and files built
# here, and the detector is driven directly with fixture text. Nothing here re-implements the rule
# (L52). Every fixture phrase below is a planted defect the guard must catch (L1), and each clean
# case sits beside the dirty case of the same shape, so a guard that stopped reading would fail the
# dirty one rather than passing both.
#
# This file is one the detector deliberately never judges (its fixtures are made of the phrases),
# and that exemption is itself asserted below, so it cannot quietly widen.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH_HOOK="$DIR/check-deferrals.sh"
EDIT_HOOK="$DIR/deferral-edit-check.sh"
DETECTOR="$DIR/lib/deferrals.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

for f in "$PUSH_HOOK" "$EDIT_HOOK" "$DETECTOR" "$DIR/lib/deferral-phrases.txt"; do
  if [ ! -f "$f" ]; then
    echo "test-check-deferrals: $f is not beside this suite, so nothing can be driven." >&2
    printf 'SUITE-NOT-RUN %s\n' "needs $(basename "$f") beside it"
    echo "passed: $pass, failed: $fail"
    printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
    exit 2
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.deferrals.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "test-check-deferrals: refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# ---------------------------------------------------------------------------------------------
# 1. The detector, driven directly with fixture text.
# ---------------------------------------------------------------------------------------------
detect_file() {  # detect_file <path as judged> <text> -> findings on stdout
  printf '%s' "$2" | python3 "$DETECTOR" --file "$1"
}
detect_diff() {  # detect_diff <diff text>
  printf '%s' "$1" | python3 "$DETECTOR" --diff
}
want_finding() {  # want_finding <desc> <output> [needle the output must carry]
  if [ -z "$2" ]; then check "$1" "expected a finding, got none"; return; fi
  if [ -n "${3:-}" ]; then
    case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "finding did not say [$3], said: $2" ;; esac
  else
    check "$1" ok
  fi
}
want_clean() {  # want_clean <desc> <output>
  if [ -z "$2" ]; then check "$1" ok; else check "$1" "expected no finding, got: $2"; fi
}

# The positive control, in the shape of the real Slate finding this guard exists for
# (src/lib/security-headers.ts:13, whose nearest issue number sits four lines away).
REAL_CASE='/**
 * The CSP is frame-ancestors ONLY (no script-src, which would need nonces). A full
 * content CSP is a separate effort.
 *
 * The non-framing hardening is served on EVERY response via next.config
 * headers() (HSTS #1024; nosniff + Referrer-Policy #1030).
 */
export const X = 1;
'
out="$(detect_file src/lib/security-headers.ts "$REAL_CASE")"
want_finding "the real Slate case: a block comment continuation saying separate effort with the issue four lines away" "$out" "src/lib/security-headers.ts:3: separate effort:"

# The finding names file, line, phrase and the line itself, in that order.
out="$(detect_file a.ts $'const a = 1;\n// TODO wire the retry\n')"
want_finding "a // comment carrying TODO is a finding" "$out" "a.ts:2: TODO: // TODO wire the retry"

# The two lines either side rule, in BOTH directions, and its edge.
out="$(detect_file a.ts $'// see #123\n// x\n// TODO wire the retry\n')"
want_clean "an issue number exactly two lines ABOVE clears it" "$out"
out="$(detect_file a.ts $'// TODO wire the retry\n// x\n// see #123\n')"
want_clean "an issue number exactly two lines BELOW clears it" "$out"
out="$(detect_file a.ts $'// see #123\n// x\n// y\n// TODO wire the retry\n')"
want_finding "an issue number three lines above does NOT clear it" "$out" "a.ts:4: TODO:"
out="$(detect_file a.ts $'// TODO wire the retry\n// x\n// y\n// see #123\n')"
want_finding "an issue number three lines below does NOT clear it" "$out" "a.ts:1: TODO:"
out="$(detect_file a.ts $'// TODO wire the retry (#123)\n')"
want_clean "an issue number on the line itself clears it" "$out"
out="$(detect_file a.ts $'// TODO wire the retry\n// https://github.com/Try-Pennie/slate/issues/2564\n')"
want_clean "a GitHub issue URL counts as the reference" "$out"
out="$(detect_file a.ts $'// TODO wire the retry, see #\n')"
want_finding "a bare hash with no digits is not a reference" "$out" "TODO"

# Comment versus code string: the phrase inside a string literal is never a finding.
out="$(detect_file a.ts $'const s = "good enough for now";\nconst t = \'TODO later\';\n')"
want_clean "a phrase inside a string literal is not a comment" "$out"
out="$(detect_file a.ts $'const s = "for now"; // for now, until the flag flips\n')"
want_finding "the same phrase in the trailing comment of a line that also holds it in a string IS a finding" "$out" "a.ts:1: for now:"
out="$(detect_file a.ts $'const url = "https://x.example/for now";\n')"
want_clean "a // inside a URL in a string is not a comment marker" "$out"
# "later" was dropped from the shipped list for firing on ordinary sentences (see the header of
# check-deferrals.sh), so the string literal rule the issue asks for is proved with a fixture
# list that still carries it, driven through --phrases.
printf 'later  # fixture only\n' > "$WORK/later-phrases.txt"
out="$(printf '%s' $'const s = "do it later";\nsetTimeout(later, 1);\n' | python3 "$DETECTOR" --phrases "$WORK/later-phrases.txt" --file a.ts)"
want_clean "later inside a string literal or as an identifier must not fire" "$out"
out="$(printf '%s' $'const s = 1; // do it later\n' | python3 "$DETECTOR" --phrases "$WORK/later-phrases.txt" --file a.ts)"
want_finding "and the fixture list does see later in a comment, so the clean case above is not a blind detector" "$out" "later"

# Markdown: every line is prose, no marker needed.
out="$(detect_file docs/notes.md $'# Retention\n\nAccepted, for now, with the trade stated.\n')"
want_finding "a markdown line carrying a phrase is a finding" "$out" "docs/notes.md:3: for now:"
out="$(detect_file docs/notes.md $'Accepted, for now, with the trade stated (#77).\n')"
want_clean "a markdown line with its issue number is clean" "$out"

# Word boundaries and case.
out="$(detect_file a.ts $'// todo: tidy this\n')"
want_finding "matching is case insensitive" "$out" "todo"
out="$(detect_file a.ts $'// the todos array is rendered here\n')"
want_clean "a phrase inside a longer word does not match" "$out"
out="$(detect_file a.ts $'// this is deferred work run by after()\n')"
want_clean "bare deferred (the narrowed phrase) does not fire on Slate's after() vocabulary" "$out"
out="$(detect_file a.ts $'// the 14 day horizon is deferred pending a 200 agent soak\n')"
want_finding "deferred pending does fire" "$out" "deferred pending"

# Comment syntax by file kind.
out="$(detect_file run.sh $'#!/usr/bin/env bash\necho hi # for now, no lock\n')"
want_finding "a # comment in a shell script" "$out" "run.sh:2: for now:"
out="$(detect_file a.ts $'const tag = "#for now";\nconst n = 3 # for now\n')"
want_clean "a # in TypeScript is not a comment marker" "$out"
out="$(detect_file q.sql $'select 1; -- for now, no index\n')"
want_finding "a -- comment in SQL" "$out" "q.sql:1: for now:"
out="$(detect_file a.ts $'const n = a -- b; // fine\nconst m = 2; // TODO\n')"
want_finding "a -- in TypeScript is not a comment marker but the // still is" "$out" "a.ts:2: TODO:"
out="$(detect_file page.html $'<div>\n<!-- for now the footer is static -->\n</div>\n')"
want_finding "an HTML comment" "$out" "page.html:2: for now:"
out="$(detect_file a.ts $'/* the cache is\n   good enough for now\n   and revisited later */\nconst x = 1;\n')"
want_finding "a block comment body with no leading star" "$out" "a.ts:2: for now:"
out="$(detect_file a.ts $'/* done */ const x = 1; // TODO\n')"
want_finding "a closed block comment followed by a line comment on the same line" "$out" "TODO"

# Diff mode: only ADDED lines are judged, context can clear, a removed line cannot.
out="$(detect_diff $'--- a/x.ts\n+++ b/x.ts\n@@ -1,3 +1,4 @@\n const a = 1;\n+// for now we skip the lock\n+const b = 2;\n const c = 3;\n')"
want_finding "an added comment line in a hunk is a finding at its NEW line number" "$out" "x.ts:2: for now:"
out="$(detect_diff $'--- a/x.ts\n+++ b/x.ts\n@@ -1,3 +1,4 @@\n // tracked as #55\n+// for now we skip the lock\n+const b = 2;\n const c = 3;\n')"
want_clean "a context line two above carrying the issue clears the added line" "$out"
out="$(detect_diff $'--- a/x.ts\n+++ b/x.ts\n@@ -1,3 +1,3 @@\n-// tracked as #55\n+// for now we skip the lock\n const b = 2;\n const c = 3;\n')"
want_finding "a REMOVED line carrying the issue cannot clear the added line" "$out" "for now"
out="$(detect_diff $'--- a/x.ts\n+++ b/x.ts\n@@ -1,3 +1,2 @@\n-// TODO old\n const b = 2;\n const c = 3;\n')"
want_clean "a removed TODO is not judged" "$out"
out="$(detect_diff $'--- a/x.ts\n+++ b/x.ts\n@@ -1,3 +1,3 @@\n const a = 1;\n // TODO never added by this push\n const c = 3;\n')"
want_clean "a context line carrying a phrase is not judged, only added lines are" "$out"
out="$(detect_diff $'--- /dev/null\n+++ b/new.md\n@@ -0,0 +1,2 @@\n+# Plan\n+Punt on the widget until someday.\n')"
want_finding "a brand new file in a diff" "$out" "new.md:2:"

# The exemptions, asserted rather than assumed.
out="$(detect_file "$DIR/lib/deferral-phrases.txt" $'TODO # a phrase\n')"
want_clean "the phrase list itself is never judged" "$out"
out="$(detect_file payload/hooks/test-anything.sh $'# TODO fixture\n')"
want_clean "a config repo suite under payload/hooks is never judged" "$out"
out="$(detect_file /somewhere/tests/test-anything.sh $'# TODO fixture\n')"
want_clean "a config repo suite under tests/ is never judged" "$out"
out="$(detect_file payload/hooks/some-hook.sh $'# TODO fixture\n')"
want_finding "a hook that is not a suite IS judged, so the suite exemption is not the whole directory" "$out" "TODO"
out="$(detect_file scripts/test-thing.ts $'// TODO fixture\n')"
want_finding "a test file in another shape (Slate's scripts/test-*.ts) is judged" "$out" "TODO"

# A missing phrase list is a refusal, never a clean scan of nothing (L98).
printf '%s' $'// TODO\n' | python3 "$DETECTOR" --phrases "$WORK/no-such-list.txt" --file a.ts >/dev/null 2>"$WORK/err.txt"; rc=$?
[ "$rc" -eq 3 ] && check "a missing phrase list exits 3" ok || check "a missing phrase list exits 3" "exit $rc"
case "$(cat "$WORK/err.txt")" in *"could not read the phrase list"*) check "and says so" ok ;; *) check "and says so" "said: $(cat "$WORK/err.txt")" ;; esac

# ---------------------------------------------------------------------------------------------
# 2. The push hook, end to end, against fixture repositories.
# ---------------------------------------------------------------------------------------------
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
mk_repo() {  # mk_repo <name> -> prints the work tree; main pushed to a bare origin, one clean commit
  local root="$WORK/$1"
  mkdir -p "$root"
  "${G[@]}" init -q --bare "$root/origin.git"
  "${G[@]}" init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    echo baseline > README.md
    "${G[@]}" add README.md && "${G[@]}" commit -qm init
    "${G[@]}" remote add origin "$root/origin.git"
    "${G[@]}" push -qu origin main
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
commit_file() {  # commit_file <work tree> <path> <content>
  ( cd "$1" && mkdir -p "$(dirname "$2")" && printf '%s' "$3" > "$2" && "${G[@]}" add "$2" && "${G[@]}" commit -qm "add $2" ) >/dev/null 2>&1
}
run_push() {  # run_push <cwd> <command> -> RC, MSG
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  MSG="$(printf '%s' "$p" | bash "$PUSH_HOOK" 2>&1 >/dev/null)"; RC=$?
}
want_rc() {  # want_rc <expected> <desc>
  if [ "$RC" = "$1" ]; then check "$2" ok; else check "$2" "expected exit $1, got $RC; said: ${MSG:0:300}"; fi
}
want_says() {  # want_says <needle> <desc>
  case "$MSG" in *"$1"*) check "$2" ok ;; *) check "$2" "message did not say [$1], said: ${MSG:0:300}" ;; esac
}
want_silent() {  # want_silent <desc>
  if [ -z "$MSG" ]; then check "$1" ok; else check "$1" "expected nothing on stderr, got: ${MSG:0:200}"; fi
}

# The positive control: a committed comment with a phrase and no issue blocks a plain push.
W="$(mk_repo p1)"
commit_file "$W" src/a.ts $'export const a = 1;\n// good enough for now, the lock comes with the outbox\n'
run_push "$W" "git push"
want_rc 2 "push hook: a committed deferral with no issue blocks the push"
want_says "PUSH BLOCKED" "push hook: the refusal is named as a block"
want_says "src/a.ts:2: for now:" "push hook: the refusal names the file, the line and the phrase"
want_says "SKIP_DEFERRAL_CHECK=1" "push hook: the refusal names the override"
want_says "explain to the user" "push hook: the refusal says to explain before overriding"
want_says "file the issue" "push hook: the refusal says what to do"

# The same line with the issue two lines below passes.
W="$(mk_repo p2)"
commit_file "$W" src/a.ts $'export const a = 1;\n// good enough for now, the lock comes with the outbox\n// (the outbox is its own change)\n// tracked in #4321\n'
run_push "$W" "git push"
want_rc 0 "push hook: the same comment with #NNNN two lines below is allowed"
want_silent "push hook: an allowed push says nothing"

# The same phrase inside a string literal passes.
W="$(mk_repo p3)"
commit_file "$W" src/a.ts $'export const label = "good enough for now";\n'
run_push "$W" "git push"
want_rc 0 "push hook: the phrase inside a string literal is not a finding"

# Markdown is judged whole.
W="$(mk_repo p4)"
commit_file "$W" docs/plan.md $'# Plan\n\nThe widget is future work.\n'
run_push "$W" "git push"
want_rc 2 "push hook: a markdown line is judged"
want_says "docs/plan.md:3: future work:" "push hook: the markdown finding names the line"

# The escape hatch, inline on the push, one command.
W="$(mk_repo p5)"
commit_file "$W" src/a.ts $'// TODO wire the retry\n'
run_push "$W" "SKIP_DEFERRAL_CHECK=1 git push"
want_rc 0 "push hook: SKIP_DEFERRAL_CHECK=1 allows the push"
run_push "$W" "git push"
want_rc 2 "push hook: and the same repo without the override is still blocked, so the hatch is what allowed it"

# A push from a session rooted elsewhere, reaching the repo through the command.
W="$(mk_repo p6)"
commit_file "$W" src/a.ts $'// TODO wire the retry\n'
mkdir -p "$WORK/elsewhere"
run_push "$WORK/elsewhere" "cd $W && git push"
want_rc 2 "push hook: cd-then-push from a non-repo cwd is still judged"
run_push "$WORK/elsewhere" "git -C $W push"
want_rc 2 "push hook: git -C push from a non-repo cwd is still judged"

# Only ADDED lines: a pre-existing deferral untouched by this push is not this push's fault.
W="$(mk_repo p7)"
commit_file "$W" src/a.ts $'// TODO wire the retry\n'
( cd "$W" && "${G[@]}" push -q origin main ) >/dev/null 2>&1
commit_file "$W" src/b.ts $'export const b = 2;\n'
run_push "$W" "git push"
want_rc 0 "push hook: a deferral already upstream is not judged again"

# Removing a deferral is never a finding.
W="$(mk_repo p8)"
commit_file "$W" src/a.ts $'// TODO wire the retry\nexport const a = 1;\n'
( cd "$W" && "${G[@]}" push -q origin main ) >/dev/null 2>&1
commit_file "$W" src/a.ts $'export const a = 1;\n'
run_push "$W" "git push"
want_rc 0 "push hook: a push that removes a deferral is allowed"

# The pending commit, when the same command commits before it pushes.
W="$(mk_repo p9)"
( cd "$W" && mkdir -p src && printf '%s' $'// for now the cap is 7\n' > src/a.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git add src/a.ts && git commit -qm cap && git push"
want_rc 2 "push hook: a deferral in a file the chained add names is judged before the commit exists"
want_says "about to commit" "push hook: a pending finding says it was read from what the command would stage"
run_push "$W" "cd $W && git push"
want_rc 0 "push hook: a push on its own ignores the same untracked file (the working tree is not the push)"
( cd "$W" && printf '%s' $'// TODO stranger\n' > stranger.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git add src/a.ts && git commit -qm cap && git push"
want_says "src/a.ts:1: for now:" "push hook: the named file is judged"
case "$MSG" in *stranger.ts*) check "push hook: an untracked file the add does not name is NOT judged" "stranger.ts was read" ;; *) check "push hook: an untracked file the add does not name is NOT judged" ok ;; esac
run_push "$W" "cd $W && git add -A && git commit -qm cap && git push"
want_says "stranger.ts:1: TODO:" "push hook: git add -A takes the stranger, so it is judged"
( cd "$W" && "${G[@]}" add src/a.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git commit -qm cap && git push"
want_rc 2 "push hook: content already in the index is judged by a bare commit and push"

# A command that commits before it pushes, on a branch already level with its upstream, answers for
# the commit it is about to make and not for the one already on the remote (claude-config#441). The
# shared range helper dropped to HEAD~1 here, so the TODO already pushed was blamed on this push.
W="$(mk_repo p13)"
commit_file "$W" src/a.ts $'// TODO wire the retry\n'
( cd "$W" && "${G[@]}" push -q origin main && printf '%s' $'export const b = 2;\n' > b.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git add b.ts && git commit -qm b && git push"
want_rc 0 "push hook: a commit then push does not answer for a deferral already on the remote"
( cd "$W" && printf '%s' $'// TODO a new one\n' > c.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git add c.ts && git commit -qm c && git push"
want_rc 2 "push hook: and the same shape still judges the commit it is about to make"

# An add naming a path beside a commit -a takes both (claude-config#457 item 4): the tracked edit
# -a commits, and the untracked file the add names.
W="$(mk_repo p15)"
commit_file "$W" src/a.ts $'export const a = 1;\n'
( cd "$W" && "${G[@]}" push -q origin main && printf '%s' $'// TODO tracked edit nobody named\n' >> src/a.ts \
    && printf '%s' $'export const n = 1;\n' > n.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git add n.ts && git commit -qam n && git push"
want_rc 2 "push hook: an add beside commit -a judges the tracked edit -a takes"
W="$(mk_repo p16)"
( cd "$W" && printf '%s' $'// TODO in the named new file\n' > n.ts ) >/dev/null 2>&1
run_push "$W" "cd $W && git add n.ts && git commit -qam n && git push"
want_rc 2 "push hook: an add beside commit -a judges the untracked file it names"

# A branch REBASED onto a newer main and force pushed (claude-config#456). Its upstream still named
# the pre rebase tip, so the range began at the old fork point and a deferral that another pull
# request had already merged into main was blamed on this push, which is how the hook refused a
# force push over two lines nobody on the branch wrote (L11).
W="$(mk_repo p14)"
(
  cd "$W" || exit 1
  "${G[@]}" checkout -q -b feat
  printf '%s' $'export const f = 1;\n' > f.ts && "${G[@]}" add f.ts && "${G[@]}" commit -qm f
  "${G[@]}" push -qu origin feat
  "${G[@]}" checkout -q main
) >/dev/null 2>&1
commit_file "$W" src/merged.ts $'// TODO already merged by someone else\n'
(
  cd "$W" || exit 1
  "${G[@]}" push -q origin main
  "${G[@]}" checkout -q feat
  "${G[@]}" rebase -q main
) >/dev/null 2>&1
run_push "$W" "cd $W && git push --force-with-lease"
want_rc 0 "push hook: a rebased branch's force push does not answer for main's deferral (#456)"
( cd "$W" && printf '%s' $'// TODO this branch adds\n' > mine.ts && "${G[@]}" add mine.ts && "${G[@]}" commit -qm mine ) >/dev/null 2>&1
run_push "$W" "cd $W && git push --force-with-lease"
want_rc 2 "push hook: and the same rebased branch still answers for its own deferral"
case "$MSG" in *merged.ts*) check "push hook: the rebased branch's refusal names only its own line" "it named main's merged.ts" ;; *) check "push hook: the rebased branch's refusal names only its own line" ok ;; esac

# The guard's own files and the config repo's suites never block a push of themselves.
W="$(mk_repo p10)"
commit_file "$W" payload/hooks/test-something.sh $'# TODO fixture text for a suite\n'
commit_file "$W" payload/hooks/lib/deferral-phrases.txt $'TODO # the marker\n'
run_push "$W" "git push"
want_rc 0 "push hook: the phrase list and a suite under payload/hooks are exempt"

# A repository with nothing to compare against skips OUT LOUD (L98).
mkdir -p "$WORK/lonely" && ( cd "$WORK/lonely" && "${G[@]}" init -q -b main . && printf '%s' $'// TODO\n' > a.ts && "${G[@]}" add a.ts && "${G[@]}" commit -qm one ) >/dev/null 2>&1
run_push "$WORK/lonely" "git push"
want_rc 0 "push hook: a repo with one commit and no upstream is allowed"
want_says "check-deferrals: skipped" "push hook: and it says it skipped rather than passing silently"

# Not a push: nothing to judge, nothing said.
W="$(mk_repo p11)"
commit_file "$W" src/a.ts $'// TODO wire the retry\n'
run_push "$W" "git status"
want_rc 0 "push hook: a command that is not a push is ignored"
want_silent "push hook: and says nothing"
run_push "$W" "echo 'git push'"
want_rc 0 "push hook: a command that merely mentions a push is ignored"

# A detector that cannot run is a skip out loud, not a pass. Driven by pointing the hook at a
# copy of itself whose lib/ holds no detector.
mkdir -p "$WORK/nolib/lib"
cp "$PUSH_HOOK" "$WORK/nolib/check-deferrals.sh"
cp "$DIR/lib/push-scope.sh" "$WORK/nolib/lib/push-scope.sh"
W="$(mk_repo p12)"
commit_file "$W" src/a.ts $'// TODO wire the retry\n'
p="$(HK_CMD="git push" HK_CWD="$W" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
MSG="$(printf '%s' "$p" | bash "$WORK/nolib/check-deferrals.sh" 2>&1 >/dev/null)"; RC=$?
want_rc 0 "push hook: with no detector beside it the push is allowed"
want_says "deferrals.py is not beside this hook" "push hook: and the skip names what was missing"

# ---------------------------------------------------------------------------------------------
# 3. The edit hook, driven with PostToolUse payloads against real files.
# ---------------------------------------------------------------------------------------------
run_edit() {  # run_edit <json payload> -> RC, MSG
  MSG="$(printf '%s' "$1" | bash "$EDIT_HOOK" 2>&1 >/dev/null)"; RC=$?
}
edit_payload() {  # edit_payload <tool> <file> <new_string or content> [old_string]
  python3 - "$1" "$2" "$3" "${4:-}" <<'PY'
import json, sys
tool, path, new, old = sys.argv[1:5]
if tool == "Write":
    tool_input = {"file_path": path, "content": new}
elif tool == "MultiEdit":
    tool_input = {"file_path": path, "edits": [
        {"old_string": "zzz", "new_string": "const z = 0;"},
        {"old_string": old, "new_string": new}]}
else:
    tool_input = {"file_path": path, "old_string": old, "new_string": new}
sys.stdout.write(json.dumps({"tool_name": tool, "tool_input": tool_input, "tool_response": {"success": True}}))
PY
}
E="$WORK/edits"; mkdir -p "$E/docs" "$E/payload/hooks/lib" "$E/tests"

# Positive control: a Write whose content carries a deferral with no issue.
printf '%s' $'export const a = 1;\n// good enough for now\n' > "$E/w.ts"
run_edit "$(edit_payload Write "$E/w.ts" $'export const a = 1;\n// good enough for now\n')"
want_rc 2 "edit hook: a Write carrying a deferral with no issue is refused"
want_says "DEFERRAL WITHOUT AN ISSUE" "edit hook: the refusal is named"
want_says "w.ts:2: for now:" "edit hook: the refusal names the file, the line and the phrase"
want_says "file the issue" "edit hook: the refusal says what to do"

# The same Write with the issue two lines away passes.
run_edit "$(edit_payload Write "$E/w.ts" $'export const a = 1;\n// good enough for now\n// until the outbox lands\n// tracked in #4321\n')"
want_rc 0 "edit hook: a Write with #NNNN two lines below the phrase is allowed"
want_silent "edit hook: an allowed edit says nothing"

# An Edit: the new text is located in the REAL file, so an issue number already sitting two lines
# above the edited region (and not in the new text at all) clears it.
printf '%s' $'// the cap is tracked in #216\n// and stays until the soak\n// for now the cap is 7\nexport const cap = 7;\n' > "$E/e.ts"
run_edit "$(edit_payload Edit "$E/e.ts" $'// for now the cap is 7\nexport const cap = 7;' 'export const cap = 14;')"
want_rc 0 "edit hook: an Edit whose new text sits two lines below an existing issue number in the file is allowed"
printf '%s' $'// the cap is tracked in #216\n// and stays until the soak\n// and a third line\n// for now the cap is 7\nexport const cap = 7;\n' > "$E/e.ts"
run_edit "$(edit_payload Edit "$E/e.ts" $'// for now the cap is 7\nexport const cap = 7;' 'export const cap = 14;')"
want_rc 2 "edit hook: the same Edit with the issue number three lines above is refused, so the file really was read"
want_says "e.ts:4: for now:" "edit hook: and the line number is the REAL line in the file, not the line in the fragment"

# The phrase inside a string literal written by an Edit is not a finding.
printf '%s' $'export const s = "for now";\n' > "$E/s.ts"
run_edit "$(edit_payload Edit "$E/s.ts" 'export const s = "for now";' 'export const s = "x";')"
want_rc 0 "edit hook: a phrase inside a string literal is not a finding"

# MultiEdit: each edit's new_string is judged.
printf '%s' $'const z = 0;\n// TODO wire the retry\n' > "$E/m.ts"
run_edit "$(edit_payload MultiEdit "$E/m.ts" $'// TODO wire the retry' 'old')"
want_rc 2 "edit hook: a MultiEdit whose second edit carries a deferral is refused"
want_says "m.ts:2: TODO:" "edit hook: the MultiEdit finding names the line"

# Markdown written by a Write.
run_edit "$(edit_payload Write "$E/docs/plan.md" $'# Plan\n\nWe punt on the widget.\n')"
want_rc 2 "edit hook: a markdown Write is judged whole"
want_says "plan.md:3: punt:" "edit hook: the markdown finding names the line"

# The new text not where the tool said: the fragment is judged alone and the message says so.
run_edit "$(edit_payload Edit "$E/does-not-exist.ts" $'// TODO wire the retry' 'old')"
want_rc 2 "edit hook: an Edit whose file cannot be read still judges the new text"
want_says "new text line 1" "edit hook: and says the line numbers count from the new text"
want_says "not found where the tool said" "edit hook: and says the neighbours were not read"

# Exemptions: the phrase list, the guard's own files, and this repo's suites.
run_edit "$(edit_payload Write "$E/payload/hooks/lib/deferral-phrases.txt" $'TODO # marker\n')"
want_rc 0 "edit hook: the phrase list is never judged"
run_edit "$(edit_payload Write "$E/payload/hooks/test-anything.sh" $'# TODO fixture\n')"
want_rc 0 "edit hook: a suite under payload/hooks is never judged"
run_edit "$(edit_payload Write "$E/tests/test-anything.sh" $'# TODO fixture\n')"
want_rc 0 "edit hook: a suite under tests/ is never judged"
run_edit "$(edit_payload Write "$E/payload/hooks/deferral-edit-check.sh" $'# TODO in the hook header\n')"
want_rc 0 "edit hook: the guard's own hook file is never judged"
run_edit "$(edit_payload Write "$E/payload/hooks/other-hook.sh" $'# TODO in some other hook\n')"
want_rc 2 "edit hook: another hook in the same directory IS judged, so the exemption is by name"

# Unreadable payloads fail quiet.
run_edit '{not json'
want_rc 0 "edit hook: an unreadable payload is allowed"
want_silent "edit hook: and says nothing"
run_edit '{"tool_name":"Edit","tool_input":{}}'
want_rc 0 "edit hook: a payload naming no file is allowed"
run_edit ''
want_rc 0 "edit hook: an empty payload is allowed"
run_edit '{"tool_name":"Edit","tool_input":{"file_path":"'"$E/w.ts"'","new_string":7}}'
want_rc 0 "edit hook: a new_string that is not text is allowed"

# The header line the registration check reads (lib/hook-registration.py compares settings against
# it), asserted so a rename of the event or tools cannot leave the settings pointing at nothing.
grep -q '^# Claude Code PreToolUse(Bash) hook' "$PUSH_HOOK" && check "push hook declares itself a PreToolUse(Bash) hook" ok || check "push hook declares itself a PreToolUse(Bash) hook" "header line missing"
grep -q '^# Claude Code PostToolUse(Edit|Write|MultiEdit) hook' "$EDIT_HOOK" && check "edit hook declares itself a PostToolUse(Edit|Write|MultiEdit) hook" ok || check "edit hook declares itself a PostToolUse(Edit|Write|MultiEdit) hook" "header line missing"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
