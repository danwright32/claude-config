#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No shell here starts a child it never waits for while it is writing (claude-config#1984, #1989).
#
# macOS bash 3.2 never waits for a process substitution's child, so its SIGCHLD lands whenever the
# child exits, and a builtin printf or echo writing into a pipe at that moment is interrupted and NOT
# restarted: "write error: Interrupted system call", and the rest of the output is gone (L1035).
# claude-sync lost the deepest rule file of a list that way under load (#1974, fixed in #1983). A
# hook's stdout and stderr are both pipes Claude Code reads, so a hook loses whatever it was saying:
# a decision, a refusal's reason, a notice. lib/unwaited-children.py names the shapes; claude-sync
# itself is held to the same scan by tests/test-claude-sync.sh.
#
# Every shell file the repository ships is held to all of it, background jobs included: the hooks
# (#1989), the skills' and tools' own scripts (#2015) and every suite (#2040). A worker one starts
# and never waits for is its own child, and a fast failing one exits while it is still printing. A
# suite writes into a pipe whenever it is run by hand, by Claude or by the runner, and a function in
# one whose output the suite captures is #1974's shape exactly. The hooks are read from this folder
# as well, so they are judged even where there is no checkout to list.
#
# Fixture text is told from code by the shell's own grammar, never by a file's name: what sits in a
# quoted string, a heredoc's body or a comment is data, so a suite quoting the shape for a scanner it
# tests is not a site, and the same text written as code in the same suite is. Both are driven below.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/unwaited-children.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/unwaited-children.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-unwaited-children: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# Whose child it is, measured on this Mac's /bin/bash, because the scan's whole split between what
# it reports and what it lets pass rests on it (L82). The child prints its parent's pid.
# ---------------------------------------------------------------------------
_P='<''('
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "main $$"\n'
  printf 'while read -r l; do echo "redirect $l"; done < %ssh -c '"'"'ps -o ppid= -p $PPID'"'"')\n' "$_P"
  printf 'printf "argument "; cat %ssh -c '"'"'ps -o ppid= -p $PPID'"'"')\n' "$_P"
  printf 'printf "pipeline "; cat %ssh -c '"'"'ps -o ppid= -p $PPID'"'"') | cat\n' "$_P"
  printf 'x="$(cat %ssh -c '"'"'ps -o ppid= -p $PPID'"'"'))"; echo "substitution $x"\n' "$_P"
  # A job put in the background is this shell's child; one started by a subshell that ends at once,
  # `( cmd & )`, is not (#1989): its own parent is that subshell, or launchd once the subshell has gone.
  printf 'sleep 1 & echo "background $(ps -o ppid= -p $!)"; wait\n'
  printf '( sh -c '"'"'echo "doublefork $PPID"'"'"' & )\n'
} > "$TMPROOT/parent.sh"
# Prints ok, "unmeasured: <why>" when <bash> is not bash 3, or "mismatch: <what it said>".
child_split_verdict() { # <bash>
  local b="$1" major parents main
  major="$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
  if [ "$major" != 3 ]; then
    echo "unmeasured: $b is bash ${major:-of unknown version}, and the split is bash 3.2's, the bash this Mac's scripts run on (L1035)"
    return
  fi
  parents="$("$b" "$TMPROOT/parent.sh" 2>&1 | tr -s ' ')"
  main="$(printf '%s\n' "$parents" | awk '$1 == "main" { print $2 }')"
  of() { printf '%s\n' "$parents" | awk -v k="$1" '$1 == k { print $2 }'; }
  if [ -n "$main" ] && [ "$(of redirect)" = "$main" ] && [ "$(of argument)" = "$main" ] \
     && [ -n "$(of pipeline)" ] && [ "$(of pipeline)" != "$main" ] \
     && [ -n "$(of substitution)" ] && [ "$(of substitution)" != "$main" ] \
     && [ "$(of background)" = "$main" ] \
     && [ -n "$(of doublefork)" ] && [ "$(of doublefork)" != "$main" ]; then
    echo ok
  else
    echo "mismatch: the scan's split no longer matches this bash; what it said: $(printf '%s' "$parents" | tr '\n' ' ')"
  fi
}
# The split is bash 3.2's: CI's Linux runner has a newer /bin/bash, which starts these children
# differently, so there the measurement says what it could not measure rather than failing (L411),
# and on 3.2 a split that moved still fails. Both seen with stand in shells that report a version
# and print a split no bash makes.
for v in 5 3; do
  printf '#!/bin/sh\ncase "$*" in *BASH_VERSINFO*) echo %s; exit 0 ;; esac\nprintf "main 100\\nredirect 100\\nargument 100\\npipeline 100\\nsubstitution 100\\n"\n' "$v" > "$TMPROOT/bash$v"
  chmod +x "$TMPROOT/bash$v"
