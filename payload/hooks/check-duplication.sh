#!/usr/bin/env bash
#
# check-duplication.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `git push` that ADDS duplicated code to a repo's source tree (claude-config#428).
# "Consolidate from the start" (CLAUDE.md) and L613 were prompt rules with nothing behind them
# (L27): the 2026-09-18 dev team review of Slate found one button class string hand written at
# eleven sites, one comparator copied five times and one table header cell written twice, and the
# twelve auditor lesson sweep three days earlier missed all of them because duplication had no
# detector shape anywhere in the config.
#
# The detector is lib/duplication.py (python3, standard library only). The verdict is a COMPARISON,
# never a stored baseline: the tree at the merge base is measured, the tree being pushed is
# measured, and the push is refused only for a duplicate group whose copy count GREW. Existing
# duplication never fails a push (Slate's is #2561 and #2562), and there is no state file to go
# stale. Source roots are found from the tree itself (src, app, lib, components, worker, scripts,
# whichever exist); a repo with none prints ONE line saying so and exits 0, because a silent skip
# is indistinguishable from a pass (L98).
#
# THRESHOLDS, measured against Slate main fc7397d7 on 2026-09-18 (796 code files read across
# src, worker, scripts; test files, fixtures and generated output skipped):
#
#   line   one normalized line of at least 100 characters appearing 2 or more times.
#          Whole tree: 29 groups (15 across files), every one a hand written copy: class strings,
#          an <svg> opener written 7 times in 2 files, DAY_NAMES in 3 files, a helper in 2. It
#          names the review's Booker finding as two groups: 3 identical lines (Booker.tsx 1036,
#          1144, 1196) and a pair (1022, 1174), once `${...}` interpolations are blanked.
#          Replayed over the last 40 real commits on main, parent against child: fired on 2, both
#          genuine copies (a long error <div> class string, a not-configured message).
#          At 60 characters it is 411 groups and fired on 19 of 40; at 100 chars and 3 copies it
#          fired on 0 of 40 and misses the pair.
#
#   block  2 consecutive non-trivial lines totalling at least 160 characters, in 2 or more places.
#          Whole tree: 16 groups (10 across files). Replay: fired on 4 of 40, each a real copy (a
#          deps type, the entry point idiom in the bare node alerters, a JSX pair).
#          The review's day header cell (AvailabilityGridTable.tsx:67-68 against
#          BucketSupplyTable.tsx:233-234) is 131 characters over its two identical lines and is
#          NOT caught at this setting. Catching it needs 131 or lower, and at 130 the guard fired
#          on 10 of the 40 real commits (25%), mostly the tenth and eleventh copy of a two line
#          `notify:/resolve:` deps type; at 120 it is 108 groups and 12 of 40. That is the dense
#          middle of the distribution (L172), so the header stays out and the trade is written
#          here rather than paid by every push (L36).
#
#   The review's comparator (`return a < b ? -1 : a > b ? 1 : 0;`, 36 characters) is identical at
#   only two of its five sites; the rest differ in field names or direction. Catching the pair
#   needs a 36 character floor at 2 copies, which is 1,440 groups and fired on 27 of 40. Out of
#   reach for a text detector; a semantic one is a different tool.
#
#   Together: 45 groups in the whole tree at these settings, and 6 of the last 40 real commits
#   would have been refused. Three of them are the positive controls on real history, replayed
#   through the shipped `compare` on 2026-09-18: 2cddc905 (two new long class string copies and a
#   two line block in the business hours forms), a88baccb (a second copy of a not-configured
#   message across two scripts) and 325d3af9 (a third copy of the alerter entry idiom, "the base
#   had 2").
#
# Runtime on the Slate tree: 1.45s end to end (payload in, both archives, both scans, verdict out),
# three runs on 2026-09-18, all within 0.01s of each other. Suggested hook timeout: 60s.
#
# What is read on the pushed side: the COMMITS (HEAD) for a plain push. When the same command
# commits before it pushes, nothing is in history yet, so the working tree of the source roots is
# read instead (tracked files plus untracked ones git does not ignore) and the refusal SAYS so,
# because a line from a file that commit will not carry may then be named (L11, claude-config#350).
#
# Override: SKIP_DUPLICATION_CHECK=1 git push ...   Explain why to the user first, in plain
# language, same as the test gate. Never skip silently. The skip prints one line either way.
#
# Fails OPEN: any parse or git error prints one line saying what could not be measured and allows
# the push.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
DETECTOR="$HOOK_DIR/lib/duplication.py"

payload="$(cat)"

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0

if ps_has_override "$cmd" SKIP_DUPLICATION_CHECK; then
  echo "duplication check: skipped because the command carries SKIP_DUPLICATION_CHECK=1; nothing was compared."
  exit 0
fi

# One line on every path that measured nothing, so a skip never reads as a pass (L98).
skip() { echo "duplication check: skipped, $1"; exit 0; }

[ -f "$DETECTOR" ] || skip "the detector $DETECTOR is not installed, so nothing was compared."
command -v python3 >/dev/null 2>&1 || skip "python3 is not on the PATH, so nothing was compared."

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || skip "no git work tree could be found for this command, so nothing was compared."
[ -n "$repo_dir" ] || skip "no git work tree could be found for this command, so nothing was compared."
cd "$repo_dir" 2>/dev/null || skip "could not enter $repo_dir, so nothing was compared."

