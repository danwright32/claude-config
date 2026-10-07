#!/usr/bin/env bash
# Tests for linux-sections-before-push.sh, the gate that runs the sections a push touches on Linux
# before letting it through (claude-config#339).
#
# Every check drives the REAL hook with a real payload, against a throwaway git repository built to
# hold the answer it expects. What matters most here is not that it blocks: it is every direction
# in which it must NOT block, because a gate that stops a push over a question the machine cannot
# ask is worse than no gate, and one that blocks in a repository it knows nothing about is worse
# still (L98, L42).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/linux-sections-before-push.sh"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-linuxgate-test.XXXXXXXX")" || TMPROOT=""
# An rm -rf on a path from a command that can fail, refused up front rather than relied on being
# harmless (L5, L9). The same line the suites next door hold for their own directories.
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-linux-sections-before-push: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
[ -d "$TMPROOT" ] || { echo "test-linux-sections-before-push: '$TMPROOT' is not a directory." >&2; exit 2; }
trap 'rm -rf "$TMPROOT"' EXIT

# A repository shaped like the one the hook is for: a runner, an audit, and a commit to diff
# against. Both scripts are STUBS whose exit status the caller chooses, because what is under test
# is the hook's handling of what it is told, not docker and not the audit.
mkrepo(){   # $1 = name   $2 = the exit status the audit stub returns   -> prints the path
  local r="$TMPROOT/$1"
  mkdir -p "$r/tests"
  git -C "$r" init -q 2>/dev/null || { git init -q "$r" 2>/dev/null; }
  printf 'x\n' > "$r/seed.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$r/tests/run-on-linux.sh"
  cat > "$r/tests/audit-changed-sections.sh" <<AUDIT
#!/usr/bin/env bash
echo "stub audit ran: AUDIT_ON_LINUX=\${AUDIT_ON_LINUX:-} base=\${1:-}"
echo "  == LISTED alpha =="
exit $2
AUDIT
  chmod +x "$r/tests/run-on-linux.sh" "$r/tests/audit-changed-sections.sh"
  git -C "$r" add -A 2>/dev/null
  git -C "$r" -c user.email=p@l -c user.name=p commit -qm seed 2>/dev/null
  # A base to diff against, so the hook does not fall out early for want of one.
  git -C "$r" branch -f main HEAD 2>/dev/null
  git -C "$r" branch -f origin/main HEAD 2>/dev/null
  # Work happens on a branch of its own, as it does in this repository since a push straight to
  # the default branch is refused (claude-config#596). The checks of that refusal below move back.
  git -C "$r" checkout -q -b feature 2>/dev/null
  printf '%s' "$r"
}

# The status is written to a file rather than returned through a command substitution: that runs in
# a subshell, so a variable set inside it does not survive, and the first version of this died on an
# unbound RC rather than reporting a wrong one, which is the better of the two ways to be wrong.
OUTFILE="$TMPROOT/.hook-out"
RC=0
# Every run keeps the gate's stand down record inside the throwaway directory. Without this the
# fixture repositories wrote into ~/.claude/state/linux-sections, the record a real push reads, and
# five fixture repos appeared in it (L2: a test must be structurally unable to touch live state).
export LINUX_SECTIONS_STATE_DIR="${LINUX_SECTIONS_STATE_DIR:-$TMPROOT/linux-state-default}"
run(){   # $1 = repo   $2 = the command the payload carries   -> fills $OUT and $RC
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | bash "$HOOK" > "$OUTFILE" 2>&1
  RC=$?
  OUT="$(cat "$OUTFILE" 2>/dev/null || true)"
}

# --- a section that fails on Linux blocks the push. This is the one thing it may block on.
R1="$(mkrepo fails 1)"
run "$R1" 'git push'; o1="$OUT"
[ "$RC" -eq 2 ] && check "a section failing on Linux blocks the push" ok \
                || check "a section failing on Linux blocks the push" "rc=$RC out=$o1"
case "$o1" in *'PUSH BLOCKED'*) check "and says so in the words the other gates use" ok ;;
              *) check "and says so in the words the other gates use" "out=$o1" ;; esac