done
verdict5="$(child_split_verdict "$TMPROOT/bash5")"
verdict3="$(child_split_verdict "$TMPROOT/bash3")"
check "#1984 a bash other than 3 is reported unmeasured, naming its version, not failed" \
  "$([[ "$verdict5" == "unmeasured: "*"bash 5"* ]] && echo ok || echo "got: $verdict5")"
check "#1984 on bash 3 a split that no longer matches still fails" \
  "$([[ "$verdict3" == "mismatch: "* ]] && echo ok || echo "got: $verdict3")"
if [ -x /bin/bash ] && command -v ps >/dev/null 2>&1; then
  verdict="$(child_split_verdict /bin/bash)"
  case "$verdict" in
    ok) check "#1984 /bin/bash makes the child its own in the redirect, simple command and background forms, and a subshell's in a pipeline, a substitution or ( cmd & )" ok ;;
    unmeasured:*) echo "SUITE-PART-UNMEASURED whose child a process substitution or a background job is, because ${verdict#unmeasured: }" ;;
    *) check "#1984 /bin/bash makes the child its own in the redirect, simple command and background forms, and a subshell's in a pipeline, a substitution or ( cmd & )" "${verdict#mismatch: }" ;;
  esac
else
  echo "SUITE-PART-UNMEASURED whose child a process substitution is, because /bin/bash or ps is absent here"
fi

