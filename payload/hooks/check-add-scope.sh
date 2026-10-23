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
# turned off within the hour. A file a script wrote without its command naming it is credited by
# time instead: changed while one of this session's own Bash calls was running (claude-config#585).
# In a SUBAGENT the payload's transcript is the dispatching session's, so the agent's own transcript
# is read beside it, never a sibling's, and every change in the isolated worktree Claude Code was
# recorded spawning it with is its own (claude-config#1513). So is every change in a worktree the
# main session made itself with EnterWorktree and is still in, proven by its own records
# (claude-config#1523).
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

# The repository the ADD runs in: the cd in force for it, not for a push later in the command.
# Exit 2 is ps_repo_dir saying the command names a directory it could not judge (missing, not a
# repository, or nothing here to read the command with). That is not "no repository": this gate
# has no other behind it, so it refuses with that sentence rather than letting the add through
# (lessons review of #1017, L42, L490). Exit 1, no repository at all, still stands down.
# One call, its answer and its exit status read from one capture: on exit 0 the text is the
# directory, on exit 2 the sentence saying why it was not judged. No temporary file, because this
# gate also has to refuse on a machine whose PATH holds almost nothing.
repo_out="$(ps_repo_dir "$cmd" "$cwd" ps_is_git_add 2>&1; printf '\035%s' "$?")"
repo_rc="${repo_out##*$'\035'}"; repo="${repo_out%$'\035'*}"
if [ "$repo_rc" = 2 ]; then
  printf 'claude-sync: REFUSED a git add.\n\n%s\n\nStage the paths you changed by name with git -C <repository> add <path>. If this refusal is wrong, say so and add SKIP_ADD_SCOPE_CHECK=1 to that one command.\n' "$repo" >&2
  exit 2
fi
[ "$repo_rc" = 0 ] && [ -n "$repo" ] || exit 0

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

# WHOSE RECORD THIS IS (claude-config#1513). In a SUBAGENT the payload's `transcript_path` names the
# transcript of the session that DISPATCHED it, not the agent's own; the payload says it is a
# subagent by carrying `agent_id`, and the agent's own tool calls are written to
# <that transcript minus .jsonl>/subagents/[<group>/]agent-<agent_id>.jsonl, beside an
# agent-<agent_id>.meta.json recording the worktree Claude Code created for it, if any (measured on
# Claude Code 2.1.307, 2026-10-22, from its own path builder and a live probe). Reading only the
# parent's record called every file an agent wrote, through Edit or by script, another session's:
# a Bidspoke agent was refused three times that day over its own files and overrode the gate each
# time, which is how a guard teaches overriding (L36). So a subagent's own transcript is read
# BESIDE its parent's (whose record always counted), and never a sibling agent's, because a
# sibling is a concurrent worker in the same tree, the very hazard this gate is for.
# The agent id becomes part of a path, so it must be a plain name, or nothing is read for it.
ids="$(printf '%s' "$payload" | python3 -c '
import glob, json, os, re, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
tr = d.get("transcript_path") or ""
tr = tr if isinstance(tr, str) else ""
sid = d.get("session_id")
sid = sid if isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9_-]+", sid) else ""
is_agent = "agent_id" in d
aid = d.get("agent_id")
aid = aid if isinstance(aid, str) else ""
agent_tr = agent_wt = looked = ""
if is_agent and tr.endswith(".jsonl"):
    sub = os.path.join(tr[:-len(".jsonl")], "subagents")
    looked = os.path.join(sub, "agent-%s.jsonl" % aid)
    if re.fullmatch(r"[A-Za-z0-9_-]+", aid):
        for c in [looked] + sorted(glob.glob(os.path.join(glob.escape(sub), "*", "agent-%s.jsonl" % aid))):
            if os.path.isfile(c):
                agent_tr = c
                break
        meta = (agent_tr or looked)[:-len(".jsonl")] + ".meta.json"
        try:
            with open(meta) as fh:
                m = json.load(fh)
            if isinstance(m, dict) and m.get("spawnedWithWorktree") is True \
                    and isinstance(m.get("worktreePath"), str):
                agent_wt = m["worktreePath"]
        except Exception:
            pass
print("\x1f".join([tr, "1" if is_agent else "0", agent_tr, agent_wt, looked, sid]))
' 2>/dev/null || true)"
IFS=$'\x1f' read -r transcript is_agent agent_transcript agent_worktree agent_looked session_id <<IDS || true
$ids
IDS

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