case "$o1" in *'LISTED alpha'*) check "and carries what the audit reported" ok ;;
              *) check "and carries what the audit reported" "out=$o1" ;; esac
case "$o1" in *'AUDIT_ON_LINUX=1'*) check "and it really asked for the Linux run" ok ;;
              *) check "and it really asked for the Linux run" "out=$o1" ;; esac

# --- the Linux runner could not run at all: the push goes through, and the hook SAYS so. Measured
#     on 2026-09-21 while timing what a push waits on (claude-config#523): docker is installed on
#     this Mac and its daemon is not running, so this gate returned in 1.5 seconds having judged
#     nothing, in complete silence, and a push nobody checked on Linux looked exactly like one that
#     passed (L98, L557).
R7="$(mkrepo unmeasured 0)"
cat > "$R7/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
echo "  == LISTED alpha ==" >&2
echo "That is UNMEASURED, not a pass." >&2
exit 0
AUDIT
chmod +x "$R7/tests/audit-changed-sections.sh"
run "$R7" 'git push'; o7="$OUT"
[ "$RC" -eq 0 ] && check "a Linux run that could not happen does not block the push" ok \
                || check "a Linux run that could not happen does not block the push" "rc=$RC out=$o7"
case "$o7" in *UNMEASURED*) check "but the hook repeats that nothing was judged on Linux" ok ;;
              *) check "but the hook repeats that nothing was judged on Linux" "it said: [$o7]" ;; esac
case "$o7" in *'LISTED alpha'*) check "and names the sections nothing judged" ok ;;
              *) check "and names the sections nothing judged" "it said: [$o7]" ;; esac

# --- the RECORD of how often Linux actually judged a push (claude-config#529). A gate that stands
#     down on most pushes is close to not being there, and the difference is invisible unless it is
#     counted: this one stood down on every push on this Mac between 2026-09-07 and 2026-09-21 and
#     nothing anywhere knew (L557).
STATE="$TMPROOT/linux-state"
runrec(){ LINUX_SECTIONS_STATE_DIR="$STATE" run "$1" "$2"; }   # a record of its own, so the counts here are only this block's
R8="$(mkrepo counted 0)"
cat > "$R8/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
echo "  == LISTED alpha ==" >&2
echo "That is UNMEASURED, not a pass." >&2
exit 0
AUDIT
chmod +x "$R8/tests/audit-changed-sections.sh"
runrec "$R8" 'git push'; o8="$OUT"
runrec "$R8" 'git push'; o8b="$OUT"
case "$o8b" in *"judged 0 of the 2"*) check "it counts the pushes Linux did not judge, and says so" ok ;;
  *) check "it counts the pushes Linux did not judge, and says so" "it said: [$o8b]" ;; esac

# A push Linux DID judge is counted as judged, and the count is per repository.
R9="$(mkrepo countedok 0)"
cat > "$R9/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: audited 1 section(s) changed against ${1:-}, on Linux, and each one ran on its own and passed."
exit 0
AUDIT
chmod +x "$R9/tests/audit-changed-sections.sh"
runrec "$R9" 'git push'
cat > "$R9/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
echo "That is UNMEASURED, not a pass." >&2
exit 0
AUDIT
chmod +x "$R9/tests/audit-changed-sections.sh"
runrec "$R9" 'git push'; o9b="$OUT"
case "$o9b" in *"judged 1 of the 2"*) check "and a push it did judge counts as judged" ok ;;
  *) check "and a push it did judge counts as judged" "it said: [$o9b]" ;; esac
[ "$(find "$STATE" -name '*.txt' -type f 2>/dev/null | grep -c . || true)" -ge 2 ] \
  && check "and each repository has its own record" ok \
  || check "and each repository has its own record" "records: $(ls "$STATE" 2>/dev/null | tr '\n' ' ')"

