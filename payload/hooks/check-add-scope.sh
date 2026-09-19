#!/usr/bin/env bash
#
# check-add-scope.sh
# Claude Code PreToolUse(Bash) hook: refuse an UNSCOPED `git add` when the checkout holds changes
# this session did not make (claude-config#366).
#
# CLAUDE.md already says to scope every `git add` to named paths, never `-A` or `.`, because a
# checkout is routinely shared by concurrent sessions. Nothing enforced it. On 2026-09-10 a session
# working on claude-config#362 committed with an unscoped add and carried another session's half
# finished generator change and its six tests into commits 580842f and after, under a message that
# does not describe them, and pushed them. The work was correct so nothing broke, but it was judged
# by a test gate that was not asked about it and it is recorded as somebody else's change. A rule
# that lives only in a prompt is a hope (L27).
#
# It does NOT fire on a checkout with no foreign changes, because an unscoped add is fine when a
# session is alone, and a gate that fires on the ordinary case is one nobody reads (L36, L104).
#
# WHICH CHANGES ARE THIS SESSION'S is read from the session's own transcript: every file path an
# Edit or Write named, and the full text of every Bash command it ran. The second half is not
# optional. A great deal of this repo's own editing happens through heredocs and python one liners
# inside Bash, and a gate that could only see Edit calls would call all of that foreign and be
# turned off within the hour.
#
# The match is deliberately GENEROUS, on the side of allowing: a path counts as this session's if
# the session mentioned it anywhere. Being wrong that way lets one unscoped add through; being
# wrong the other way blocks ordinary work until somebody disables the gate, and then it protects
# nothing at all.
#
# The transcript is read INCREMENTALLY, from a byte offset kept beside a per session cache, because
# this runs on every git add and a transcript grows all session.
#
# Override, per this repo's convention, explained to the person first and never silently:
#   SKIP_ADD_SCOPE_CHECK=1 as an inline prefix, good for that one command.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null || true)"
parsed="$(ps_parse_payload "$payload" segmented 2>/dev/null)" || parsed=""
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cwd" ] || cwd="$PWD"

# THE READERS THIS GATE SEES THROUGH, asked before their answers are believed (claude-config#480,
# L490). ps__read_adds reads what the add takes with python3, and ps_add_takes_all compares its
# answer against the literal "yes": a missing interpreter produced no answer at all, which compared
# as NO, so this gate exited 0 on every unscoped add on such a machine with nothing said. An absent
# reader is the one failure indistinguishable from a clean run (L42, L98). The transcript this gate
# tells one session's work from another's by is read with python3 as well, so nothing is left that
# could judge the add either way.
#
# Whether to refuse is decided further down, beside the transcript refusal, so it fires only on a
# tree that actually holds changes an add could sweep up, which is the state this gate exists for.
# A command with no add in it is never asked, because an absent reader takes nothing from it (L54).
unreadable_add=0
if [ -z "$cmd" ]; then
  # Nothing read the payload at all. An empty command with a reader present is simply a tool call
  # with no command in it, and there is nothing to judge; with NO reader it is this gate's own
  # blindness, and the raw payload text is enough to say whether an add could be in there.
  ps_reader_missing jq python3 || exit 0
  case "$payload" in *SKIP_ADD_SCOPE_CHECK=1*) exit 0 ;; esac
  case "$payload" in
    *"git add"*) unreadable_add=1 ;;
    *) exit 0 ;;
  esac
else
  ps_has_override "$cmd" SKIP_ADD_SCOPE_CHECK && exit 0
  if ps_add_scope_unreadable "$cmd"; then
    unreadable_add=1
  else
    # Does any git add in the command take more than the paths it names (`-A`, `--all`, `.`, `:/`,
    # `*` or `-u`)? Asked of the shared parser, which reads each segment's leading tokens, so an
    # echo or a commit message that merely mentions one cannot fire this. This hook kept a detector
    # of its own beside that parser, and the copy had already drifted: it never saw an add inside a
    # subshell (claude-config#457, L613). A `git add` naming nothing stages nothing, so it is not
    # this shape.
    ps_add_takes_all "$cmd" || exit 0
  fi
fi

repo="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo" ] || exit 0

# Everything the add would sweep up. --porcelain gives "XY path"; a rename gives "old -> new" and
# both halves are checked, because staging a rename touches both.
changed="$(git -C "$repo" status --porcelain 2>/dev/null | sed -E 's/^.{3}//; s/^.* -> //' | sed 's/^"//; s/"$//' || true)"
[ -n "$changed" ] || exit 0

