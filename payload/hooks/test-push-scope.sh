#!/usr/bin/env bash
# Tests for how a hook payload's command is read, and therefore for whether a
# push is seen as a push at all (claude-config#97).
#
# A newline is a command separator in shell, exactly like a semicolon. Every
# parse_payload flattened it to a SPACE, and ps_is_git_push then split the
# command on && || ; and | and asked whether each segment STARTS with git push.
# A push written on its own line was glued onto the previous segment, so it
# started with whatever that segment started with, and the gate exited 0 without
# looking at anything. Not refused, not warned: unseen, which is indistinguishable
# from a push that was judged and allowed (L98, L184).
#
# That is the shape a heredoc commit message forces, because the heredoc has to
# close before the next command can start, so it is the commonest shape here
# rather than an exotic one.
#
# The functions under test are taken out of the real files rather than restated,
# so this cannot pass against a copy that has drifted.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/push-scope.sh"
GATE="$DIR/require-tests-before-push.sh"

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

# shellcheck source=lib/push-scope.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

# The whole chain a hook runs: a JSON payload in, a verdict on whether this is a
# push out. Asked this way rather than of ps_is_git_push alone, because the
# defect lived in the step BEFORE it and a test of the splitter on its own would
# have passed throughout (L3).
payload_for() { # payload_for <command text> [cwd]
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' \
    "$1" "${2:-}"
}

seen_as_push() { # seen_as_push <command text>
  local parsed cmd
  parsed="$(ps_parse_payload "$(payload_for "$1")" segmented)" || return 2
  cmd="${parsed%%$'\x1f'*}"
  ps_is_git_push "$cmd"
}

want_push()    { if seen_as_push "$1"; then check "$2" ok; else check "$2" "not seen as a push"; fi; }
want_notpush() { if seen_as_push "$1"; then check "$2" "seen as a push"; else check "$2" ok; fi; }

# The shape that was invisible: a heredoc commit message, then the push on the
# next line, because the heredoc cannot be followed by && on the same line.
want_push "$(printf 'git add -A && git commit -q -F - <<%sMSG%s\nsome message\nMSG\ngit push -u origin branch' "'" "'")" \
  "#97 a push on the line after a heredoc commit is seen"
want_push "$(printf 'git add -A && git commit -q -m "x"\ngit push')" \
  "#97 a push on its own line after a commit is seen"
want_push "$(printf 'echo one\necho two\ngit push --force-with-lease')" \
  "#97 a push on the last of several lines is seen"

# The shapes that already worked must keep working.
want_push 'git push' \
  "#97 a bare push is still seen"
want_push 'git add -A && git commit -m "x" && git push' \
  "#97 a push joined with && is still seen"
want_push 'cd /tmp/x; git push origin main' \
  "#97 a push after a semicolon is still seen"

# And it must not start seeing pushes that are not there, or every gate fires on
# every command and they all get switched off (L36).
want_notpush 'git status' \
  "#97 an unrelated command is not a push"
want_notpush "$(printf 'git add -A\ngit commit -m "mentions git push in the message"')" \
  "#97 a push named inside an argument is not a push"
want_notpush "$(printf 'echo one\necho two')" \
  "#97 several lines with no push in them are not a push"

# A heredoc BODY line that begins with the words is deliberately accepted as a
# push. It is the safe direction to be wrong in: the cost is a gate running when
# it need not, against a gate not running when it must, which is what shipped.
want_push "$(printf 'git commit -F - <<%sMSG%s\ngit push is what this message talks about\nMSG' "'" "'")" \
  "#97 a body line that reads like a push is judged, not ignored"