# A push with nothing to judge (no section changed) is NOT a stand down, or the count would say
# the gate is failing on every push that touches no test.
R10="$(mkrepo nothingtodo 0)"
cat > "$R10/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: tests/test-claude-sync.sh is unchanged against ${1:-}, so no section needed running on its own. The full suite still runs."
exit 0
AUDIT
chmod +x "$R10/tests/audit-changed-sections.sh"
runrec "$R10" 'git push'; o10="$OUT"
[ -z "$o10" ] && check "a push with no section to judge says nothing and counts nothing" ok \
  || check "a push with no section to judge says nothing and counts nothing" "it said: [$o10]"

# A state directory it cannot write is not a reason to stop a push, and it says so rather than
# going quiet about its own bookkeeping (L42, L98).
R11="$(mkrepo unwritable 0)"
cp "$R8/tests/audit-changed-sections.sh" "$R11/tests/audit-changed-sections.sh"
LINUX_SECTIONS_STATE_DIR="/dev/null/nope" run "$R11" 'git push'; o11="$OUT"
[ "$RC" -eq 0 ] && check "a record it cannot write does not block the push" ok \
  || check "a record it cannot write does not block the push" "rc=$RC out=$o11"
case "$o11" in *UNMEASURED*) check "and the stand down is still reported" ok ;;
  *) check "and the stand down is still reported" "it said: [$o11]" ;; esac

# --- everything it must NOT block on.
R2="$(mkrepo passes 0)"
run "$R2" 'git push'; o2="$OUT"
[ "$RC" -eq 0 ] && check "a clean audit lets the push through" ok \
                || check "a clean audit lets the push through" "rc=$RC out=$o2"

# The audit refusing to answer is its own problem, not evidence about this push.
R3="$(mkrepo refuses 2)"
run "$R3" 'git push'; o3="$OUT"
[ "$RC" -eq 0 ] && check "an audit that could not answer does not block the push" ok \
                || check "an audit that could not answer does not block the push" "rc=$RC out=$o3"

# A repository this does not apply to: no runner, so nothing to run and nothing to say.
R4="$(mkrepo norunner 1)"; rm -f "$R4/tests/run-on-linux.sh"
run "$R4" 'git push'; o4="$OUT"
[ "$RC" -eq 0 ] && check "a repository with no Linux runner is left alone" ok \
                || check "a repository with no Linux runner is left alone" "rc=$RC out=$o4"
[ -z "$o4" ] && check "and it says nothing at all there" ok \
             || check "and it says nothing at all there" "out=$o4"

# Not a push at all.
R5="$(mkrepo notapush 1)"
run "$R5" 'git status'; o5="$OUT"
[ "$RC" -eq 0 ] && check "a command that is not a push is ignored" ok \
                || check "a command that is not a push is ignored" "rc=$RC out=$o5"

# The override, which must be explained to the user but must work.
R6="$(mkrepo override 1)"
run "$R6" 'SKIP_LINUX_CHECK=1 git push'; o6="$OUT"
[ "$RC" -eq 0 ] && check "the override lets a failing push through" ok \
                || check "the override lets a failing push through" "rc=$RC out=$o6"

# --- THE PRELUDE FAILED, NOT THE SECTION (claude-config#625). The audit answers 4 when the changed
#     sections' own checks passed and the prelude before them failed. On 2026-10-03 this hook
#     blamed the changed section for exactly that, while the suite's own counts said otherwise.
R12="$(mkrepo prelude 4)"
run "$R12" 'git push'; o12="$OUT"
[ "$RC" -eq 2 ] && check "a prelude failing on Linux still blocks the push" ok \
                || check "a prelude failing on Linux still blocks the push" "rc=$RC out=$o12"
case "$o12" in *'prelude every test section runs first FAILS'*) check "and says the prelude failed" ok ;;
  *) check "and says the prelude failed" "out=$o12" ;; esac
case "$o12" in *'a test section this change touches FAILS'*) check "and does not blame the section" "out=$o12" ;;
  *) check "and does not blame the section" ok ;; esac
case "$o12" in *'unchanged base'*) check "and names how to tell a broken base from this change" ok ;;
  *) check "and names how to tell a broken base from this change" "out=$o12" ;; esac