# THE WORKTREE THIS AGENT WAS SPAWNED WITH IS ITS OWN (claude-config#1513). Claude Code creates an
# isolated worktree for one agent and records it in that agent's .meta.json, so every change in it
# is that agent's, including what a background process it started wrote after its call returned,
# which no time window below can see. Only a LINKED worktree qualifies: the main checkout is the one
# concurrent sessions share, and no record naming it is ever a blanket credit. Only the CALLING
# agent's own meta is read, so a worktree another agent was spawned with credits nothing here.
# is_linked_worktree_top <path>: the add runs at the top of <path>, and <path> is a LINKED worktree.
# One predicate for both whole worktree credits, an agent's and a session's own (claude-config#1523).
is_linked_worktree_top(){
  local top top_real wt_real git_dir common_dir
  [ -n "$1" ] || return 1
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
  top_real="$(cd "$top" 2>/dev/null && pwd -P || true)"
  wt_real="$(cd "$1" 2>/dev/null && pwd -P || true)"
  git_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  common_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$top_real" ] && [ "$top_real" = "$wt_real" ] && [ -n "$git_dir" ] && [ -n "$common_dir" ] \
    && [ "$git_dir" != "$common_dir" ]
}
is_linked_worktree_top "$agent_worktree" && exit 0

# The cache of what this session has mentioned, topped up from wherever the last read stopped. One
# cache per transcript read: the session's, and in a subagent its own beside it.
STATE_DIR="${CLAUDE_ADD_SCOPE_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MENTIONS_FILES=()
WINDOWS_FILES=()
topup_cache(){ # topup_cache <transcript>
local transcript="$1" key MENTIONS OFFSET WINDOWS from size
key="$(printf '%s' "$transcript" | shasum | cut -c1-12)"
MENTIONS="$STATE_DIR/claude-add-scope-$key.mentions"
OFFSET="$STATE_DIR/claude-add-scope-$key.offset"
# When each of this session's Bash calls started and finished, as "S id epoch" and "E id epoch"
# lines, read in the same pass as the mentions (claude-config#585).
WINDOWS="$STATE_DIR/claude-add-scope-$key.windows"
# The records that say which worktree this session made and is in, one JSON line each, in transcript
# order (claude-config#1523).
WORKTREE="$STATE_DIR/claude-add-scope-$key.worktree"
WORKTREE_FILE="$WORKTREE"
MENTIONS_FILES+=("$MENTIONS")
WINDOWS_FILES+=("$WINDOWS")

from=0
[ -f "$OFFSET" ] && from="$(cat "$OFFSET" 2>/dev/null || echo 0)"
case "$from" in ''|*[!0-9]*) from=0 ;; esac
size="$(wc -c < "$transcript" 2>/dev/null | tr -d ' ')"
case "$size" in ''|*[!0-9]*) size=0 ;; esac
# A transcript that SHRANK is a different file under the same name (a compaction, a fresh session
# reusing the path), and reading on from the old offset would read the middle of a line. Start over
# rather than carry a stale cache forward.
if [ "$size" -lt "$from" ]; then from=0; : > "$MENTIONS"; : > "$WINDOWS"; : > "$WORKTREE"; fi

if [ "$size" -gt "$from" ]; then
  tail -c "+$(( from + 1 ))" "$transcript" 2>/dev/null | ADD_SCOPE_WINDOWS="$WINDOWS" ADD_SCOPE_WORKTREE="$WORKTREE" python3 -c '
