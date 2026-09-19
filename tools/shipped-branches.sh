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

# The default branch, from the one rule shipped-worktrees.sh uses too. A missing library is a
# refusal, never a run that carries on without it (L488).
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/default-branch.sh"
[ -f "$lib" ] || fail "its library is missing: $lib"
# shellcheck source=lib/default-branch.sh
. "$lib"
default="$(default_branch "$repo")" \
  || fail "cannot work out which branch things merge into ($default is not a ref here)"

# WHICH BRANCHES EXIST, asked of the remote rather than of this clone's memory of it.
#
# The first version read refs/remotes/origin, which is only as current as the last prune. On the
# real repo that copy held 50 branches while the remote held exactly one: every other branch had
# been deleted on the server long ago and nothing here had noticed. The tool then reported at
# length on 49 branches that do not exist, and the first command run on the strength of it failed
# with "remote ref does not exist". A report about a list nobody checked against its source is the
# thing this tool exists to replace (L11, L175).
#
# So the remote is asked. When it cannot be reached the remembered copy is used and that is said
# plainly, because a stale answer that admits it is stale is worth more than nothing to somebody
# offline, and worth much more than a stale answer presented as current (L98).
remote_heads="$(git -C "$repo" ls-remote --heads origin 2>/dev/null | awk '{print $2}' | sed 's#^refs/heads/#origin/#' || true)"
remote_read=1
[ -n "$remote_heads" ] || remote_read=0

tracked="$(git -C "$repo" for-each-ref --format='%(refname)' refs/remotes/origin \
  | grep -v '^refs/remotes/origin/HEAD$' \
  | sed 's#^refs/remotes/##' || true)"

if [ "$remote_read" = 1 ]; then
  branches="$(printf '%s\n' "$remote_heads" | grep -vx "$default" || true)"
  # Refs this clone still remembers for branches the remote no longer has. Not work, and not a
  # verdict about work: a local tidy up, named as one.
  gone="$(comm -23 \
    <(printf '%s\n' "$tracked" | grep -vx "$default" | sort) \
    <(printf '%s\n' "$remote_heads" | sort) 2>/dev/null || true)"
else
  branches="$(printf '%s\n' "$tracked" | grep -vx "$default" || true)"
  gone=""
fi

if [ -z "$branches" ] && [ -z "$gone" ]; then
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
gone_count=0
printf 'shipped-branches: %s, judged against %s\n' "$repo" "$default"
if [ "$remote_read" = 1 ]; then
  printf '  branches read from the remote itself.\n\n'
else
  printf '  the remote could not be read, so this is what this clone remembered at its last fetch\n'
  printf '  and a branch deleted on the server since then still appears below. Refresh it with:\n'
  printf '  git -C %s fetch --prune\n\n' "$repo"
fi

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

while IFS= read -r stale; do
  [ -n "$stale" ] || continue
  printf '  GONE       %-46s no longer on the remote; this clone still remembers it\n' "$stale"
  gone_count=$((gone_count + 1))
done <<EOF
$gone
EOF

printf '\n  %d shipped, %d unmatched, %d gone from the remote.\n' "$shipped" "$unmatched" "$gone_count"
if [ "$gone_count" -gt 0 ]; then
  printf '  A GONE branch is not work and not a verdict about work: the branch was removed on the\n'
  printf '  server and this clone has not caught up. Clear those with: git -C %s fetch --prune\n' "$repo"
fi
if [ "$unmatched" -gt 0 ]; then
  printf '  An UNMATCHED branch is one to look at, not one to act on: a branch reworded when it\n'
  printf '  merged looks exactly like this. Read one with: git -C %s log --oneline %s..<branch>\n' \
    "$repo" "$default"
fi
printf '  Nothing here was changed: no ref was moved and no branch was removed.\n'
exit 0