# --- A PUSH STRAIGHT TO THE DEFAULT BRANCH (claude-config#596). The Linux run above judged none of
#     the 15 pushes recorded on this Mac by 2026-10-05, and it only covers one suite's sections, so
#     a change reaches main through a pull request whose CI runs everything on Linux.
# The refusal is about the SHARED repository (claude-config#892), so these fixtures say they are it:
# an origin naming it, which nothing here ever contacts.
SHARED_URL="https://github.com/danwright32/claude-config.git"
R13="$(mkrepo direct 0)"
git -C "$R13" remote add origin "$SHARED_URL" 2>/dev/null
git -C "$R13" checkout -q main 2>/dev/null
run "$R13" 'git push'; o13="$OUT"
[ "$RC" -eq 2 ] && check "a bare push from the default branch is refused" ok \
                || check "a bare push from the default branch is refused" "rc=$RC out=$o13"
case "$o13" in *'pushes straight to main'*) check "and names the branch it would have pushed to" ok ;;
  *) check "and names the branch it would have pushed to" "out=$o13" ;; esac
case "$o13" in *'gh pr create'*) check "and hands over the pull request route instead" ok ;;
  *) check "and hands over the pull request route instead" "out=$o13" ;; esac
case "$o13" in *'stub audit ran'*) check "and refuses before running anything on Linux" "out=$o13" ;;
  *) check "and refuses before running anything on Linux" ok ;; esac
run "$R13" 'ALLOW_DIRECT_MAIN_PUSH=1 git push'; o13b="$OUT"
[ "$RC" -eq 0 ] && check "its own override lets the push through" ok \
                || check "its own override lets the push through" "rc=$RC out=$o13b"
run "$R13" 'SKIP_LINUX_CHECK=1 git push'; o13c="$OUT"
[ "$RC" -eq 2 ] && check "the Linux check's override does not also open the default branch (L448)" ok \
                || check "the Linux check's override does not also open the default branch (L448)" "rc=$RC out=$o13c"

R14="$(mkrepo refspec 0)"
git -C "$R14" remote add origin "$SHARED_URL" 2>/dev/null
run "$R14" 'git push origin HEAD:main'; o14="$OUT"
[ "$RC" -eq 2 ] && check "a refspec naming the default branch from a feature branch is refused" ok \
                || check "a refspec naming the default branch from a feature branch is refused" "rc=$RC out=$o14"
run "$R14" 'git push --force-with-lease origin +feature:refs/heads/main'; o14b="$OUT"
[ "$RC" -eq 2 ] && check "a forced, fully spelled refspec to the default branch is refused" ok \
                || check "a forced, fully spelled refspec to the default branch is refused" "rc=$RC out=$o14b"
run "$R14" 'git push --all origin'; o14c="$OUT"
[ "$RC" -eq 2 ] && check "pushing every branch is refused, since that includes the default" ok \
                || check "pushing every branch is refused, since that includes the default" "rc=$RC out=$o14c"
run "$R14" 'git add x && git commit -qm y && git push -u origin feature'; o14d="$OUT"
[ "$RC" -eq 0 ] && check "a feature branch push is let through" ok \
                || check "a feature branch push is let through" "rc=$RC out=$o14d"
# A tag only push from the default branch updates no branch at all, so it is not a push to main.
git -C "$R14" checkout -q main 2>/dev/null
run "$R14" 'git push --tags origin'; o14g="$OUT"
[ "$RC" -eq 0 ] && check "a tag only push from the default branch is not a push to it" ok \
                || check "a tag only push from the default branch is not a push to it" "rc=$RC out=$o14g"
run "$R14" 'git push origin v1.2'; o14h="$OUT"
[ "$RC" -eq 0 ] && check "pushing one named tag from the default branch is not a push to it" ok \
                || check "pushing one named tag from the default branch is not a push to it" "rc=$RC out=$o14h"
