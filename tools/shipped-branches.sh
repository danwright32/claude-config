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
# Three signals, read in this order, and they are not equally strong, so the report says which one
# it used:
#
#   ancestor   the branch tip really is reachable from the default branch. That is PROOF.
#   merged     GitHub reports a merged pull request from the branch whose head is the branch tip or
#                holds it (claude-config#459). That is PROOF too, and it catches a branch whose
#                title was reworded at merge, which the subject guess misses. A merge of an EARLIER
#                commit proves nothing about work pushed to the same name since, and is said so.
#   subject    a commit on the default branch carries one of the branch's own commit subjects,
#                which is what a squash merge leaves behind. That is a GUESS, and a good one:
#                five out of five sampled by hand on 2026-09-10 matched this way.
#
# GitHub is read through lib/pull-requests.sh, the one reading shipped-worktrees.sh uses. When it
# cannot be read this does not refuse, because it changes nothing: it says so once, stops asking
# (each further call would pay the same offline timeout), and falls back to the subject guess on
# every row, labelled "GitHub not read". Unreadable is never reported as unmerged (L98).
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
libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for lib in default-branch.sh pull-requests.sh; do
  [ -f "$libdir/$lib" ] || fail "its library is missing: $libdir/$lib"
done
# shellcheck source=lib/default-branch.sh
. "$libdir/default-branch.sh"
# shellcheck source=lib/pull-requests.sh
. "$libdir/pull-requests.sh"
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
rows=()
row() {  # row <verdict> <branch> <detail>
  rows+=("$(printf '  %-9s  %-46s %s' "$1" "$2" "$3")")
}

# GitHub is asked until it first fails, then not again: every later call would pay the same
# offline timeout to say the same thing.
gh_readable=1
gh_said=""

while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  tip="$(git -C "$repo" rev-parse --verify --quiet "$branch" 2>/dev/null || true)"
  if [ -z "$tip" ]; then
    row UNMATCHED "$branch" "(its tip could not be read)"
    unmatched=$((unmatched + 1)); continue
  fi

  if git -C "$repo" merge-base --is-ancestor "$tip" "$default" 2>/dev/null; then
    row SHIPPED "$branch" "ancestor of $default"
    shipped=$((shipped + 1)); continue
  fi

  # MERGED, from GitHub. A merge proves the head it recorded shipped, so it proves this branch
  # only when the tip is that head or inside it. stdin is closed because this loop reads its
  # branches from it and nothing gh runs may eat them.
  pr_note="GitHub not read"
  if [ "$gh_readable" = 1 ]; then
    if prs="$(pull_requests "$repo" "${branch#origin/}" </dev/null)"; then
      proven=""
      earlier=""
      while read -r state number oid; do
        [ "${state:-}" = MERGED ] || continue
        if [ "${oid:-}" = "$tip" ] || { [ -n "${oid:-}" ] \
            && git -C "$repo" merge-base --is-ancestor "$tip" "$oid" 2>/dev/null; }; then
          proven="$number"; break
        fi
        earlier="${earlier:+$earlier, }#$number"
      done <<< "$prs"
      open="$(awk '$1 == "OPEN" { printf "%s#%s", (n++ ? ", " : ""), $2 }' <<< "$prs")"
      if [ -n "$proven" ]; then
        row SHIPPED "$branch" "pull request #$proven merged$([ -z "$open" ] || printf ' (%s still open)' "$open")"
        shipped=$((shipped + 1)); continue
      fi
      if [ -n "$earlier" ]; then pr_note="pull request $earlier merged an earlier commit than its tip"
      elif [ -n "$open" ]; then pr_note="pull request $open still open"
      else pr_note="no merged pull request"
      fi
    else
      gh_readable=0
      gh_said="$prs"
    fi
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
    row SHIPPED "$branch" "subject match, a guess ($pr_note): ${hit:0:72}"
    shipped=$((shipped + 1))
  else
    row UNMATCHED "$branch" "nothing on $default carries any of its subjects ($pr_note)"
    unmatched=$((unmatched + 1))
  fi
done <<EOF
$branches
EOF

# The header is written after the rows are judged, because whether GitHub could be read is only
# known once it has been asked, and that belongs above the rows it qualifies.
printf 'shipped-branches: %s, judged against %s\n' "$repo" "$default"
printf '  merged means GitHub reports a merged pull request from the branch, read with gh.\n'
if [ "$remote_read" = 1 ]; then
  printf '  branches read from the remote itself.\n'
else
  printf '  the remote could not be read, so this is what this clone remembered at its last fetch\n'
  printf '  and a branch deleted on the server since then still appears below. Refresh it with:\n'
  printf '  git -C %s fetch --prune\n' "$repo"
fi
if [ "$gh_readable" = 0 ]; then
  printf '  GitHub could not be read, so no row below rests on a pull request: a row marked\n'
  printf '  "GitHub not read" fell back to the subject guess, and is neither merged nor unmerged.\n'
  printf '  gh said:\n'
  printf '%s\n' "$gh_said" | sed 's/^/    /'
fi
printf '\n'
[ "${#rows[@]}" -eq 0 ] || printf '%s\n' "${rows[@]}"

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
