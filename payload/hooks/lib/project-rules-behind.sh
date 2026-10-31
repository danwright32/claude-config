#!/usr/bin/env bash
#
# project-rules-behind.sh: whether the session starting in <cwd> loaded a project rules file older
# than the copy on origin (claude-config#1939). Sourced, never run. rule-files-changed.sh asks it at
# SessionStart and says the answer once per session.
#
# WHY. Bidspoke cut its CLAUDE.md from 36,964 to 20,423 characters on 2026-10-29 (bidspoke#3050,
# #3062), and a day later the cut had reached no session. Every session, and every agent in a
# worktree nested inside the checkout, loads the project rules from the PRIMARY checkout: Claude Code
# reads CLAUDE.md in the folder a session starts in and in every folder above it, so a worktree under
# <primary>/.claude/worktrees loads <primary>/CLAUDE.md as an ancestor. That checkout sat on main 22
# commits behind origin/main, so all 12 sessions started after the merge loaded the old file, and
# nothing said so. The repository's own budget test passed, because it reads the committed file.
#
# WHAT COUNTS. The primary checkout is the folder holding the repository's .git, found from <cwd>
# through git's common directory, and only when <cwd> lies inside it (a worktree outside it does not
# load its CLAUDE.md). It must be on the default branch, read from origin/HEAD, or, when origin/HEAD
# was never recorded, a branch named main or master, and behind the origin copy of that branch. A
# primary on a feature branch is somebody's work in progress, not a stale default, and says nothing.
# The rule files are CLAUDE.md, .claude/CLAUDE.md, AGENTS.md, the .claude/rules folder, and every
# file those import with an @path, followed through the local copies. One is named only when origin
# changed it since the checkout's commit: a file that differs only by an uncommitted local edit is
# the person's own work, not staleness.
#
# COST. This runs at every session start, so the current case costs exactly two git processes and
# nothing else: one to find the primary, one to read HEAD and origin's sha and names together. No
# fetch, ever: a network call on every start would cost seconds offline and on a slow link, and the
# origin ref on disk is kept fresh by every worktree that fetches (worktrees share refs). So the
# notice says how old that ref is, from the newest of FETCH_HEAD and the ref's own files, rather than
# claiming to know where origin is now. Everything past the equality test runs only when the
# checkout really is behind, where a notice is about to be said anyway. test-per-prompt-hook-cost.sh
# holds the two.
#
# IT NEVER CHANGES THE CHECKOUT. Another session may be standing on it, so the hook runs no fetch,
# pull, merge, checkout or reset. "Offer the fast forward" means the notice names the one command,
# and only when it can only fast forward: no commits of its own on the branch, and no changes to
# tracked files. Untracked and ignored files (a cache, node_modules) do not withhold it, since a
# fast forward that would overwrite one is refused by git itself.
#
#   project_rules_behind <cwd>
#       sets PRB_TEXT (for the person) and PRB_CONTEXT (for the session) when the checkout is behind
#       on a rule file, and leaves both empty otherwise. Always returns 0.
#
# Env: PROJECT_RULES_NOW, the clock in epoch seconds, for a test to render the age deterministically;
#      PROJECT_RULES_PYTHON, the interpreter that reads the counts (default python3), for a test to
#      make that reading fail.

PRB_TEXT=""
PRB_CONTEXT=""