if [ "$unreadable_add" -eq 1 ]; then
  cat >&2 <<MSG
claude-sync: REFUSED a 'git add' in $repo.

$(ps_reader_absent_why "python3 is not on PATH" "check-add-scope.sh reads what a git add takes with it, through lib/push-scope.sh, and reads this session's own transcript with it too, so with python3 absent nothing here can tell an unscoped add from a scoped one, or this session's changes from another session's." "python3")

Stage the paths you actually changed, by name:

  git -C $repo add <path> [<path> ...]

The changes currently in the tree:
$(printf '%s\n' "$changed" | sed 's/^/  /')
MSG
  exit 2
fi

transcript="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("transcript_path") or "")
' 2>/dev/null || true)"

# NOT silence. Without the transcript there is no way to tell this session's work from another
# session's, and "everything is yours" is the assumption that produced the incident. Refusing is
# the safe direction and costs one override; the other direction costs somebody else's work being
# committed under a message that does not describe it (L42, L98).
if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
  cat >&2 <<MSG
claude-sync: REFUSED an unscoped 'git add' in $repo.

This checkout holds changes, and this hook could not read the session transcript, so it cannot tell which of them this session made. An unscoped add would stage every one of them, including anything a concurrent session is still working on.

Stage the paths you actually changed, by name:

  git -C $repo add <path> [<path> ...]

The changes currently in the tree:
$(printf '%s\n' "$changed" | sed 's/^/  /')
MSG
  exit 2
fi

# The cache of what this session has mentioned, topped up from wherever the last read stopped.
key="$(printf '%s' "$transcript" | shasum | cut -c1-12)"
STATE_DIR="${CLAUDE_ADD_SCOPE_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MENTIONS="$STATE_DIR/claude-add-scope-$key.mentions"
OFFSET="$STATE_DIR/claude-add-scope-$key.offset"

from=0
[ -f "$OFFSET" ] && from="$(cat "$OFFSET" 2>/dev/null || echo 0)"
case "$from" in ''|*[!0-9]*) from=0 ;; esac
size="$(wc -c < "$transcript" 2>/dev/null | tr -d ' ')"
case "$size" in ''|*[!0-9]*) size=0 ;; esac
# A transcript that SHRANK is a different file under the same name (a compaction, a fresh session
# reusing the path), and reading on from the old offset would read the middle of a line. Start over
# rather than carry a stale cache forward.
if [ "$size" -lt "$from" ]; then from=0; : > "$MENTIONS"; fi

if [ "$size" -gt "$from" ]; then
  tail -c "+$(( from + 1 ))" "$transcript" 2>/dev/null | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    stack = [rec]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ("file_path", "notebook_path", "path") and isinstance(v, str):
                    out.append(v)
                elif k == "command" and isinstance(v, str):
                    out.append(v)
                else:
                    stack.append(v)
        elif isinstance(node, list):
            stack.extend(node)
sys.stdout.write("\n".join(out))
sys.stdout.write("\n" if out else "")
' >> "$MENTIONS" 2>/dev/null || true
  printf '%s' "$size" > "$OFFSET" 2>/dev/null || true
fi

# Every changed path sorted into exactly ONE bucket, in one pass. A second loop asking the inverse
# question would be a second reading of the same evidence and the two drift (L16, L517).
foreign=""
mine=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Matched on the repo relative path and on the absolute one, because a session names a file both
  # ways: an Edit records the absolute path and a command typically uses the relative one.
  if grep -qF -- "$p" "$MENTIONS" 2>/dev/null || grep -qF -- "$repo/$p" "$MENTIONS" 2>/dev/null; then
    mine="${mine:+$mine }$p"
  else
    foreign="${foreign}  $p
"
  fi
done <<CHANGED
$changed
CHANGED

[ -n "$foreign" ] || exit 0

cat >&2 <<MSG
claude-sync: REFUSED an unscoped 'git add' in $repo.

These changes are in the tree and this session never touched them, so they belong to another session working in the same checkout:
$foreign
An unscoped add stages them too, and they then travel in a commit whose message does not describe them, judged by a test gate that was not asked about them. That happened on 2026-09-10, in this repo, and the work only survived because it happened to be correct.

Stage what this session actually changed, by name:

  git -C $repo add${mine:+ $mine}

If those paths really are this session's, say so and add SKIP_ADD_SCOPE_CHECK=1 to that one command.
MSG
exit 2