# Does this same command commit before it pushes? Then nothing is in history yet and the pushed
# side has to be read from the working tree (claude-config#350).
from_worktree=0
ps_commit_in_chain "$cmd" && from_worktree=1

# Which source roots the pushed side holds. Asked of the detector, so the list exists once.
root_names="$(python3 "$DETECTOR" root-names 2>/dev/null)"
head_roots="$(git ls-tree --name-only HEAD 2>/dev/null | python3 "$DETECTOR" roots 2>/dev/null)"
if [ "$from_worktree" -eq 1 ]; then
  # A commit in this same command may be adding the first source root, which HEAD cannot show.
  wt_roots="$(ls -1 2>/dev/null | python3 "$DETECTOR" roots 2>/dev/null)"
  head_roots="$(printf '%s\n%s\n' "$head_roots" "$wt_roots" | awk 'NF && !seen[$0]++')"
fi
[ -n "$head_roots" ] || skip "$(basename "$repo_dir") has none of the source roots this reads ($root_names)."

# What the push is measured against, from the shared helpers (claude-config#339). Where the range
# starts is the shared contract too (claude-config#441): a command that commits first has its own
# entry point, because its pending commit is the change and the last commit already on the remote
# is not this push's to answer for. This hook kept a private version of that rule, which also took
# HEAD as the base when the base was only the local branch itself, so an unpushed last commit was
# never compared.
base="$(ps_base_ref || true)"
if [ "$from_worktree" -eq 1 ]; then
  mb="$(ps_pending_base "$base")"
else
  mb="$(ps_merge_base "$base")"
fi
[ -n "$mb" ] || skip "no base commit could be worked out for this push (no upstream, no origin/main, no previous commit), so nothing was compared."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.dupcheck.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") skip "a throwaway directory could not be made, so nothing was compared." ;;
esac
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/base" "$WORK/head"

# The base tree: only the roots that exist at the merge base. A first push that creates src/ has
# an empty base, and everything duplicated in it is then genuinely new.
base_roots="$(git ls-tree --name-only "$mb" 2>/dev/null | python3 "$DETECTOR" roots 2>/dev/null)"
if [ -n "$base_roots" ]; then
  # shellcheck disable=SC2086
  if ! git archive "$mb" $base_roots 2>/dev/null | tar -x -C "$WORK/base" 2>/dev/null; then
    skip "the tree at $(git rev-parse --short "$mb" 2>/dev/null) could not be read, so nothing was compared."
  fi
fi

# The pushed tree.
pushed_dir="$WORK/head"
compare_args=()
if [ "$from_worktree" -eq 1 ]; then
  pushed_dir="$repo_dir"
  # shellcheck disable=SC2086
  {
    git ls-files -- $head_roots 2>/dev/null
    git ls-files --others --exclude-standard -- $head_roots 2>/dev/null
  } | awk 'NF && !seen[$0]++' > "$WORK/pushed-files"
  compare_args=(--pushed-files-from "$WORK/pushed-files")
else
  # shellcheck disable=SC2086
  if ! git archive HEAD $head_roots 2>/dev/null | tar -x -C "$WORK/head" 2>/dev/null; then
    skip "the tree at HEAD could not be read, so nothing was compared."
  fi
fi

report="$(python3 "$DETECTOR" compare "$WORK/base" "$pushed_dir" "${compare_args[@]}" 2>"$WORK/err")"
rc=$?
summary="$(printf '%s\n' "$report" | awk 'NR == 1')"
body="$(printf '%s\n' "$report" | awk 'NR > 1')"

if [ "$rc" -eq 0 ]; then
  echo "duplication check: no new duplicate groups ($summary; against $(git rev-parse --short "$mb" 2>/dev/null))."
  exit 0
fi
if [ "$rc" -ne 1 ]; then
  skip "the detector failed ($(awk 'NR == 1' "$WORK/err" 2>/dev/null)), so nothing was compared."
fi

# The refusal may claim only what it measured (L11).
{
  base_label="$(git rev-parse --short "$mb" 2>/dev/null)"
  [ -n "$base" ] && base_label="$base_label (the merge base with $base)"
  if [ "$from_worktree" -eq 1 ]; then
    echo "PUSH BLOCKED: the commit this command is about to make would add duplicated code"
    echo "that the base did not have."
  else
    echo "PUSH BLOCKED: this push adds duplicated code that the base did not have."
  fi
  echo "CLAUDE.md asks for one implementation from the start (Consolidate from the start,"
  echo "L613); this is the check behind that rule."
  echo ""
  echo "Compared against $base_label, in $(printf '%s' "$head_roots" | tr '\n' ' ' | sed 's/ *$//' | sed 's/ /, /g'):"
  printf '%s\n' "$body"
  echo ""
  if [ "$from_worktree" -eq 1 ]; then
    echo "Read from the working tree, because this command commits before it pushes and"
    echo "nothing is in history yet. A line above may belong to a file this commit will not"
    echo "carry. To judge the commits only, run the commit and the push as"
    echo "two separate commands: a push on its own judges the commits only."
    echo ""
  fi
  echo "Move the copied code into one shared function, component or constant and call it"
  echo "from every site, then push again. Duplication that was already there does not block"
  echo "a push; only what this push adds does."
  echo "OVERRIDE: if this is a false positive (a copy that genuinely cannot share code),"
  echo "re-run with:"
  echo "    SKIP_DUPLICATION_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, WHY skipping is legitimate here, so they can judge whether it"
  echo "makes sense. Never override silently."
} >&2
exit 2