# The shared number check, from beside this file whoever sources it.
case "${BASH_SOURCE[0]}" in */*) _prb_dir="${BASH_SOURCE[0]%/*}" ;; *) _prb_dir=. ;; esac
# shellcheck source=whole-number.sh
. "$_prb_dir/whole-number.sh" 2>/dev/null || true

project_rules_behind() {
  PRB_TEXT=""; PRB_CONTEXT=""
  local cwd="${1:-}" common primary here lines head_sha origin_sha head_ref origin_ref branch counts ahead behind
  [ -n "$cwd" ] || return 0
  command -v git >/dev/null 2>&1 || return 0

  # 1. The primary checkout: the folder holding the common .git directory.
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  case "$common" in */.git) primary="${common%/.git}" ;; *) return 0 ;; esac
  # Both sides resolved, in bash, so a link in either path cannot make an inside folder look outside.
  here="$(cd "$cwd" 2>/dev/null && pwd -P)" || return 0
  primary="$(cd "$primary" 2>/dev/null && pwd -P)" || return 0
  case "$here/" in "$primary/"*) ;; *) return 0 ;; esac

  # 2. HEAD and origin's default branch, shas then names, in one process.
  lines="$(git -C "$primary" rev-parse HEAD origin/HEAD --symbolic-full-name HEAD origin/HEAD 2>/dev/null)" || lines=""
  { read -r head_sha; read -r origin_sha; read -r head_ref; read -r origin_ref; } <<< "$lines"
  if [ -z "$lines" ]; then
    # No origin/HEAD recorded (a repository not made by clone). Only a branch whose name says it is
    # the default is judged; anything else could be a feature branch.
    lines="$(git -C "$primary" rev-parse --symbolic-full-name HEAD 2>/dev/null)" || return 0
    case "$lines" in refs/heads/main|refs/heads/master) ;; *) return 0 ;; esac
    head_ref="$lines"
    origin_ref="refs/remotes/origin/${lines#refs/heads/}"
    lines="$(git -C "$primary" rev-parse HEAD "$origin_ref" 2>/dev/null)" || return 0
    { read -r head_sha; read -r origin_sha; } <<< "$lines"
  fi
  [ -n "$head_sha" ] && [ -n "$origin_sha" ] || return 0
  [ "$head_sha" = "$origin_sha" ] && return 0
  case "$origin_ref" in refs/remotes/origin/?*) branch="${origin_ref#refs/remotes/origin/}" ;; *) return 0 ;; esac
  [ "$head_ref" = "refs/heads/$branch" ] || return 0

  # Past here the checkout is on its default branch and not at origin's commit.
  counts="$(git -C "$primary" rev-list --left-right --count "HEAD...$origin_ref" 2>/dev/null)" || return 0
  read -r ahead behind <<< "$counts"
  # Read through the one whole number check (lib/whole-number.sh, claude-config#1948). Missing, it
  # answers 127, read as not behind, so the start says nothing rather than something unmeasured.
  whole_above_zero "$behind" behind 2>/dev/null || return 0
  whole_above_zero "$ahead" ahead 2>/dev/null || ahead=0

  # 3. Which rule files origin changed since this checkout's commit.
  local files=() changed
  while IFS= read -r changed; do [ -n "$changed" ] && files+=("$changed"); done < <(_prb_rule_files "$primary")
  changed="$(git -C "$primary" --literal-pathspecs diff --name-only HEAD "$origin_ref" -- "${files[@]}" .claude/rules 2>/dev/null)" || return 0
  [ -n "$changed" ] || return 0

  # 4. The counts and the age, in one python3, which reads origin's copies through one git.
  local detail
  detail="$(printf '%s\n' "$changed" | PRB_NOW="${PROJECT_RULES_NOW:-}" "${PROJECT_RULES_PYTHON:-python3}" -c '
import os, subprocess, sys, time
primary, common, ref, label = sys.argv[1:5]
paths = [p for p in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines() if p]
def chars(b):
    return None if b is None else len(b.decode("utf-8", "replace"))