# ---------------------------------------------------------------------------
# The scan reports each shape, and none of what is not one (L1, L104).
# ---------------------------------------------------------------------------
_H='<''<'
{
  printf '#!/usr/bin/env bash\n'                                                        # 1
  printf 'while read -r a; do echo "$a"; done < %sfind .)\n' "$_P"                       # 2  redirect
  printf 'while read -r a; do echo "$a"; done 6< %sls)\n' "$_P"                          # 3  redirect
  printf 'comm -23 %ssort a) %ssort b) > out\n' "$_P" "$_P"                              # 4  argument
  printf 'x="$(comm -23 %ssort a) %ssort b))"\n' "$_P" "$_P"                             # 5  not: substitution
  printf 'comm -23 %ssort a) %ssort b) | tr x y\n' "$_P" "$_P"                           # 6  not: pipeline
  printf 'comm -23 \\\n  %ssort a | sed s/a/b/) \\\n  %ssort b) \\\n  | tr x y\n' "$_P" "$_P"  # 7-10 not: pipeline on a later line
  printf '# done < %sfind .) in a comment\n' "$_P"                                       # 11 not
  printf 'echo "done < %sfind .) in a string"\n' "$_P"                                  # 12 not
  printf "echo 'done < %sfind .) in quotes'\n" "$_P"                                     # 13 not
  printf 'cat %sEOF\ndone < %sfind .) in a heredoc\nEOF\n' "$_H" "$_P"                   # 14-16 not
  printf 'y="$(case $1 in a) awk 1 %sls) ;; esac)"\n' "$_P"                             # 17 not: case pattern inside a substitution
  printf 'lines="$(find .)"\nwhile read -r a; do echo "$a"; done %sL\n$lines\nL\n' "$_H"  # 18-21 not: the remedy
  printf 'f(){\n  sleep 1 &\n  echo "$!"\n}\n'                                          # 22-25 background, no wait
  printf 'g(){\n  sleep 1 > /dev/null 2>&1 &\n  wait "$!"\n}\n'                          # 26-29 not: waited
  printf 'h(){\n  true && echo a >&2 && echo b &> /dev/null\n}\n'                         # 30-32 not: no background
  printf 'z="$(paste %sprintf a) \\\n  %sprintf b))"\n' "$_P" "$_P"                      # 33-34 not: substitution
  # Background jobs a shell can start safely, and the ones it cannot (#1989).
  printf '( sleep 1 </dev/null >/dev/null 2>&1 & )\n'                                    # 35 not: started by a subshell that ends at once
  printf '( sleep 1 & printf "r %%s\\n" "$!" >> rec ) </dev/null >/dev/null 2>&1\n'      # 36 not: a subshell that can write to no pipe
  printf '( sleep 1 & echo "$!" ) >/dev/null\n'                                         # 37 background: its stderr is still the pipe
  printf 'sleep 1 &\ndisown "$!"\n'                                                     # 38-39 background: never waited for
  printf 'sleep 2 &\n# kept\nkept=$!\nwait "$kept"\n'                                   # 40-43 not: kept and waited
  printf 'sleep 3 &\nlost=$!\n'                                                         # 44-45 background: kept, never waited
  printf 'w(){\n  sleep 4 > /dev/null 2>&1 &\n  inflight="$inflight $!"\n}\n'            # 46-49 not: waited below by name
  printf 'wait $inflight 2>/dev/null\n'                                                 # 50
  printf 'x="$(sleep 5 & echo "$!")"\n'                                                 # 51 background: the substitution writes into its pipe
} > "$TMPROOT/probe.sh"
probe="$(printf 'probe.sh\n' | python3 "$SCAN" --root "$TMPROOT" --background)"; probe_rc=$?
probe_got="$(printf '%s\n' "$probe" | awk -F': ' 'NF { split($1, p, ":"); printf "%s:%s ", p[2], $2 }')"
want="2:redirect 3:redirect 4:argument 23:background 37:background 38:background 44:background 51:background "
[ "$probe_rc" = 1 ] && [ "$probe_got" = "$want" ] \
  && check "#1984 the scan reports each unwaited shape, and nothing else" ok \
  || check "#1984 the scan reports each unwaited shape, and nothing else" "exit $probe_rc, got '$probe_got' where '$want' was wanted:
$probe"
# Without --background a background job is not judged (the hooks start detached workers on purpose).
probe_nb="$(printf 'probe.sh\n' | python3 "$SCAN" --root "$TMPROOT" | grep -c ': background: ' || true)"
[ "$probe_nb" = 0 ] \
  && check "#1984 background jobs are judged only when asked for" ok \
  || check "#1984 background jobs are judged only when asked for" "$probe_nb reported without --background"

# A bare `wait` reaps every job still in the table, so it answers for each kept one, and not for one
# that was disowned, which it no longer waits for (#1989).
{
  printf '#!/usr/bin/env bash\n'                                    # 1
  printf 'for i in 1 2; do\n  ( sleep 1 ) < /dev/null &\n  lane[$i]=$!\ndone\n'  # 2-5 not: kept, and the bare wait reaps them
  printf 'sleep 9 &\ndisown "$!"\n'                                 # 6-7 background: the bare wait does not wait for it
  printf 'wait\n'                                                   # 8
} > "$TMPROOT/probe-bare.sh"
bare="$(printf 'probe-bare.sh\n' | python3 "$SCAN" --root "$TMPROOT" --background)"; bare_rc=$?
bare_got="$(printf '%s\n' "$bare" | awk -F': ' 'NF { split($1, p, ":"); printf "%s:%s ", p[2], $2 }')"
[ "$bare_rc" = 1 ] && [ "$bare_got" = "6:background " ] \
  && check "#1989 a bare wait answers for every kept job and not for a disowned one" ok \
  || check "#1989 a bare wait answers for every kept job and not for a disowned one" "exit $bare_rc, got '$bare_got' where '6:background ' was wanted:
$bare"

# An `&` inside arithmetic is a bitwise and, and a `<(` there is a comparison, never a job or a
# process substitution (#2015): bug-bash's egress setup and disk-clean's scan-lib.sh read flags that
# way, and were reported as background jobs. A real job right after arithmetic is still one.
{
  printf '#!/usr/bin/env bash\n'                                    # 1
  printf '[ $(( 8#$mode & 8#022 )) -eq 0 ] || exit 1\n'             # 2  not
  printf 'x="$(( 16#$f & 16#40000000 ))"\n'                         # 3  not: in a double quoted string
  printf '(( a & b )) && echo yes\n'                                # 4  not: an arithmetic command
  printf 'y=$(( (a & 1) + $(echo 2) ))\n'                           # 5  not: nested parentheses and a substitution
  printf 'z=$(( a &\n  b ))\n'                                      # 6-7 not: across a line
  printf '[ $(( a %sb) )) = 1 ]\n' "$_P"                           # 8  not: a comparison, not a substitution
  printf 'sleep 1 &\n'                                              # 9  background
  printf 'echo $(( 1 & 1 )) & echo done\n'                          # 10 background: the job after the arithmetic
  printf 'if (( a & 1 )); then :; fi\n'                             # 11 not: an arithmetic command after if
  printf 'while (( n & 1 )); do break; done\n'                      # 12 not: and after while
} > "$TMPROOT/probe-arith.sh"
ar="$(printf 'probe-arith.sh\n' | python3 "$SCAN" --root "$TMPROOT" --background)"; ar_rc=$?
ar_got="$(printf '%s\n' "$ar" | awk -F': ' 'NF { split($1, p, ":"); printf "%s:%s ", p[2], $2 }')"
[ "$ar_rc" = 1 ] && [ "$ar_got" = "9:background 10:background " ] \
  && check "#2015 an and inside arithmetic is no background job, and a job after arithmetic is one" ok \
  || check "#2015 an and inside arithmetic is no background job, and a job after arithmetic is one" "exit $ar_rc, got '$ar_got' where '9:background 10:background ' was wanted:
$ar"

# A wait on a loop's variable waits for the list the loop walks (#2040): the claude-sync suite reaps
# its shards one by one, `for p in $pids; do wait "$p"`, to keep each one's exit status. The variable
# stands for the list the nearest loop before the wait gave it, so a later loop reusing the name for
# another list does not answer for the first, and a list no wait loops over is still reported.
{
  printf '#!/usr/bin/env bash\n'                                    # 1
  printf 'pids=""\n'                                                # 2
  printf 'for i in 1 2; do\n  sleep 1 &\n  pids="$pids $!"\ndone\n' # 3-6 not: waited through the loop below
  printf 'for p in $pids; do wait "$p"; done\n'                     # 7
  printf 'sleep 2 &\nother="$!"\n'                                  # 8-9 background: no wait loops over it
  printf 'for q in $unrelated; do wait "$q"; done\n'                # 10
  printf 'sleep 3 &\nlate="$!"\n'                                   # 11-12 background: q names another list when waited for
  printf 'for q in $late; do :; done\n'                             # 13
  printf 'for q in $nothing; do\n  wait "$q"\ndone\n'               # 14-16
} > "$TMPROOT/probe-loop.sh"
lp="$(printf 'probe-loop.sh\n' | python3 "$SCAN" --root "$TMPROOT" --background)"; lp_rc=$?
lp_got="$(printf '%s\n' "$lp" | awk -F': ' 'NF { split($1, p, ":"); printf "%s:%s ", p[2], $2 }')"
[ "$lp_rc" = 1 ] && [ "$lp_got" = "8:background 11:background " ] \
  && check "#2040 a wait on a loop variable answers for the list that loop walks, and for no other" ok \
  || check "#2040 a wait on a loop variable answers for the list that loop walks, and for no other" "exit $lp_rc, got '$lp_got' where '8:background 11:background ' was wanted:
$lp"

# Fixture text against code, in files named as suites are, both ways (#1989). A suite that writes the
# shape into a fixture for the scanner it tests, through a heredoc, a quoted string or a check whose
# subject is a substitution, has no site; the same suite with the shape written as code has exactly
# that one. The decision is the grammar's, so nothing about the name `test-` excuses anything.
mkdir -p "$TMPROOT/suites"
{
  printf '#!/usr/bin/env bash\n'                                                         # 1
  printf 'f="$1"\n'                                                                      # 2
  printf 'cat > "$f" %s'"'"'EOF'"'"'\n' "$_H"                                            # 3
  printf 'while read -r l; do echo "$l"; done < %sfind .)\n' "$_P"                       # 4  heredoc body
  printf 'EOF\n'                                                                         # 5
  printf "printf '%%s\\\\n' 'done < %sls)' 'comm -23 %ssort a) %ssort b) > out' >> \"\$f\"\n" "$_P" "$_P" "$_P"  # 6 quoted
  printf 'check "they agree" "$(diff %ssort a) %ssort b) > /dev/null && echo ok)"\n' "$_P" "$_P"  # 7 a substitution's own
} > "$TMPROOT/suites/test-fixture.sh"
cp "$TMPROOT/suites/test-fixture.sh" "$TMPROOT/suites/test-real.sh"
printf 'while read -r l; do echo "$l"; done < %sfind .)\n' "$_P" >> "$TMPROOT/suites/test-real.sh"  # 8 code
fx="$(printf 'test-fixture.sh\n' | python3 "$SCAN" --root "$TMPROOT/suites")"; fx_rc=$?
[ "$fx_rc" = 0 ] && [ -z "$fx" ] \
  && check "#1989 a suite quoting the shape as fixture text has no site" ok \
  || check "#1989 a suite quoting the shape as fixture text has no site" "exit $fx_rc: $fx"
rl="$(printf 'test-real.sh\n' | python3 "$SCAN" --root "$TMPROOT/suites")"; rl_rc=$?
rl_got="$(printf '%s\n' "$rl" | awk -F': ' 'NF { split($1, p, ":"); printf "%s:%s ", p[2], $2 }')"
[ "$rl_rc" = 1 ] && [ "$rl_got" = "8:redirect " ] \
  && check "#1989 the same suite with the shape written as code has exactly that site" ok \
  || check "#1989 the same suite with the shape written as code has exactly that site" "exit $rl_rc, got '$rl_got' where '8:redirect ' was wanted:
$rl"

# A file that cannot be read is reported, never passed as clean (L98).
missing="$(printf 'no-such-file.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; missing_rc=$?
missing_named=0
case "$missing" in *'could not be read'*) missing_named=1 ;; esac
[ "$missing_rc" = 1 ] && [ "$missing_named" = 1 ] \
  && check "#1984 a file the scan cannot read fails it" ok \
  || check "#1984 a file the scan cannot read fails it" "exit $missing_rc: $missing"

# ---------------------------------------------------------------------------
# The real hooks: none at all, background jobs included (#1989).
# ---------------------------------------------------------------------------
FILES="$(cd "$DIR" && find . -maxdepth 2 -name '*.sh' ! -name 'test-*' ! -name 'test_*' -type f | sed 's|^\./||' | sort)"
found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$DIR" --background --count)"; found_rc=$?
judged="$(printf '%s\n' "$found" | sed -n 's/^judged \([0-9]*\) files.*/\1/p')"
[ "${judged:-0}" -gt 50 ] \
  && check "the hook scripts were read" ok \
  || check "the hook scripts were read" "judged '${judged:-none}' files under $DIR, so the check below measured nothing:
$found"
[ "$found_rc" = 0 ] \
  && check "#1984 no hook starts a child its shell never waits for" ok \
  || check "#1984 no hook starts a child its shell never waits for" "exit $found_rc; bash 3.2 can drop what the hook prints next when that child exits:
$found
  Read the output into a variable first, which waits for every child, and feed the loop from a here document:
    lines=\"\$(producer)\"
    while IFS= read -r l; do ...; done ${_H}LINES
    \$lines
    LINES
  A worker nobody waits for is started by a subshell that ends at once, so it is never this hook's child:
    ( worker </dev/null >/dev/null 2>&1 & )
  One that is waited for keeps its pid (pid=\$!) and is reaped with wait \"\$pid\"."

# ---------------------------------------------------------------------------
# Every other shell file the repository ships: the skills, tools/, tests/ and every suite (#1989),
# background jobs included (#2015 for the skills and tools, #2040 for the suites). A suite writes
# into a pipe whenever it is run by hand, by Claude or by the runner, so a job of its own that exits
# mid line cuts its report short on bash 3.2 exactly as a hook's would. One pass over every file.
# ---------------------------------------------------------------------------
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "SUITE-PART-UNMEASURED the skills, tools and suites, because $DIR/.. is not the payload of a claude-config checkout, so there is no list of the repository's shell files to read"
else
  REPO_SH="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null | awk '/\.sh$/ || $0 == "claude-sync"' | sort)"
  repo_suites="$(printf '%s\n' "$REPO_SH" | awk -F/ '$NF ~ /^test[-_]/ { n++ } END { print n + 0 }')"
  repo_outside="$(printf '%s\n' "$REPO_SH" | awk '/^(tools|tests)\// || /^payload\/skills\// { n++ } END { print n + 0 }')"
  [ "$repo_suites" -gt 200 ] && [ "$repo_outside" -gt 100 ] \
    && check "#1989 the repository's suites, skills and tools are in what is read" ok \
    || check "#1989 the repository's suites, skills and tools are in what is read" "$repo_suites suites and $repo_outside files under payload/skills, tools and tests were listed in $ROOT, so the check below read too little"
  repo_found="$(printf '%s\n' "$REPO_SH" | python3 "$SCAN" --root "$ROOT" --background --count)"; repo_rc=$?
  repo_judged="$(printf '%s\n' "$repo_found" | sed -n 's/^judged \([0-9]*\) files.*/\1/p')"
  [ "${repo_judged:-0}" -gt 300 ] \
    && check "#1989 the repository's shell files were read" ok \
    || check "#1989 the repository's shell files were read" "judged '${repo_judged:-none}' files under $ROOT:
$repo_found"
  [ "$repo_rc" = 0 ] \
    && check "#2040 no skill, tool or suite starts a child its shell never waits for, background jobs included" ok \
    || check "#2040 no skill, tool or suite starts a child its shell never waits for, background jobs included" "exit $repo_rc; bash 3.2 can drop what the script prints next when that child exits:
$repo_found
  Read the output into a variable first and feed the loop from a here document, as above. A loop
  with no guard against an empty line gains one: a here document of an empty variable is one line.
  A stand in that lives for the whole run is started by a subshell that ends at once and writes
  nowhere, and its pid recorded in a file, so it is never this script's child:
    ( worker </dev/null >/dev/null 2>&1 & printf '%s\n' \"\$!\" > pid.file ) </dev/null >/dev/null 2>&1
  One that is waited for keeps its pid (pid=\$!), is reaped with wait \"\$pid\" straight after it is
  killed or has finished, and says beside it why nothing is printed between its start and that wait."
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
