#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No shell file opens a heredoc inside a command substitution whose body holds a single quote
# (claude-config#1690).
#
# macOS bash 3.2 finds the end of a `$( ... )` by scanning its text for quotes before it reads the
# heredoc inside it, so one apostrophe in the body refuses the whole file: a suite dies with exit 2
# and no SUITE-RESULT line (#1368 found it in test-ai-review-on-push.sh, #1575 in another suite). A
# newer bash parses the same file, so CI never sees it, and the parse check (check-shell-syntax.sh)
# sees it only on a Mac. So this reads the text, which reads the same everywhere, and it reports a
# body with balanced quotes too, which parses today and breaks on the next apostrophe anyone adds.
# The remedy: read the heredoc into a variable (or a file) outside the substitution, then run that.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/heredoc-in-substitution.py"
# The checkout, found by the one shared test (lib/checkout-root.sh, claude-config#1567).
ROOT="${HEREDOC_SUBST_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-heredoc-in-substitution: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/heredoc-subst.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-heredoc-in-substitution: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# The fault itself, on this Mac's /bin/bash, so the rule rests on a measurement (L82). On a bash
# that parses it the case is said once and counted as nothing (L411).
# ---------------------------------------------------------------------------
_H='<''<'
{
  printf '#!/usr/bin/env bash\n'
  printf 'x="$(python3 - %s%s\n' "$_H" "'PY'"
  printf '# the review%ss own words\nprint("one")\nPY\n)"\necho "$x"\n' "'"
} > "$TMPROOT/fault.sh"
if [ -x /bin/bash ] && ! /bin/bash -n "$TMPROOT/fault.sh" >/dev/null 2>&1; then
  check "#1690 /bin/bash refuses a heredoc holding an apostrophe inside a command substitution" ok
else
  echo "SUITE-PART-UNMEASURED the fault itself, because /bin/bash here ($(/bin/bash -c 'echo $BASH_VERSION' 2>/dev/null || echo absent)) parses it"
fi
# And the remedy parses there and gives the same answer.
{
  printf '#!/usr/bin/env bash\n'
  printf "IFS= read -r -d '' x_prog %s'PY' || true\n" "$_H"
  printf '# the review%ss own words\nprint("one")\nPY\n' "'"
  printf 'x="$(python3 -c "$x_prog" </dev/null)"\necho "$x"\n'
} > "$TMPROOT/remedy.sh"
if [ -x /bin/bash ]; then
  got="$(/bin/bash "$TMPROOT/remedy.sh" 2>&1)"
  [ "$got" = one ] \
    && check "#1690 the remedy, the program read outside the substitution, parses and runs under /bin/bash" ok \
    || check "#1690 the remedy, the program read outside the substitution, parses and runs under /bin/bash" "got: $got"
fi

# ---------------------------------------------------------------------------
# The scan sees each shape of one, and none of what is not one (L1, L104).
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/tree/payload/hooks"
{
  printf '#!/usr/bin/env bash\n'                                                   # 1
  printf 'a="$(python3 - "$x" %s%s 2>&1\n' "$_H" "'PY'"                            # 2  reported
  printf "print('balanced, still reported')\nPY\n)\"\n"                              # 3-5
  printf 'b="$(cat %s%s\n' "$_H" 'EOF'                                              # 6  reported
  printf "it's\nEOF\n)\"\n"                                                          # 7-9
  printf 'c="$(python3 - %s%s\n' "$_H" "'PY'"                                       # 10 not: no quote
  printf 'print("fine")\nPY\n)"\n'                                                   # 11-13
  printf 'python3 - %s%s\n' "$_H" "'PY'"                                            # 14 not: no substitution
  printf "print('top level')\nPY\n"                                                  # 15-16
  printf "d=\"\$(printf \"cat %s'EOF'\\\\nit's\\\\nEOF\")\"\n" "$_H"                 # 17 not: text in a string
  printf "# e=\"\$(cat %sEOF   a comment\n" "$_H"                                    # 18 not: comment
  printf "f=\"\$(wc -l %s%s \"it's\")\"\n" "$_H" "$_H"                              # 19 not: a here string
} > "$TMPROOT/tree/payload/hooks/probe.sh"
probe="$(printf 'payload/hooks/probe.sh\n' | python3 "$SCAN" --root "$TMPROOT/tree")"; probe_rc=$?
probe_lines="$(printf '%s\n' "$probe" | awk -F: 'NF { printf "%s ", $2 }')"
[ "$probe_rc" = 1 ] && [ "$probe_lines" = "2 6 " ] \
  && check "#1690 the scan sees a heredoc holding a quote inside a substitution, and nothing else" ok \
  || check "#1690 the scan sees a heredoc holding a quote inside a substitution, and nothing else" "exit $probe_rc, lines '$probe_lines' where 2 6 were wanted:
$probe"

# ---------------------------------------------------------------------------
# The real tree: none at all.
# ---------------------------------------------------------------------------
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
[ -n "$FILES" ] \
  && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$ROOT")"; found_rc=$?
[ "$found_rc" = 0 ] && [ -z "$found" ] \
  && check "#1690 no shell file opens a heredoc holding a quote inside a command substitution" ok \
  || check "#1690 no shell file opens a heredoc holding a quote inside a command substitution" "exit $found_rc; macOS bash 3.2 refuses these the day the body gains an unpaired apostrophe:
$found
  Read the body outside the substitution: IFS= read -r -d '' prog <<'PY' || true, then \$(python3 -c \"\$prog\" ... </dev/null)."

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