proc = subprocess.run(["git", "-C", primary, "cat-file", "--batch"],
                      input="".join("%s:%s\n" % (ref, p) for p in paths).encode("utf-8", "replace"),
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
out, theirs, i = proc.stdout, {}, 0
for p in paths:
    j = out.index(b"\n", i)
    head = out[i:j].split()
    i = j + 1
    if len(head) == 3:
        n = int(head[2]); theirs[p] = out[i:i + n]; i += n + 1
    else:
        theirs[p] = None
parts = []
for p in paths:
    try:
        mine = open(os.path.join(primary, p), "rb").read()
    except OSError:
        mine = None
    a, b = chars(mine), chars(theirs[p])
    if a is None:
        parts.append("%s (not in this checkout; %s has %s characters)" % (p, label, format(b, ",")))
    elif b is None:
        parts.append("%s (this session loaded %s characters; %s has removed it)" % (p, format(a, ","), label))
    else:
        parts.append("%s (this session loaded %s characters; %s has %s)" % (p, format(a, ","), label, format(b, ",")))
print("; ".join(parts))
newest = 0
for f in ("FETCH_HEAD", "refs/remotes/origin/" + label.split("/", 1)[1], "logs/refs/remotes/origin/" + label.split("/", 1)[1]):
    try:
        newest = max(newest, os.path.getmtime(os.path.join(common, f)))
    except OSError:
        pass
now = int(os.environ.get("PRB_NOW") or time.time())
if not newest:
    print("at an unknown time")
else:
    s = max(0, now - int(newest))
    for unit, size in (("day", 86400), ("hour", 3600), ("minute", 60)):
        if s >= size:
            n = s // size
            print("%d %s%s ago" % (n, unit, "" if n == 1 else "s")); break
    else:
        print("under a minute ago")
' "$primary" "$common" "$origin_ref" "origin/$branch" 2>/dev/null)" || detail=""
  local named age
  named="$(printf '%s\n' "$detail" | sed -n 1p)"
  age="$(printf '%s\n' "$detail" | sed -n 2p)"
  # By here the files are known to differ, so a reading that failed (no python3, an unreadable
  # object) still names them, and says the sizes and the age were not read rather than going quiet
  # about a stale checkout (L11).
  if [ -z "$named" ]; then
    named="$(printf '%s\n' "$changed" | tr '\n' ',' | sed 's/,$//; s/,/, /g') (the character counts could not be read here)"
    age="at a time that could not be read"
  fi

  local s_behind="commits" s_ahead="commits" offer
  [ "$behind" = 1 ] && s_behind="commit"
  [ "$ahead" = 1 ] && s_ahead="commit"
  if [ "$ahead" -gt 0 ]; then
    offer="$branch also has $ahead $s_ahead origin/$branch does not have, so it cannot simply be fast forwarded; bring it up to date by hand."
  else
    local dirty
    dirty="$(git -C "$primary" status --porcelain --untracked-files=no 2>/dev/null | awk 'END { print NR }')"
    case "$dirty" in ''|*[!0-9]*) dirty=1 ;; esac
    if [ "$dirty" -gt 0 ]; then
      offer="The checkout has changes to tracked files, so no fast forward is offered; bring it up to date by hand once they are dealt with."
    else
      offer="The checkout has no changes to tracked files, so this brings it up to date for the next session: git -C '$primary' pull --ff-only"
    fi
  fi
  PRB_TEXT="This session loaded project rules older than origin's. $primary is on $branch, $behind $s_behind behind origin/$branch as this Mac last fetched it ($age), and origin changed these rule files since: $named. $offer"
  local first
  first="$(printf '%s\n' "$changed" | sed -n 1p)"
  PRB_CONTEXT="$PRB_TEXT Before relying on what the loaded copy says, read the current one, for example with: git -C '$primary' show origin/$branch:$first"
  return 0
}

# The rule files a session loads from <primary>, as paths relative to it: the three Claude Code
# reads at the root, then every @path they import, followed through the local copies. Claude Code
# takes an @path anywhere in the text, so a token is read wherever it starts a word. An absolute,
# home or parent path points outside the checkout, so it is not this check's. Bounded, so a cycle or
# a file of nothing but @ tokens cannot run on.
_prb_rule_files() {
  local primary="$1" queue=(CLAUDE.md .claude/CLAUDE.md AGENTS.md) seen="|" i=0 f dir line t words w
  while [ "$i" -lt "${#queue[@]}" ] && [ "$i" -lt 200 ]; do
    f="${queue[$i]}"; i=$((i + 1))
    case "$seen" in *"|$f|"*) continue ;; esac
    seen="$seen$f|"
    printf '%s\n' "$f"
    [ -f "$primary/$f" ] || continue
    case "$f" in */*) dir="${f%/*}/" ;; *) dir="" ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *@*) ;; *) continue ;; esac
      read -r -a words <<< "$line"
      for w in "${words[@]}"; do
        case "$w" in @?*) ;; *) continue ;; esac
        t="${w#@}"
        case "$t" in /*|'~'*|*..*) continue ;; esac
        t="${t#./}"
        queue+=("$dir$t")
      done
    done < "$primary/$f"
  done
}