# ---------------------------------------------------------------------------
# One definition, two modes (claude-config#102). Six hooks each had their own copy
# of this, three flattening a newline and three not, which is how the defect above
# came to live in exactly the three that guard a push.
# ---------------------------------------------------------------------------
two_line="$(printf 'echo one\necho two')"
seg="$(ps_parse_payload "$(payload_for "$two_line" /tmp/somewhere)" segmented)"
raw="$(ps_parse_payload "$(payload_for "$two_line" /tmp/somewhere)" raw)"
seg_cmd="${seg%%$'\x1f'*}"; seg_cwd="${seg#*$'\x1f'}"
raw_cmd="${raw%%$'\x1f'*}"; raw_cwd="${raw#*$'\x1f'}"
[ "$seg_cmd" = "echo one; echo two" ] \
  && check "segmented mode turns a newline into a separator" ok \
  || check "segmented mode turns a newline into a separator" "got [$seg_cmd]"
[ "$raw_cmd" = "$two_line" ] \
  && check "raw mode leaves the command exactly as typed" ok \
  || check "raw mode leaves the command exactly as typed" "got [$raw_cmd]"
# Both modes carry the working directory, so every caller reads one shape. Losing it
# is not visible in the command half, and the gate uses it to find the repository at
# all: without it the whole hook exits silently.
[ "$seg_cwd" = "/tmp/somewhere" ] && [ "$raw_cwd" = "/tmp/somewhere" ] \
  && check "both modes carry the working directory" ok \
  || check "both modes carry the working directory" "segmented=[$seg_cwd] raw=[$raw_cwd]"
ps_parse_payload "$(payload_for "echo hi")" sideways >/dev/null 2>&1
[ "$?" -eq 2 ] \
  && check "an unknown mode is refused rather than guessed at" ok \
  || check "an unknown mode is refused rather than guessed at" "it answered anyway"
bad_json="$(ps_parse_payload 'not json at all' segmented 2>/dev/null)"; bad_rc=$?
[ "$bad_rc" -ne 0 ] || [ -z "$bad_json" ] \
  && check "a payload that does not parse does not answer with a command" ok \
  || check "a payload that does not parse does not answer with a command" "rc=$bad_rc out=[$bad_json]"

# And nothing may keep a private copy. Derived from the files rather than from a list
# of the hooks somebody remembered, because a copy added later is exempt from exactly
# the check meant to catch it (L96).
own_copies="$(grep -l '^parse_payload() {' "$DIR"/*.sh 2>/dev/null | tr '\n' ' ')"
case "$own_copies" in *[![:space:]]*) own_copies_found=1 ;; *) own_copies_found=0 ;; esac
[ "$own_copies_found" -eq 0 ] \
  && check "no hook keeps its own copy of the payload reader" ok \
  || check "no hook keeps its own copy of the payload reader" "still defined in: $own_copies"
users="$(grep -l 'ps_parse_payload' "$DIR"/*.sh 2>/dev/null | grep -c . || true)"
[ "${users:-0}" -ge 6 ] \
  && check "and the hooks that read one go through the library" ok \
  || check "and the hooks that read one go through the library" "only $users use it"

# ---------------------------------------------------------------------------
# End to end, through the whole hook against a real repository, because
# classifying the command correctly is only half of it: the verdict is what
# ships (L3). Two payloads carrying the SAME work, one joined with && and one
# split across lines, must reach the same verdict. Measured on the old code the
# first exits 2 and the second exits 0, which is the defect.
# ---------------------------------------------------------------------------
E2E="$(mktemp -d)"
trap 'rm -rf "$E2E"' EXIT
(
  cd "$E2E" || exit 1
  git init -q .
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p src
  printf 'print("one")\n' > src/thing.py
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m seed
  git init -q --bare "$E2E/remote.git"
  git remote add origin "$E2E/remote.git"
  git push -q -u origin HEAD 2>/dev/null
  printf 'print("two")\n' >> src/thing.py
) >/dev/null 2>&1

e2e_verdict() { # e2e_verdict <command text> -> prints the hook's exit code
  local rc=0
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))'     "$1" "$E2E" | bash "$GATE" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

