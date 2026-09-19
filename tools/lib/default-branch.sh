# default-branch.sh: which remote branch a checkout's work merges into. Sourced, not run.
#
# One copy, shared by shipped-branches.sh and shipped-worktrees.sh, because both judge work
# against it and two copies of "which branch is main" drift apart with no symptom (L613).
#
# default_branch <repo>
#   Prints the branch, like origin/main, from the remote's own HEAD where it says, and from the
#   checkout's current branch only as a fallback. Named rather than assumed, because judging
#   against the wrong branch reports every branch as unshipped and reads exactly like a repo full
#   of abandoned work. Returns 1, printing the name it tried, when that name is not a ref here.

default_branch() {
  local repo="$1" name
  name="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [ -n "$name" ] || name="origin/$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  printf '%s\n' "$name"
  git -C "$repo" rev-parse --verify --quiet "$name" >/dev/null 2>&1
}