git -C "$R14" tag v1.2 2>/dev/null
run "$R14" 'git push origin v1.2'; o14h="$OUT"
[ "$RC" -eq 0 ] && check "a refspec naming an existing tag is not the default branch" ok \
                || check "a refspec naming an existing tag is not the default branch" "rc=$RC out=$o14h"
git -C "$R14" checkout -q feature 2>/dev/null
# A glob refspec is matched, never expanded against the working directory: a file named main sits
# in the checkout, so an unquoted expansion of 'refs/heads/*' patterns would read it as a word.
: > "$R14/main"
run "$R14" 'git push origin "refs/heads/*:refs/heads/*"'; o14i="$OUT"
[ "$RC" -eq 2 ] && check "a glob refspec over every branch counts as pushing the default one" ok \
                || check "a glob refspec over every branch counts as pushing the default one" "rc=$RC out=$o14i"
rm -f "$R14/main"
run "$R14" 'git push other main'; o14e="$OUT"
[ "$RC" -eq 0 ] && check "a push to some other remote is not the shared default branch" ok \
                || check "a push to some other remote is not the shared default branch" "rc=$RC out=$o14e"
run "$R14" 'gh pr create --body "then git push origin main later"'; o14f="$OUT"
[ "$RC" -eq 0 ] && check "a push only quoted inside an argument is not a push" ok \
                || check "a push only quoted inside an argument is not a push" "rc=$RC out=$o14f"

# The control for the refusal being scoped to this repository: with no Linux runner, a push from
# the default branch is none of this hook's business.
R15="$(mkrepo elsewhere 0)"; rm -f "$R15/tests/run-on-linux.sh"
git -C "$R15" checkout -q main 2>/dev/null
run "$R15" 'git push'; o15="$OUT"
[ "$RC" -eq 0 ] && [ -z "$o15" ] && check "another repository's default branch push is left alone" ok \
  || check "another repository's default branch push is left alone" "rc=$RC out=$o15"

# --- JUDGE THE REPOSITORY THE PUSH TARGETS, NOT THE WORDS (claude-config#892). On 2026-10-07 a push
#     to main in a scratch repository whose origin was a local bare repository was refused here.
#     What decides it now is where the push GOES: the directory it runs in (a -C, a cd in the same
#     command, or the session's), and the URL of the remote it pushes to. A target that cannot be
#     resolved is still refused.
BARE="$TMPROOT/scratch-remote.git"
git init -q --bare "$BARE" 2>/dev/null
# A scratch copy shaped exactly like this repository (runner and audit present), on main, whose
# origin is the local bare repository: its shape says claude-config, its target does not.
R16="$(mkrepo scratch-clone 0)"
git -C "$R16" remote add origin "$BARE" 2>/dev/null
git -C "$R16" checkout -q main 2>/dev/null
run "$R16" 'git push origin main'; o16="$OUT"
[ "$RC" -eq 0 ] && check "a scratch repo whose origin is a local bare repo may push to main" ok \
                || check "a scratch repo whose origin is a local bare repo may push to main" "rc=$RC out=$o16"
run "$R13" "cd '$R16' && git push origin main"; o16b="$OUT"
[ "$RC" -eq 0 ] && check "a cd into the scratch repo from a claude-config session judges the scratch repo" ok \
                || check "a cd into the scratch repo from a claude-config session judges the scratch repo" "rc=$RC out=$o16b"
run "$R13" "git -C '$R16' push"; o16c="$OUT"
[ "$RC" -eq 0 ] && check "a git -C at the scratch repo from a claude-config session judges the scratch repo" ok \
                || check "a git -C at the scratch repo from a claude-config session judges the scratch repo" "rc=$RC out=$o16c"
# A plain unrelated repository, no runner at all, with the same local bare remote.
R17="$TMPROOT/plain-scratch"
git init -q "$R17" 2>/dev/null
git -C "$R17" -c user.email=p@l -c user.name=p commit -q --allow-empty -m seed 2>/dev/null
git -C "$R17" branch -M main 2>/dev/null
git -C "$R17" remote add origin "$BARE" 2>/dev/null
run "$R13" "cd '$R17' && git push origin main"; o17="$OUT"
[ "$RC" -eq 0 ] && check "an unrelated scratch repo with a local bare remote passes" ok \
                || check "an unrelated scratch repo with a local bare remote passes" "rc=$RC out=$o17"