import datetime, json, os, sys
out = []
windows = []
worktree = []
def epoch(ts):
    try:
        return datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    # The times around each Bash call, so a file its script wrote without naming can be credited.
    t = epoch(rec.get("timestamp") or "") if isinstance(rec, dict) else None
    # A message that is not an object (some record kinds carry a plain string) has no content, and
    # must not abort the read, which would lose every mention in this chunk (L215).
    msg = rec.get("message") if isinstance(rec, dict) else None
    content = (msg.get("content") if isinstance(msg, dict) else None) or []
    if t is not None and isinstance(content, list):
        for c in content:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use" and c.get("name") == "Bash" and c.get("id"):
                windows.append("S %s %d" % (c["id"], int(t)))
            elif c.get("type") == "tool_result" and c.get("tool_use_id"):
                windows.append("E %s %d" % (c["tool_use_id"], int(t)))
    # Which worktree this session made (claude-config#1523): its EnterWorktree calls, their results
    # (toolUseResult carries the path and a message saying Created, Resumed, Reused or Entered), and
    # every worktree-state record, each with the session id of the record it came from.
    if isinstance(rec, dict):
        rsid = rec.get("sessionId")
        if rec.get("type") == "worktree-state":
            worktree.append({"k": "S", "sid": rsid, "ws": rec.get("worktreeSession")})
        tur = rec.get("toolUseResult")
        for c in (content if isinstance(content, list) else []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use" and c.get("name") == "EnterWorktree" and c.get("id"):
                worktree.append({"k": "U", "id": c["id"], "sid": rsid})
            elif c.get("type") == "tool_result" and c.get("tool_use_id") and isinstance(tur, dict) \
                    and isinstance(tur.get("worktreePath"), str) and isinstance(tur.get("message"), str):
                worktree.append({"k": "R", "id": c["tool_use_id"], "sid": rsid, "path": tur["worktreePath"],
                                 "created": tur["message"].startswith("Created worktree at ")})
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
if windows:
    with open(os.environ["ADD_SCOPE_WINDOWS"], "a") as fh:
        fh.write("\n".join(windows) + "\n")
if worktree:
    with open(os.environ["ADD_SCOPE_WORKTREE"], "a") as fh:
        fh.write("\n".join(json.dumps(w) for w in worktree) + "\n")
' >> "$MENTIONS" 2>/dev/null || true
  printf '%s' "$size" > "$OFFSET" 2>/dev/null || true
fi
: >> "$MENTIONS" 2>/dev/null || true
}

topup_cache "$transcript"
SESSION_WORKTREE_FILE="$WORKTREE_FILE"
[ -n "$agent_transcript" ] && topup_cache "$agent_transcript"

# THE WORKTREE THIS SESSION MADE ITSELF IS ITS OWN (claude-config#1523), under the same rule as an
# agent's: a linked worktree only, never the shared main checkout, and only the session that made
# it. What Claude Code 2.1.307 records for that (measured 2026-10-22 with throwaway headless sessions
# and read from its own code): a `worktree-state` record whose `worktreeSession` names the path and
# the session, with `enteredExisting: true` when the session went into one that already existed; and
# EnterWorktree's result, whose message begins "Created worktree at" only when that call made it.
# The record ALONE proves nothing: a worktree resumed by name gets one identical to a created one,
# and was measured holding a file an earlier session had left in it. So credit needs both, from this
# session's own id: the latest record says the session is in the worktree and did not enter it as a
# guest, and the latest EnterWorktree result says Created for that same path. `claude --worktree`
# makes no tool call and leaves only the record, so it gets no credit and is judged as before.
# A SUBAGENT never gets this credit, even in its session's worktree: sibling agents share that tree,
# which is the hazard this gate is for, and an agent's own worktree is credited by its meta above.
if [ "$is_agent" = 0 ] && [ -n "$session_id" ] && [ -s "$SESSION_WORKTREE_FILE" ]; then
  own_worktree="$(ADD_SCOPE_SID="$session_id" python3 -c '
import json, os, sys
sid = os.environ["ADD_SCOPE_SID"]
uses, result, state = {}, None, None
with open(sys.argv[1]) as fh:
    for line in fh:
        try:
            w = json.loads(line)
        except Exception:
            continue
        if not isinstance(w, dict):
            continue
        if w.get("k") == "U":
            uses[w.get("id")] = w.get("sid")
        elif w.get("k") == "R" and w.get("id") in uses:
            result = dict(w, use_sid=uses[w.get("id")])
        elif w.get("k") == "S":
            state = w
ws = state.get("ws") if state else None
if (isinstance(ws, dict) and state.get("sid") == sid and ws.get("sessionId") == sid
        and ws.get("enteredExisting") is not True and ws.get("hookBased") is not True
        and isinstance(ws.get("worktreePath"), str) and result is not None
        and result.get("created") is True and result.get("sid") == sid and result.get("use_sid") == sid
        and result.get("path") == ws["worktreePath"]):
    print(ws["worktreePath"])
' "$SESSION_WORKTREE_FILE" 2>/dev/null || true)"
  is_linked_worktree_top "$own_worktree" && exit 0
fi