_p="git push"
e2e_amp="$(e2e_verdict "git add -A && git commit -q -m x && $_p origin HEAD")"
e2e_nl="$(e2e_verdict "$(printf 'git add -A && git commit -q -m x\n%s origin HEAD' "$_p")")"
[ "$e2e_amp" = "2" ] \
  && check "#97 the gate refuses an untested change written on one line" ok \
  || check "#97 the gate refuses an untested change written on one line" "exit=$e2e_amp"
[ "$e2e_nl" = "2" ] \
  && check "#97 and refuses the same change with the push on its own line" ok \
  || check "#97 and refuses the same change with the push on its own line" "exit=$e2e_nl"

# --- ps_base_ref (claude-config#339): the ref a push is judged AGAINST. Three push gates need the
#     same answer and it used to be written out inside one of them, so a second gate would have
#     been a second copy, and two answers to "what is this push compared with" drift invisibly.
BR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-baseref.XXXXXXXX")"
case "${BR%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$BR'" >&2; exit 2 ;; esac
trap 'rm -rf "$BR"' EXIT
git init -q "$BR/r" 2>/dev/null
( cd "$BR/r" && printf 'x\n' > f && git add f && git -c user.email=p@l -c user.name=p commit -qm seed ) >/dev/null 2>&1

# With no upstream and no remote at all, it falls through to the local names it knows.
got="$( cd "$BR/r" && ps_base_ref || true )"
[ "$got" = "main" ] || [ "$got" = "master" ] \
  && check "ps_base_ref falls back to the local default branch" ok \
  || check "ps_base_ref falls back to the local default branch" "got=$got"

# And it prefers what the remote itself says over guessing from a list of names.
( cd "$BR/r" && git branch -f origin/zeta HEAD && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/zeta ) >/dev/null 2>&1
got2="$( cd "$BR/r" && ps_base_ref || true )"
[ "$got2" = "origin/zeta" ] \
  && check "ps_base_ref prefers the remote's own default branch" ok \
  || check "ps_base_ref prefers the remote's own default branch" "got=$got2"

# Nothing at all to compare with is a refusal, never a guess: "judge against HEAD~1" and "judge
# nothing" are different decisions and the gates do not make them the same way.
git init -q "$BR/empty" 2>/dev/null
( cd "$BR/empty" && ps_base_ref ) >/dev/null 2>&1 \
  && check "ps_base_ref refuses when there is nothing to compare with" "it returned 0" \
  || check "ps_base_ref refuses when there is nothing to compare with" ok

# A LONG COMMAND, read under pipefail (claude-config#403). The four questions below piped the
# command into a quiet grep, which leaves on its first match. With the match near the start of a
# command longer than a pipe buffer, the writer was killed holding the rest, and under the pipefail
# every hook sourcing this library sets, the pipeline reported that death: the override or the
# commit it had just found read as absent (L183). A heredoc commit message is exactly this shape.
# This suite runs under pipefail itself, so it asks in the same conditions the hooks do.
#
# The CONTROL is the same command short: every answer must be yes there too, so a failure below is
# the size and not a pattern that never matched (L159).
LONG_TAIL="$(awk 'BEGIN{for(i=0;i<40000;i++) print "filler line of a long heredoc body " i}')"
for size in short long; do
  body=""; [ "$size" = long ] && body="$LONG_TAIL"
  long_cmd="SKIP_TEST_CHECK=1 git add a.txt && git commit -a -m \"\$(cat <<'EOF'
subject
$body
EOF
)\" && git push"
  ps_has_override "$long_cmd" SKIP_TEST_CHECK \
    && check "a $size command still carries its override" ok \
    || check "a $size command still carries its override" "read as absent over ${#long_cmd} bytes"
  ps_commit_in_chain "$long_cmd" \
    && check "a $size command still has its commit seen" ok \
    || check "a $size command still has its commit seen" "read as absent over ${#long_cmd} bytes"
  ps_add_in_chain "$long_cmd" \
    && check "a $size command still has its add seen" ok \
    || check "a $size command still has its add seen" "read as absent over ${#long_cmd} bytes"