# A claude-config push is still judged, whichever way the command reaches it.
run "$R17" "cd '$R13' && git push origin main"; o18="$OUT"
[ "$RC" -eq 2 ] && check "a cd into a claude-config checkout pushing main is still refused" ok \
                || check "a cd into a claude-config checkout pushing main is still refused" "rc=$RC out=$o18"
run "$R17" "git -C '$R13' push origin main"; o18b="$OUT"
[ "$RC" -eq 2 ] && check "a git -C at a claude-config checkout pushing main is still refused" ok \
                || check "a git -C at a claude-config checkout pushing main is still refused" "rc=$RC out=$o18b"
# The remote is judged by its URL, not its name: claude-config under another name is still it.
git -C "$R16" remote add shared "$SHARED_URL" 2>/dev/null
run "$R16" 'git push shared main'; o18c="$OUT"
[ "$RC" -eq 2 ] && check "claude-config reached under another remote name is still refused" ok \
                || check "claude-config reached under another remote name is still refused" "rc=$RC out=$o18c"
run "$R16" "git push $SHARED_URL HEAD:main"; o18d="$OUT"
[ "$RC" -eq 2 ] && check "claude-config named by URL in the command is still refused" ok \
                || check "claude-config named by URL in the command is still refused" "rc=$RC out=$o18d"

# A target that cannot be resolved is still refused when the words name the default branch.
run "$R13" 'cd "$SCRATCH_NOT_EXPANDED" && git push origin main'; o19="$OUT"
[ "$RC" -eq 2 ] && check "a cd to a variable the hook cannot resolve, pushing main, is refused" ok \
                || check "a cd to a variable the hook cannot resolve, pushing main, is refused" "rc=$RC out=$o19"
case "$o19" in *'could not tell which repository'*) check "and says the target could not be resolved" ok ;;
  *) check "and says the target could not be resolved" "out=$o19" ;; esac
run "$R17" "mkdir -p '$TMPROOT/not-yet' && cd '$TMPROOT/not-yet' && git push origin main"; o19b="$OUT"
[ "$RC" -eq 2 ] && check "a cd to a directory that does not exist yet, pushing main, is refused" ok \
                || check "a cd to a directory that does not exist yet, pushing main, is refused" "rc=$RC out=$o19b"
run "$R13" 'ALLOW_DIRECT_MAIN_PUSH=1 git -C "$X" push origin main'; o19c="$OUT"
[ "$RC" -eq 0 ] && check "the override still lets an unresolvable push through" ok \
                || check "the override still lets an unresolvable push through" "rc=$RC out=$o19c"
run "$R13" 'cd "$X" && git push origin feature'; o19d="$OUT"
[ "$RC" -eq 0 ] && check "an unresolvable push to a feature branch is not a push to main" ok \
                || check "an unresolvable push to a feature branch is not a push to main" "rc=$RC out=$o19d"
run "$R13" 'cd "$X" && git push'; o19f="$OUT"
[ "$RC" -eq 2 ] && check "an unresolvable bare push, whose branch cannot be read, is refused" ok \
                || check "an unresolvable bare push, whose branch cannot be read, is refused" "rc=$RC out=$o19f"
run "$R13" 'cd "$X" && git push origin HEAD'; o19g="$OUT"
[ "$RC" -eq 2 ] && check "an unresolvable push of HEAD, whose branch cannot be read, is refused" ok \
                || check "an unresolvable push of HEAD, whose branch cannot be read, is refused" "rc=$RC out=$o19g"
# The check stands down only on a target POSITIVELY known to be another repository. A destination is
# judged by its repository path (owner/name, without case, .git or a trailing slash), whatever the
# host or port, so any path naming danwright32/claude-config is judged, as is one it cannot parse.
run "$R13" 'cd "$X" && git push https://mirror.example/github.com/danwright32/claude-config main'; o19h="$OUT"
[ "$RC" -eq 2 ] && check "any host serving the path danwright32/claude-config is judged" ok \
                || check "any host serving the path danwright32/claude-config is judged" "rc=$RC out=$o19h"
