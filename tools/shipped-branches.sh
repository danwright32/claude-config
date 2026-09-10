#!/usr/bin/env bash
#
# shipped-branches.sh: which remote branches have already shipped, and which have not.
#
# Why this exists (claude-config#358): in a repo that SQUASHES on merge, a merged branch is never
# an ancestor of the default branch, so every local way of asking reports every branch as unmerged
# (L642). claude-config had 48 of them. The cost is not the clutter: a branch holding real
# unfinished work sits in that list looking exactly like the ones that shipped months ago, so
# nobody can find it and nobody dares delete anything either.
#
# Two signals, and they are not equally strong, so the report says which one it used:
#
#   ancestor   the branch tip really is reachable from the default branch. That is PROOF.
#   subject    a commit on the default branch carries one of the branch's own commit subjects,
#                which is what a squash merge leaves behind. That is a GUESS, and a good one:
#                five out of five sampled by hand on 2026-09-10 matched this way.
#
# UNMATCHED means LOOK AT THIS. It never means delete it. A branch whose title was reworded when
# it merged is a false negative, and acting on a false negative destroys the one branch in the
# list that mattered (L5). So this prints and returns; it removes nothing, checks nothing out, and
# moves no ref. A checkout on this machine can be shared by concurrent sessions, and a branch
# operation moves whatever is standing on it.
#
# Exit 2 on a target it cannot use, rather than falling back to the current directory: a run about
# the wrong repo looks exactly like a run about the right one afterwards (L320).

set -uo pipefail

SUBJECT_SCAN_DEPTH="${SHIPPED_BRANCHES_SCAN_DEPTH:-40}"

fail() {
  printf 'shipped-branches: %s\n' "$1" >&2
  exit 2
}

repo="${1:-$PWD}"
[ -d "$repo" ] || fail "there is no directory at $repo"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "$repo is not a git checkout, so there are no branches here to judge"

# The default branch, from the remote's own HEAD where it says, and from the checkout's current
# branch only as a fallback. Named rather than assumed, because judging against the wrong branch
# reports every branch as unshipped and reads exactly like a repo full of abandoned work.
default="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
[ -n "$default" ] || default="origin/$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
git -C "$repo" rev-parse --verify --quiet "$default" >/dev/null 2>&1 \
  || fail "cannot work out which branch things merge into ($default is not a ref here)"

# Every remote branch except the default and the symbolic HEAD.
branches="$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/remotes/origin \
  | grep -v '^origin/HEAD$' | grep -vx "$default" || true)"

if [ -z "$branches" ]; then
  printf 'shipped-branches: %s has no branches besides %s, so there is nothing to judge.\n' \
    "$repo" "$default"
  exit 0
fi

# The default branch's subjects, read ONCE. A lookup per branch per commit over a growing history
# is the same scan repeated, and the input is identical every time (L573).
subjects="$(mktemp "${TMPDIR:-/tmp}/shipped-branches.subjects.XXXXXXXX")" || fail "no scratch file"
trap 'rm -f "$subjects"' EXIT
git -C "$repo" log --format='%H %s' "$default" > "$subjects" 2>/dev/null

shipped=0
unmatched=0
printf 'shipped-branches: %s, judged against %s\n\n' "$repo" "$default"

while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  tip="$(git -C "$repo" rev-parse --verify --quiet "$branch" 2>/dev/null || true)"
  if [ -z "$tip" ]; then
    printf '  UNMATCHED  %-46s (its tip could not be read)\n' "$branch"
    unmatched=$((unmatched + 1)); continue
  fi

  if git -C "$repo" merge-base --is-ancestor "$tip" "$default" 2>/dev/null; then
    printf '  SHIPPED    %-46s ancestor of %s\n' "$branch" "$default"
    shipped=$((shipped + 1)); continue
  fi

  hit=""
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    hit="$(grep -m1 -F -- "$subject" "$subjects" 2>/dev/null || true)"
    [ -n "$hit" ] && break
  done <<EOF
$(git -C "$repo" log --format='%s' --max-count="$SUBJECT_SCAN_DEPTH" "$default..$branch" 2>/dev/null)
EOF

  if [ -n "$hit" ]; then
    printf '  SHIPPED    %-46s subject match: %s\n' "$branch" "${hit:0:72}"
    shipped=$((shipped + 1))
  else
    printf '  UNMATCHED  %-46s nothing on %s carries any of its subjects\n' "$branch" "$default"
    unmatched=$((unmatched + 1))
  fi
done <<EOF
$branches
EOF

printf '\n  %d shipped, %d unmatched.\n' "$shipped" "$unmatched"
if [ "$unmatched" -gt 0 ]; then
  printf '  An UNMATCHED branch is one to look at, not one to act on: a branch reworded when it\n'
  printf '  merged looks exactly like this. Read one with: git -C %s log --oneline %s..<branch>\n' \
    "$repo" "$default"
fi
printf '  Nothing here was changed: no ref was moved and no branch was removed.\n'
exit 0