done

# ---------------------------------------------------------------------------
# Every ps_ function is defined exactly once (claude-config#440). ps_base_ref was written twice and
# bash kept the second, so the first and its comment read as live while nothing ran them, and the
# next edit to one would not have reached the other (L29, L30). Derived from the file, so a
# function added later is covered without anybody listing it (L96).
# ---------------------------------------------------------------------------
dup_defs="$(grep -Eo '^ps_[A-Za-z0-9_]+\(\)' "$LIB" | sort | uniq -d | tr '\n' ' ')"
def_count="$(grep -Ec '^ps_[A-Za-z0-9_]+\(\)' "$LIB")"
[ "${def_count:-0}" -ge 8 ] \
  && check "the define once check can see the library's functions" ok \
  || check "the define once check can see the library's functions" "found only $def_count definitions"
case "$dup_defs" in
  *[![:space:]]*) check "#440 every ps_ function is defined exactly once" "defined more than once: $dup_defs" ;;
  *) check "#440 every ps_ function is defined exactly once" ok ;;
esac

# ---------------------------------------------------------------------------
# ps_repo_dir reads a cd written inside a subshell or a group (claude-config#439). Its pattern
# wanted whitespace or a separator before the cd, so `(cd repo && git push)` fell through to the
# SESSION's directory and the gate judged, and refused, a repository the command never touched
# (L11). Each case sets the session directory to a DIFFERENT real repository, so a fall through is
# visible as the wrong answer rather than as no answer.
# ---------------------------------------------------------------------------
RD="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-repodir.XXXXXXXX")"
case "${RD%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$RD'" >&2; exit 2 ;; esac
git init -q "$RD/target" 2>/dev/null
git init -q "$RD/session" 2>/dev/null
mkdir -p "$RD/with space"
git init -q "$RD/with space/repo" 2>/dev/null
T="$RD/target"; S="$RD/session"

want_repo() { # want_repo <command> <expected dir> <description>
  local got
  got="$(ps_repo_dir "$1" "$S" || true)"
  [ "$got" = "$2" ] && check "$3" ok || check "$3" "resolved to [$got]"
}
want_repo "cd $T && git push" "$T" \
  "#439 control: a plain cd before the push is still read"
want_repo "(cd $T && git push)" "$T" \
  "#439 a cd inside a subshell names the repo"
want_repo "( cd $T && git push )" "$T" \
  "#439 a subshell with spaces inside its parentheses names the repo"
want_repo "{ cd $T; git push; }" "$T" \
  "#439 a cd inside a brace group names the repo"
want_repo "out=\$(cd $T && git push 2>&1); echo \"\$out\"" "$T" \
  "#439 a cd inside a command substitution names the repo"
want_repo "echo \"(cd $T && git push)\" && git push" "$S" \
  "#439 a subshell cd written inside a quoted string is not a cd"
want_repo "git commit -m 'then cd $T' && git push" "$S" \
  "#439 a cd written inside a single quoted message is not a cd"
want_repo "cd \"$RD/with space/repo\" && git push" "$RD/with space/repo" \
  "#439 a quoted path with a space in it is read whole"
# The commonest shape of all: a heredoc commit message whose body has an apostrophe in it, which
# leaves an unbalanced quote for any tokenizer that reads to the end (segmented, as a hook sees it).
want_repo "cd $T && git commit -q -F - <<'MSG'; it isn't balanced; MSG; git push" "$T" \
  "#439 a cd before a heredoc body with an apostrophe is still read"
want_repo "git push" "$S" \
  "#439 with no cd at all the session directory is used"

# Finding the repo is only half of it: the same subshell has to be seen as a push at all, or every
# gate exits before it asks which repo. Its segment ends `git push)`, whose subcommand read as
# `push)`, so the push was invisible, which is indistinguishable from a push judged clean (L98).
want_push "(cd /tmp/x && git push)" \
  "#439 a push inside a subshell is seen"
