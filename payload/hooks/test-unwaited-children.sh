#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/
# No hook starts a child its shell never waits for while that shell is writing (claude-config#1984).
#
# macOS bash 3.2 never waits for a process substitution's child, so its SIGCHLD lands whenever the
# child exits, and a builtin printf or echo writing into a pipe at that moment is interrupted and NOT
# restarted: "write error: Interrupted system call", and the rest of the output is gone (L1035).
# claude-sync lost the deepest rule file of a list that way under load (#1974, fixed in #1983). A
# hook's stdout and stderr are both pipes Claude Code reads, so a hook loses whatever it was saying:
# a decision, a refusal's reason, a notice. lib/unwaited-children.py names the shapes; claude-sync
# itself is held to the same scan by tests/test-claude-sync.sh.
#
# Test files are not judged: a suite's verdict is its exit code and SUITE-RESULT line (L184), and
# several of them carry the shape as fixture text for the scanners they test.
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
} > "$TMPROOT/parent.sh"
if [ -x /bin/bash ] && command -v ps >/dev/null 2>&1; then
  parents="$(/bin/bash "$TMPROOT/parent.sh" 2>&1 | tr -s ' ')"
  main="$(printf '%s\n' "$parents" | awk '$1 == "main" { print $2 }')"
  of() { printf '%s\n' "$parents" | awk -v k="$1" '$1 == k { print $2 }'; }
  if [ -n "$main" ] && [ "$(of redirect)" = "$main" ] && [ "$(of argument)" = "$main" ] \
     && [ -n "$(of pipeline)" ] && [ "$(of pipeline)" != "$main" ] \
     && [ -n "$(of substitution)" ] && [ "$(of substitution)" != "$main" ]; then
    check "#1984 /bin/bash makes the child its own in the redirect and simple command forms, and a subshell's in a pipeline or substitution" ok
  else
    check "#1984 /bin/bash makes the child its own in the redirect and simple command forms, and a subshell's in a pipeline or substitution" "the scan's split no longer matches this bash; what it said:
$parents"
  fi
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
} > "$TMPROOT/probe.sh"
probe="$(printf 'probe.sh\n' | python3 "$SCAN" --root "$TMPROOT" --background)"; probe_rc=$?
probe_got="$(printf '%s\n' "$probe" | awk -F': ' 'NF { split($1, p, ":"); printf "%s:%s ", p[2], $2 }')"
want="2:redirect 3:redirect 4:argument 23:background "
[ "$probe_rc" = 1 ] && [ "$probe_got" = "$want" ] \
  && check "#1984 the scan reports each unwaited shape, and nothing else" ok \
  || check "#1984 the scan reports each unwaited shape, and nothing else" "exit $probe_rc, got '$probe_got' where '$want' was wanted:
$probe"
# Without --background a background job is not judged (the hooks start detached workers on purpose).
probe_nb="$(printf 'probe.sh\n' | python3 "$SCAN" --root "$TMPROOT" | grep -c ': background: ' || true)"
[ "$probe_nb" = 0 ] \
  && check "#1984 background jobs are judged only when asked for" ok \
  || check "#1984 background jobs are judged only when asked for" "$probe_nb reported without --background"

# A file that cannot be read is reported, never passed as clean (L98).
missing="$(printf 'no-such-file.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; missing_rc=$?
[ "$missing_rc" = 1 ] && printf '%s' "$missing" | grep -q 'could not be read' \
  && check "#1984 a file the scan cannot read fails it" ok \
  || check "#1984 a file the scan cannot read fails it" "exit $missing_rc: $missing"

# ---------------------------------------------------------------------------
# The real hooks: none at all.
# ---------------------------------------------------------------------------
FILES="$(cd "$DIR" && find . -maxdepth 2 -name '*.sh' ! -name 'test-*' ! -name 'test_*' -type f | sed 's|^\./||' | sort)"
found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$DIR" --count)"; found_rc=$?
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
    LINES"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