# Every changed path sorted into exactly ONE bucket, in one pass. A second loop asking the inverse
# question would be a second reading of the same evidence and the two drift (L16, L517).
foreign=""
mine=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Matched on the repo relative path and on the absolute one, because a session names a file both
  # ways: an Edit records the absolute path and a command typically uses the relative one.
  if grep -qF -- "$p" "${MENTIONS_FILES[@]}" 2>/dev/null || grep -qF -- "$repo/$p" "${MENTIONS_FILES[@]}" 2>/dev/null; then
    mine="${mine:+$mine }$p"
  else
    foreign="${foreign}  $p
"
  fi
done <<CHANGED
$changed
CHANGED

[ -n "$foreign" ] || exit 0

# WRITTEN BY THIS SESSION'S OWN SCRIPTS (claude-config#585). A path the session never named can
# still be its own: a python or sed script, or a generator, writes files its command line does not
# mention, and on 2026-09-26 that had this gate call a session's own work another session's, which
# pushes toward the override or an unscoped add. So a file whose last change (its modification or
# its status change time) falls inside one of this session's finished Bash calls, a second either
# side for the clock's rounding, is credited. Generous on purpose, as the rest of this match is: a
# concurrent session writing at that same moment would be credited too, and that costs one add,
# while the other way costs every scripted edit. Asked only of the paths still foreign, in one pass.
windows_list=""
for w in "${WINDOWS_FILES[@]}"; do
  [ -s "$w" ] && windows_list="${windows_list}${w}
"
done
if [ -n "$windows_list" ]; then
  credited="$(printf '%s' "$foreign" | sed 's/^  //' | ADD_SCOPE_WINDOWS="$windows_list" ADD_SCOPE_REPO="$repo" python3 -c '
import os, sys
starts, ends = {}, {}
lines = []
for wf in os.environ["ADD_SCOPE_WINDOWS"].splitlines():
    if wf:
        with open(wf) as fh:
            lines.extend(fh.read().splitlines())
for line in lines:
    parts = line.split()
    if len(parts) != 3:
        continue
    kind, ident, t = parts
    try:
        t = int(t)
    except ValueError:
        continue
    (starts if kind == "S" else ends)[ident] = t
spans = [(starts[i] - 1, ends[i] + 1) for i in starts if i in ends and ends[i] >= starts[i]]
repo = os.environ["ADD_SCOPE_REPO"]
for p in sys.stdin.read().splitlines():
    if not p:
        continue
    # A DELETED file has nothing left to stat, so it is judged by the directory it was removed
    # from, whose modification time the removal sets (generous, as the rest of this is).
    full = os.path.join(repo, p)
    try:
        st = os.lstat(full)
    except OSError:
        try:
            st = os.lstat(os.path.dirname(full.rstrip("/")) or repo)
        except OSError:
            continue
    times = (int(st.st_mtime), int(st.st_ctime))
    if any(a <= t <= b for t in times for a, b in spans):
        print(p)
' 2>/dev/null || true)"
  if [ -n "$credited" ]; then
    still=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      p="${p#  }"
      if case "
$credited
" in *"
$p
"*) true ;; *) false ;; esac; then
        mine="${mine:+$mine }$p"
      else
        still="${still}  $p
"
      fi
    done <<FOREIGN
$foreign
FOREIGN
    foreign="$still"
  fi
fi

[ -n "$foreign" ] || exit 0

# A subagent whose own transcript is not on disk (a nested agent's is never written) was judged on
# the dispatching session's record alone. That is the refusing direction, and the refusal says so,
# because "another session made these" is then a claim nothing measured (L11).
unread_note=""
if [ "$is_agent" = 1 ] && [ -z "$agent_transcript" ]; then
  unread_note="
This call comes from a subagent, and its own transcript was not found (looked for ${agent_looked:-it beside the session transcript}), so only the dispatching session's record was read: files this agent changed itself are among those listed.
"
fi

cat >&2 <<MSG
claude-sync: REFUSED an unscoped 'git add' in $repo.

These changes are in the tree and this session never touched them, so they belong to another session working in the same checkout:
$foreign$unread_note
An unscoped add stages them too, and they then travel in a commit whose message does not describe them, judged by a test gate that was not asked about them. That happened on 2026-09-10, in this repo, and the work only survived because it happened to be correct.

Stage what this session actually changed, by name:

  git -C $repo add${mine:+ $mine}

If those paths really are this session's, say so and add SKIP_ADD_SCOPE_CHECK=1 to that one command.
MSG
exit 2