want_push "( cd /tmp/x && git push )" \
  "#439 a push inside a spaced subshell is seen"
want_push "{ cd /tmp/x; git push; }" \
  "#439 a push inside a brace group is seen"
want_push "(git push origin main)" \
  "#439 a subshell that is only a push is seen"
want_push "(SKIP_X=1 git push)" \
  "#439 a subshell push with an inline variable is seen"
want_notpush "git commit -m \"(git push later)\"" \
  "#439 a parenthesised push inside a message is still not a push"
want_notpush "(cd /tmp/x && git status)" \
  "#439 a subshell with no push in it is not a push"

# ---------------------------------------------------------------------------
# Where a push's range starts, in the three situations a push hook meets (claude-config#441).
# ps_merge_base alone dropped to HEAD~1 whenever the merge base was HEAD, which is right for a plain
# push with no upstream and wrong for the other two, and two hooks had each worked around it
# privately. Each situation is built for real below and asked of the helper written for it.
# ---------------------------------------------------------------------------
MB="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-mergebase.XXXXXXXX")"
case "${MB%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$MB'" >&2; exit 2 ;; esac
gc() { git -c user.email=p@l -c user.name=p "$@"; }
mb_commit() { # mb_commit <repo> <message>
  ( cd "$1" && printf '%s\n' "$2" >> f && git add f && gc commit -qm "$2" ) >/dev/null 2>&1
}
sha_of() { git -C "$1" rev-parse --verify --quiet "$2" 2>/dev/null; }

# 1. A PLAIN push with no upstream: the base falls to the local branch, which IS HEAD, so the
#    committed range is the most recent change (the case the HEAD~1 fallback was written for).
git init -q -b main "$MB/plain" 2>/dev/null
mb_commit "$MB/plain" one; mb_commit "$MB/plain" two
got="$( cd "$MB/plain" && ps_merge_base "$(ps_base_ref)" )"
[ "$got" = "$(sha_of "$MB/plain" HEAD~1)" ] \
  && check "#441 a plain push with no upstream is measured from HEAD~1" ok \
  || check "#441 a plain push with no upstream is measured from HEAD~1" "got=$got"

# 2. A command that COMMITS before it pushes, on a branch whose upstream is already HEAD. The
#    pending commit is the change, so the base is HEAD; HEAD~1 would blame this push for the last
#    commit already on the remote.
git init -q --bare "$MB/remote.git" 2>/dev/null
git init -q -b main "$MB/pend" 2>/dev/null
mb_commit "$MB/pend" one; mb_commit "$MB/pend" two
( cd "$MB/pend" && git remote add origin "$MB/remote.git" && git push -q -u origin main ) >/dev/null 2>&1
got="$( cd "$MB/pend" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/pend" HEAD)" ] \
  && check "#441 a commit then push on a pushed branch is measured from HEAD" ok \
  || check "#441 a commit then push on a pushed branch is measured from HEAD" "got=$got"
# The same helper on unpushed commits still returns the fork point, not HEAD.
mb_commit "$MB/pend" three
got="$( cd "$MB/pend" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/pend" HEAD~1)" ] \
  && check "#441 a commit then push with unpushed work is measured from the upstream" ok \
  || check "#441 a commit then push with unpushed work is measured from the upstream" "got=$got"

# A ONE commit repository, pushed: HEAD~1 does not exist, so the old fallback returned nothing and
# the gate skipped the very commit this command was about to make.
git init -q --bare "$MB/one.git" 2>/dev/null
git init -q -b main "$MB/one" 2>/dev/null
mb_commit "$MB/one" only
( cd "$MB/one" && git remote add origin "$MB/one.git" && git push -q -u origin main ) >/dev/null 2>&1
got="$( cd "$MB/one" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/one" HEAD)" ] \
  && check "#441 a commit then push in a one commit repo is measured from HEAD" ok \
  || check "#441 a commit then push in a one commit repo is measured from HEAD" "got=[$got]"

