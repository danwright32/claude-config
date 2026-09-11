#!/usr/bin/env bash
#
# payload-write-gate.sh
# Claude Code PreToolUse hook: refuse a write under a development checkout's payload/ while the
# watch daemon could revert it, rather than warning about it on the next prompt
# (claude-config#367).
#
# payload-revert-warning.sh already says the right thing: edits to payload/ in a development
# checkout are mirrored over by the watch daemon running from another clone. But it is a
# UserPromptSubmit hook, so it speaks only when Dan sends a message. On 2026-09-10 a session made
# roughly forty tool calls editing payload/LESSONS.md, adding 476 short form lines, before the
# warning was ever printed, and only then took a hold. Had the daemon fired in that window the work
# would have been reverted silently, which is what happened on 2026-09-03 to 84 files.
#
# So the refusal happens at the WRITE, which is the first step that can answer it (L667), and the
# prompt time warning stays for the case this cannot see: a hold that lapses mid session.
#
# It refuses ONLY in the state that loses work: a live watcher, running from a DIFFERENT clone, and
# no hold in force. A session editing the clone the watcher itself runs from is editing the source
# of the mirror and is not at risk, and neither is one holding the watcher off. Its four questions
# come from lib/sync-clone.sh, shared with the warning hook, so the two cannot come to two
# different answers about whether a hold is in force (L370).
#
# Env:
#   SYNC_WATCH_PID_FILE  the watcher's pid file (default ~/.claude-sync-watch.pid)
#   SYNC_HOLD_FILE       the hold marker (default ~/.claude-sync-hold)
# Override, per this repo's convention, explained to the person first and never silently:
#   SKIP_PAYLOAD_WRITE_CHECK=1 as an inline prefix on a Bash command, for that one command.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sync-clone.sh
. "$HOOK_DIR/lib/sync-clone.sh" 2>/dev/null || exit 0
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null || true)"

read -r tool cwd <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print((d.get("tool_name") or "-"), (d.get("cwd") or "-"))
' 2>/dev/null || printf -- '- -')
EOF
[ "$cwd" = "-" ] && cwd="$PWD"

# WHICH FILES this call would write. Two shapes, because two kinds of tool call write a file and
# only covering the first would leave the gate silent on the way most of this session's own edits
# were actually made (L247).
targets=""
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    targets="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
ti = d.get("tool_input") or {}
seen = []
for key in ("file_path", "notebook_path"):
    v = ti.get(key)
    if v:
        seen.append(v)
for e in (ti.get("edits") or []):
    v = (e or {}).get("file_path")
    if v:
        seen.append(v)
for v in seen:
    print(v)
' 2>/dev/null || true)"
    ;;
  Bash)
    cmd="$(ps_parse_payload "$payload" raw 2>/dev/null || true)"
    cmd="${cmd%%$'\x1f'*}"
    [ -n "$cmd" ] || exit 0
    # The documented override, honoured before anything else, so the person who has read the
    # message can get past it for one command.
    case "$cmd" in *SKIP_PAYLOAD_WRITE_CHECK=1*) exit 0 ;; esac
    # Only the payload paths in a WRITE POSITION, never every payload path in a command that
    # happens to contain a redirect somewhere. `cat payload/x 2>/dev/null` holds both and writes
    # nothing, and reading is the overwhelming majority of what a session does in a checkout: a
    # gate that refused those would be turned off within the hour (L36, L104).
    targets="$(printf '%s' "$cmd" | python3 -c '
import re, sys

cmd = sys.stdin.read()
targets = []

def add(tok):
    tok = tok.strip().strip("\"\x27")
    if tok and re.search(r"(^|/)payload/", tok):
        targets.append(tok)

# A redirect TARGET: the word after > or >> (or 2>, &>, a fd form), attached or separated.
for m in re.finditer(r"(?:^|[^0-9<>&|])(?:[0-9]*|&)>>?\s*([^\s;&|<>]+)", cmd):
    add(m.group(1))

# Commands whose arguments ARE what they write. Scanned per segment, so a read in one segment is
# not blamed on a write in the next.
WRITERS = ("tee", "cp", "mv", "rm", "touch", "mkdir", "patch", "install", "rsync", "truncate")
for seg in re.split(r"&&|\|\||;|\||\n", cmd):
    words = seg.split()
    if not words:
        continue
    # Leading VAR=value assignments are not the command.
    k = 0
    while k < len(words) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[k]):
        k += 1
    if k >= len(words):
        continue
    head = words[k].rsplit("/", 1)[-1]
    if head == "sed" and any(w == "-i" or w.startswith("-i") for w in words[k:]):
        for w in words[k + 1:]:
            add(w)
    elif head in WRITERS:
        for w in words[k + 1:]:
            add(w)

# An inline script opening a file for writing. This is how most of this repo own payload edits are
# actually made, and a gate blind to it would be silent on exactly the session that prompted it.
for m in re.finditer(r"open\(\s*([\"\x27][^\"\x27]+[\"\x27])\s*,\s*[\"\x27][wa]", cmd):
    add(m.group(1))

seen = []
for t in targets:
    if t not in seen:
        seen.append(t)
print("\n".join(seen))
' 2>/dev/null || true)"
    ;;
  *) exit 0 ;;
esac
[ -n "$targets" ] || exit 0

# Which clone each target is in, and whether that clone is at risk. Asked per target, because one
# command can name paths in two checkouts.
refuse_root=""
refuse_path=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$t" in
    /*) d="$(dirname "$t")" ;;
    *)  d="$(dirname "$cwd/$t")" ;;
  esac
  root="$(sc_clone_root_of "$d")" || continue
  [ -n "$root" ] || continue
  # Only payload/ is mirrored. An edit to claude-sync itself, or to tests/, is this checkout's own
  # work and the daemon never touches it.
  case "$(cd "$d" 2>/dev/null && pwd -P)/" in "$root/payload/"*) ;; *) continue ;; esac
  wcmd="$(sc_watcher_cmd || true)"
  [ -n "$wcmd" ] || continue                       # no watcher: nothing can revert anything
  sc_is_this_clone "$root" "$wcmd" && continue     # the watcher runs from HERE: this is its source
  sc_hold_live && continue                         # held off: this is exactly what a hold is for
  refuse_root="$root"; refuse_path="$t"; break
done <<TARGETS
$targets
TARGETS

[ -n "$refuse_root" ] || exit 0

cat >&2 <<MSG
claude-sync: REFUSED a write to $refuse_path.

This is a development checkout at $refuse_root, and a watch daemon is live on this Mac running from another clone. That daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ here is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit and deleted a file that existed only in the repo.

Two ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"

A hold expires. When it does, make ~/.claude match what is in the checkout, or the next send reverts it again.
MSG
exit 2
