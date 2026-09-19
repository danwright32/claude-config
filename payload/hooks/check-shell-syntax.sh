#!/usr/bin/env bash
#
# check-shell-syntax.sh: parse every shell file in a tree with the shell itself (claude-config#489).
#
# THE FAULT THAT PROMPTED IT. bash does not honour a shell COMMENT while it scans for the closing
# paren of a command substitution, so a prose comment holding an apostrophe inside $( ... ) makes
# it report "unexpected EOF while looking for matching quote" at the END of the file, naming a line
# far from the cause. Reproduced in isolation on 2026-09-19 while writing test-lessons-advisory.sh.
# Several suites here build strings inside command substitutions with prose comments in them, and
# this repository's house style is long prose comments, so the next one costs the same hunt. It is
# L434's sibling: a construct that reads differently between tools, with no error to say so.
#
# WHY THE SHELL AND NOT A PATTERN SCAN. The issue proposed scanning for an apostrophe inside a
# comment within a command substitution, and asked for the false positive rate to be measured
# before choosing. It was measured: a line based scanner of that shape flagged 13 sites across the
# 161 shell files here and every one was wrong, because a multi line single quoted string (an awk
# or python program, of which this repository has many) defeats any reading that does not actually
# parse the file. Reading it correctly needs a bash parser, and there is one to hand. So the guard
# asks the question the thing it guards asks (L144), and the over match that would read exactly
# like the guard working (L104) cannot happen.
#
# It catches every other syntax error too, which nothing here did before.
#
# WHICH BASH MATTERS. This fault is a property of the interpreter. Both Macs run what
# /usr/bin/env bash resolves to there, which is 3.2.57, and that one has it. A newer bash may parse
# the same file correctly, so a pass under one of those is a smaller statement than a pass under
# 3.2, and the version is printed rather than left to be assumed (L11, L460). Nothing was measured
# here about bash 5: no copy of it was available on the machine this was written on, and claiming
# otherwise would be a claim no check made.
#
# Run:  bash ~/.claude/hooks/check-shell-syntax.sh [ROOT]
#
# Exit 0 = every shell file found under ROOT parses, and it says how many and with which bash.
# Exit 1 = at least one does not parse. Each one is named with what the shell said about it,
#          quoted rather than summarised: the shell's own message carries the line, and a guess
#          written here would be a second account of a fault the shell already described (L351).
# Exit 2 = nothing could be measured: ROOT is not a directory, or it holds no shell file at all.
#          Refusing rather than passing, because a sweep that found nothing to check reports
#          success exactly like one that checked everything and found it sound (L98, L320).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The tree to read. An explicit argument is used as given and never quietly swapped for the
# default, because a tool handed a target it then does not use looks exactly like one that used it
# (L320). With no argument: the git checkout this is run from, or failing that the config root the
# hooks directory sits in, which is what the installed copy has above it.
ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || ROOT=""
  [ -n "$ROOT" ] || ROOT="$(cd "$DIR/.." && pwd)"
fi
if [ ! -d "$ROOT" ]; then
  echo "check-shell-syntax: '$ROOT' is not a directory, so no shell file could be parsed. Refusing rather than falling back to somewhere else, which would look exactly like having run on the one you named." >&2
  exit 2
fi

# A nested checkout is a second copy of the same tree, so a default recursive walk parses every
# file once per worktree and can report a failure that belongs to somebody else's branch (L234).
# .git and node_modules are excluded for the ordinary reason: nothing in them is ours.
files="$(find "$ROOT" \
  \( -name .git -o -name node_modules -o -name worktrees \) -prune -o \
  -type f -print 2>/dev/null)"

n=0
bad=0
report=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # A shell file by NAME, or by what its shebang says it is, so claude-sync and any extensionless
  # hook are read too. Matched on sh and bash only: a python or node script is not ours to parse.
  case "$f" in
    *.sh) ;;
    *)
      # Read into a variable and matched with `case`, never piped into a short circuiting consumer:
      # under pipefail a `grep -q` that exits on its first match kills the producer feeding it, and
      # the pipeline then reports a failure that never happened (L183). test-pipefail-shortcircuit.sh
      # is the guard that catches this shape, and it caught this line.
      _first="$(head -n 1 "$f" 2>/dev/null || true)"
      case "$_first" in
        '#!'*bash*|'#!'*/sh|'#!'*/sh\ *|'#!'*env\ sh) ;;
        *) continue ;;
      esac ;;
  esac
  n=$((n + 1))
  if ! out="$(bash -n "$f" 2>&1)"; then
    bad=$((bad + 1))
    report="$report  ${f#$ROOT/}
$(printf '%s' "$out" | sed 's/^/    /')
"
  fi
done <<EOF
$files
EOF

if [ "$n" -eq 0 ]; then
  echo "check-shell-syntax: found no shell file at all under '$ROOT', so nothing was parsed. Refusing rather than reporting a clean sweep of nothing (L98)." >&2
  exit 2
fi

if [ "$bad" -gt 0 ]; then
  echo "check-shell-syntax: $bad of $n shell file(s) under '$ROOT' do not parse, so whatever runs them fails at the first line rather than where the fault is:" >&2
  printf '%s' "$report" >&2
  echo "Parsed with bash $BASH_VERSION. If a message names the end of the file while looking for a matching quote, look for a prose comment holding an apostrophe inside a \$( ) substitution: bash does not honour a comment while scanning for the closing paren, so the apostrophe opens a quote that never closes. Write the word without the apostrophe, or move the comment outside the substitution." >&2
  exit 1
fi

echo "check-shell-syntax: $n shell file(s) under '$ROOT' parsed, with bash $BASH_VERSION."
exit 0