# But when the base is only a LOCAL branch name, a merge base at HEAD says nothing about what the
# remote holds, so the pending helper keeps the plain push answer and reads the last commit too.
# Reading one commit more is the safe side for a gate; reading one fewer ships it unjudged (L93).
got="$( cd "$MB/plain" && ps_pending_base "$(ps_base_ref)" )"
[ "$got" = "$(sha_of "$MB/plain" HEAD~1)" ] \
  && check "#441 a commit then push against a local base keeps the plain push answer" ok \
  || check "#441 a commit then push against a local base keeps the plain push answer" "got=$got"

# 3. AFTER the push (a PostToolUse hook). The upstream is now HEAD, so the merge base is HEAD and
#    the old fallback reviewed one commit however many the push carried.
git init -q --bare "$MB/post.git" 2>/dev/null
git init -q -b main "$MB/post" 2>/dev/null
mb_commit "$MB/post" one
( cd "$MB/post" && git remote add origin "$MB/post.git" && git push -q -u origin main ) >/dev/null 2>&1
before="$(sha_of "$MB/post" HEAD)"
mb_commit "$MB/post" two; mb_commit "$MB/post" three; mb_commit "$MB/post" four
( cd "$MB/post" && git push -q ) >/dev/null 2>&1
got="$( cd "$MB/post" && ps_pushed_base )"
[ -n "$got" ] && [ "$got" = "$before" ] \
  && check "#441 after a three commit push the range starts at the upstream's previous tip" ok \
  || check "#441 after a three commit push the range starts at the upstream's previous tip" "got=$got want=$before"
# The control: this is exactly the situation where the plain push answer is one commit short.
got_plain="$( cd "$MB/post" && ps_merge_base "$(ps_base_ref)" )"
[ "$got_plain" != "$before" ] \
  && check "#441 control: the plain push answer really is short after a push" ok \
  || check "#441 control: the plain push answer really is short after a push" "it already matched"

# A FIRST push of a feature branch has no previous upstream tip, so the whole branch is measured
# against the remote's default branch.
( cd "$MB/post" && git checkout -q -b feat && printf 'x\n' > g && git add g && gc commit -qm g1 \
    && printf 'y\n' >> g && git add g && gc commit -qm g2 && git push -q -u origin feat ) >/dev/null 2>&1
got="$( cd "$MB/post" && ps_pushed_base )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/post" main)" ] \
  && check "#441 after a first push of a branch the range starts where it left main" ok \
  || check "#441 after a first push of a branch the range starts where it left main" "got=$got"

# And no hook keeps its own copy of the post push rule. ai-review-on-push.sh wrote the three steps
# out itself because the library had no entry point for them; a second copy of "what did this push
# add" drifts invisibly (L613). The reflog selector is what every copy has to read, so it is the
# needle, assembled here so this line does not match itself (L245).
reflog_sel='@{u}'; reflog_sel="${reflog_sel}@{1}"
own_pushed="$(grep -lF "$reflog_sel" "$DIR"/*.sh 2>/dev/null | grep -v '/test-' | tr '\n' ' ')"
case "$own_pushed" in
  *[![:space:]]*) check "#441 no hook keeps its own post push range" "still in: $own_pushed" ;;
  *) check "#441 no hook keeps its own post push range" ok ;;
esac

# ---------------------------------------------------------------------------
# A branch REBASED onto a newer main and force pushed (claude-config#456). Its upstream still names
# the pre rebase tip, which is no longer an ancestor of HEAD, so the merge base with it is the OLD
# fork point and every commit main gained since was judged as part of this push: the deferral gate
# refused a force push over lines another pull request had already merged (L11). When the upstream
# tip is not an ancestor of HEAD, the range starts where the branch now leaves the default branch.
# ---------------------------------------------------------------------------
git init -q --bare "$MB/rb.git" 2>/dev/null
git init -q -b main "$MB/rb" 2>/dev/null
mb_commit "$MB/rb" base
( cd "$MB/rb" && git remote add origin "$MB/rb.git" && git push -q -u origin main \
    && git checkout -q -b feat && printf 'f\n' > g && git add g && gc commit -qm feat1 \
    && git push -q -u origin feat \
    && git checkout -q main ) >/dev/null 2>&1