run "$R16" 'git push https://github.com/DanWright32/Claude-Config.git/ HEAD:main'; o19o="$OUT"
[ "$RC" -eq 2 ] && check "the path is compared without case, .git or a trailing slash" ok \
                || check "the path is compared without case, .git or a trailing slash" "rc=$RC out=$o19o"
run "$R16" 'git push ssh://github.com HEAD:main'; o19p="$OUT"
[ "$RC" -eq 2 ] && check "a URL with no repository path cannot be placed, so it is judged" ok \
                || check "a URL with no repository path cannot be placed, so it is judged" "rc=$RC out=$o19p"
run "$R16" 'git push https://github.com/danwright32/other-repo.git HEAD:main'; o19q="$OUT"
[ "$RC" -eq 0 ] && check "a GitHub URL for another repository stands down" ok \
                || check "a GitHub URL for another repository stands down" "rc=$RC out=$o19q"
# A remote that fetches from a local mirror and PUSHES to claude-config is judged by where it pushes.
git -C "$R16" remote add mirrored "$BARE" 2>/dev/null
git -C "$R16" remote set-url --push mirrored "$SHARED_URL" 2>/dev/null
run "$R16" 'git push mirrored main'; o19i="$OUT"
[ "$RC" -eq 2 ] && check "a remote whose push URL is claude-config is refused, whatever it fetches from" ok \
                || check "a remote whose push URL is claude-config is refused, whatever it fetches from" "rc=$RC out=$o19i"
# --repo names the destination when no remote word does (git lets a remote word win), in either
# spelling. R16 and R13 are both on main, so these bare pushes update main.
run "$R16" "git push --repo=$SHARED_URL"; o19j="$OUT"
[ "$RC" -eq 2 ] && check "--repo=<claude-config URL> pushing main is refused" ok \
                || check "--repo=<claude-config URL> pushing main is refused" "rc=$RC out=$o19j"
run "$R16" "git push --repo $SHARED_URL"; o19k="$OUT"
[ "$RC" -eq 2 ] && check "--repo <claude-config URL> pushing main is refused" ok \
                || check "--repo <claude-config URL> pushing main is refused" "rc=$RC out=$o19k"
run "$R13" "git push --repo '$BARE'"; o19l="$OUT"
[ "$RC" -eq 0 ] && check "--repo naming a local bare repo from a claude-config checkout passes" ok \
                || check "--repo naming a local bare repo from a claude-config checkout passes" "rc=$RC out=$o19l"
# claude-config through an ssh host alias (any name, not only github.com-<x>), or with a port.
run "$R16" 'git push git@github.com-work:danwright32/claude-config.git HEAD:main'; o19m="$OUT"
[ "$RC" -eq 2 ] && check "claude-config through a github.com-<alias> ssh host is refused" ok \
                || check "claude-config through a github.com-<alias> ssh host is refused" "rc=$RC out=$o19m"
run "$R16" 'git push gh-work:danwright32/claude-config HEAD:main'; o19r="$OUT"
[ "$RC" -eq 2 ] && check "claude-config through an ssh alias of any name is refused" ok \
                || check "claude-config through an ssh alias of any name is refused" "rc=$RC out=$o19r"
run "$R16" 'git push ssh://git@github.com:22/danwright32/claude-config.git HEAD:main'; o19n="$OUT"
[ "$RC" -eq 2 ] && check "claude-config through an ssh URL with a port is refused" ok \
                || check "claude-config through an ssh URL with a port is refused" "rc=$RC out=$o19n"
run "$R13" "cd \"\$X\" && git push '$BARE' main"; o19e="$OUT"
[ "$RC" -eq 0 ] && check "an unresolvable directory pushing to a local path is not the shared repo" ok \
                || check "an unresolvable directory pushing to a local path is not the shared repo" "rc=$RC out=$o19e"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