mb_commit "$MB/rb" main2; mb_commit "$MB/rb" main3
( cd "$MB/rb" && git push -q origin main && git checkout -q feat && git rebase -q main ) >/dev/null 2>&1
new_main="$(sha_of "$MB/rb" main)"
old_fork="$(sha_of "$MB/rb" main~2)"
# The fixture is what it claims: the upstream is behind a rewrite, not simply behind (L159).
if git -C "$MB/rb" merge-base --is-ancestor origin/feat HEAD 2>/dev/null; then
  check "#456 fixture: the upstream tip is no longer an ancestor of HEAD" "it still is"
else
  check "#456 fixture: the upstream tip is no longer an ancestor of HEAD" ok
fi
got="$( cd "$MB/rb" && ps_merge_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$new_main" ] \
  && check "#456 a rebased branch's plain push is measured from the new main, not the old fork" ok \
  || check "#456 a rebased branch's plain push is measured from the new main, not the old fork" "got=$got want=$new_main (old fork $old_fork)"
got="$( cd "$MB/rb" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$new_main" ] \
  && check "#456 a rebased branch's commit then push is measured from the new main" ok \
  || check "#456 a rebased branch's commit then push is measured from the new main" "got=$got want=$new_main"
# After the force push itself, the post push helper reads the whole branch against the new main.
( cd "$MB/rb" && git push -q --force origin feat ) >/dev/null 2>&1
got="$( cd "$MB/rb" && ps_pushed_base )"
[ -n "$got" ] && [ "$got" = "$new_main" ] \
  && check "#456 after the force push the range starts at the new main" ok \
  || check "#456 after the force push the range starts at the new main" "got=$got want=$new_main"

# The control that keeps the fix narrow: a branch that DIVERGED from its upstream without being
# rebased (someone else pushed to it) is not a rewrite onto main. The newer of the two merge bases
# wins, so the range stays on the branch rather than widening back to where it left main.
git init -q --bare "$MB/dv.git" 2>/dev/null
git init -q -b main "$MB/dv" 2>/dev/null
mb_commit "$MB/dv" base
( cd "$MB/dv" && git remote add origin "$MB/dv.git" && git push -q -u origin main \
    && git checkout -q -b feat && printf 'a\n' > g && git add g && gc commit -qm f1 \
    && git push -q -u origin feat \
    && git clone -q "$MB/dv.git" "$MB/dv2" && cd "$MB/dv2" && git checkout -q feat \
    && printf 'other\n' > h && git add h && gc commit -qm theirs && git push -q origin feat \
    && cd "$MB/dv" && git fetch -q origin \
    && printf 'b\n' >> g && git add g && gc commit -qm mine ) >/dev/null 2>&1
shared="$(sha_of "$MB/dv" HEAD~1)"
got="$( cd "$MB/dv" && ps_merge_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$shared" ] \
  && check "#456 control: a diverged but unrebased branch keeps the upstream merge base" ok \
  || check "#456 control: a diverged but unrebased branch keeps the upstream merge base" "got=$got want=$shared"

# A repository with no commits has no range at all: every entry point answers nothing and says so
# with its status, rather than printing something a caller would diff against.
git init -q "$MB/none" 2>/dev/null
for fn in ps_merge_base ps_pending_base ps_pushed_base; do
  out="$( cd "$MB/none" && "$fn" "" 2>/dev/null )"; rc=$?
  [ -z "$out" ] && [ "$rc" -ne 0 ] \
    && check "#441 $fn refuses in a repository with no commits" ok \
    || check "#441 $fn refuses in a repository with no commits" "rc=$rc out=[$out]"
done

# ---------------------------------------------------------------------------
# ps_add_scope: what the commit in a chained command will take beyond the index
# (claude-config#442). It lived as inline python in two hooks; the cases are the ones
# test-check-style-guide.sh drives end to end, asked here of the one parser directly.
# ---------------------------------------------------------------------------
want_scope() { # want_scope <command> <expected output, lines joined by |> <description>
  local got
  got="$(ps_add_scope "$1" | tr '\n' '|' | sed 's/|$//')"
  [ "$got" = "$2" ] && check "$3" ok || check "$3" "got [$got]"
}
want_scope "git add app/copy.ts && git commit -qm copy && git push" "PATHS|app/copy.ts" \
  "#442 an add naming one file takes that path"
want_scope "git add a.ts b/c.ts && git commit -qm x && git push" "PATHS|a.ts|b/c.ts" \
  "#442 an add naming several files takes each"
want_scope "git add -A && git commit -qm copy && git push" "ALL" \
  "#442 git add -A takes everything"
want_scope "git add . && git commit -qm copy && git push" "ALL" \
  "#442 git add . takes everything"
want_scope "git add -u && git commit -qm copy && git push" "TRACKED" \
  "#442 git add -u takes tracked changes"
want_scope "git commit -qam copy && git push" "TRACKED" \
  "#442 commit -a with no add takes tracked changes"
want_scope "git commit -qm copy && git push" "INDEX" \
  "#442 a bare commit takes only the index"
want_scope "git add does-not-exist.txt && git commit -qm copy && git push" "PATHS|does-not-exist.txt" \
  "#442 a named path is reported as named, for the caller to resolve"
want_scope "git add \"app/copy.ts && git commit -qm copy && git push" "UNKNOWN" \
  "#442 a command that cannot be tokenised is UNKNOWN, never narrowed to nothing"
want_scope "git add --verbose && git commit -qm x && git push" "UNKNOWN" \
  "#442 an add that names nothing is UNKNOWN"
want_scope "rtk git -C /tmp/x add app/copy.ts && git commit -qm x && git push" "PATHS|app/copy.ts" \
  "#442 an rtk rewritten add with -C is still read"
# An add naming paths AND a commit that stages for itself with -a (claude-config#457 item 4). The
# commit takes every tracked change as well as the named paths, and reporting only the paths left
# a tracked edit nobody named unread by every gate. TRACKED, with the named paths after it, because
# a named path may be untracked and -a alone never takes one.
want_scope "git add new.ts && git commit -qam x && git push" "TRACKED|new.ts" \
  "#457 an add naming a path beside commit -a takes tracked changes AND the path"
want_scope "git add a.ts b.ts && git commit -a -m x && git push" "TRACKED|a.ts|b.ts" \
  "#457 the same with a separate -a flag and several paths"
want_scope "git add -u sub && git commit -qm x && git push" "TRACKED" \
  "#457 control: an add -u with a path and no commit -a names no untracked path"
want_scope "git add -A && git commit -qam x && git push" "ALL" \
  "#457 control: an add taking everything stays ALL beside commit -a"

# And no hook keeps its own copy of the parser. Derived from the hooks on disk, not from a list of
# the two that had one, so a third copy is caught the day it is written (L96, L613).
# The pattern is written with its brackets escaped, so the line holding it does not match itself
# (L245): the text on disk here is not the text the pattern finds.
own_add_parsers="$(grep -l 'toks\[j\] != "add"' "$DIR"/*.sh 2>/dev/null | tr '\n' ' ')"
case "$own_add_parsers" in
  *[![:space:]]*) check "#442 no hook keeps its own git add scope parser" "still in: $own_add_parsers" ;;
  *) check "#442 no hook keeps its own git add scope parser" ok ;;
esac

rm -rf "$RD" "$MB"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
