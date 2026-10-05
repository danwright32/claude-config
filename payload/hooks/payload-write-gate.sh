#!/usr/bin/env bash
#
# payload-write-gate.sh
# Claude Code PreToolUse(Bash|Edit|Write|MultiEdit|NotebookEdit) hook: refuse a write under a
# development checkout's payload/ while the watch daemon could revert it, rather than warning about
# it on the next prompt (claude-config#367).
# Claude Code PostToolUse(Bash) hook: before a Bash call the half above notes what an at risk
# payload/ holds, and after it this names anything written, added or removed there, so a write the
# command's words could not show (a script file, a path built at run time) is still caught, by its
# destination (claude-config#647).
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

# THE READER THIS GATE SEES THE TOOL CALL THROUGH, asked before its answer is believed
# (claude-config#480, L490).
#
# Which tool is being called and which files it would write are both read with python3 below. With
# none installed the tool name came back as a dash, the case over it matched nothing, and every
# write under payload/ was allowed with nothing said: an absent reader is the one failure that
# looks exactly like a clean run (L42, L98), and what it was allowing is the loss of a day's work.
#
# What is refused is narrowed to what could be a payload write at all, by the raw payload text,
# because nothing here can read the path out of it: a gate that refused every Edit and every Bash
# call on such a machine is one nobody keeps (L36, L54). The three questions that decide whether
# anything is at risk (is there a watcher, does it run from HERE, is a hold in force) are pure
# shell in lib/sync-clone.sh, so they are asked here exactly as they are below, and a machine where
# nothing could revert the write is not refused.
if ps_reader_missing python3; then
  case "$payload" in *SKIP_PAYLOAD_WRITE_CHECK=1*) exit 0 ;; esac
  # After a call there is nothing left to refuse, and the check made then needs the note this
  # branch never took.
  case "$payload" in *'"hook_event_name":"PostToolUse"'*|*'"hook_event_name": "PostToolUse"'*) exit 0 ;; esac
  case "$payload" in *payload/*) ;; *) exit 0 ;; esac
  unreadable_root="$(sc_clone_root_of "$PWD" 2>/dev/null || true)"
  unreadable_watcher="$(sc_watcher_cmd || true)"
  [ -n "$unreadable_watcher" ] || exit 0
  if [ -n "$unreadable_root" ]; then
    sc_is_this_clone "$unreadable_root" "$unreadable_watcher" && exit 0
  fi
  sc_hold_live && exit 0
  cat >&2 <<MSG
claude-sync: REFUSED a write that may be under a development checkout's payload/.

$(ps_reader_absent_why "python3 is not on PATH" "payload-write-gate.sh reads which tool is being called and which files it would write with it, so with python3 absent it cannot tell a write under payload/ from any other write, and a watch daemon is live on this Mac running from another clone." "python3")

A watch daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ in a development checkout is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit.

Two ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
fi

IFS=$'\t' read -r tool cwd event use_id <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, re, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
def f(k):
    v = d.get(k) or "-"
    return re.sub(r"[\t\n]", " ", str(v))
print("\t".join([f("tool_name"), f("cwd"), f("hook_event_name"), f("tool_use_id")]))
' 2>/dev/null || printf -- '-\t-\t-\t-')
EOF
[ "$cwd" = "-" ] && cwd="$PWD"

# WHERE this gate keeps the note of what payload/ held before a Bash call, read back after it
# (claude-config#647). One small set of files per call, removed by the read, so what it keeps
# cannot grow with the number of calls (claude-config#603).
STATE_DIR="${PAYLOAD_WRITE_STATE_DIR:-$HOME/.claude-payload-write-gate}"
state_key="$(printf '%s' "$use_id" | tr -c 'A-Za-z0-9_.-' '_')"

# AFTER a Bash call: what changed under a payload/ that was at risk while it ran (claude-config#647).
#
# The command text cannot show every write. A script FILE, a path a program builds at run time, a
# tool nobody listed: each writes where its words do not say, and on 2026-10-04 an agent's python
# edits to payload/mods went past this gate while its one shell redirect was refused. So whatever
# the words could not show is judged by the destination itself, after the fact. It cannot undo the
# write, so it says so plainly and names the one step that protects it now, rather than staying
# quiet about a write the daemon may revert (L11, L98).
if [ "$event" = "PostToolUse" ]; then
  [ "$tool" = "Bash" ] || exit 0
  [ "$use_id" != "-" ] || exit 0
  roots_f="$STATE_DIR/$state_key.roots"
  list_f="$STATE_DIR/$state_key.list"
  [ -f "$roots_f" ] || exit 0
  changed=""
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/payload" ] || continue
    # Written or replaced since the note: mtime for an edit, ctime for a move, which keeps the moved
    # file's old modification time and would read as untouched by mtime alone.
    changed="$changed$(find "$root/payload" -type f \( -newer "$roots_f" -o -cnewer "$roots_f" \) 2>/dev/null)
"
  done < "$roots_f"
  # Added or removed: the listing now against the listing then.
  now_list="$(while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/payload" ] && find "$root/payload" -type f 2>/dev/null
  done < "$roots_f" | LC_ALL=C sort)"
  if [ -f "$list_f" ]; then
    changed="$changed$(printf '%s\n' "$now_list" | LC_ALL=C comm -3 - "$list_f" | sed 's/^[[:space:]]*//')"
  fi
  rm -f "$roots_f" "$list_f"
  changed="$(printf '%s\n' "$changed" | sed '/^$/d' | LC_ALL=C sort -u)"
  [ -n "$changed" ] || exit 0
  # Protected since it ran: a hold taken meanwhile, or the watcher gone, is what makes it safe now.
  wcmd="$(sc_watcher_cmd || true)"
  [ -n "$wcmd" ] || exit 0
  sc_hold_live && exit 0
  n="$(printf '%s\n' "$changed" | grep -c .)"
  shown="$(printf '%s\n' "$changed" | awk 'NR <= 20 { print "  " $0 }')"
  [ "$n" -gt 20 ] && shown="$shown
  ... and $((n - 20)) more"
  cat >&2 <<MSG
claude-sync: that command changed $n file(s) under a development checkout's payload/ while a watch daemon was live from another clone and no hold was in force:

$shown

Nothing in the command's words showed those writes, so they could not be refused before it ran. The daemon mirrors ~/.claude up over payload/ and pushes, so these edits can be reverted silently, as 84 files were on 2026-09-03. Protect them now, before anything else:

     claude-sync hold 120 "why you are editing the checkout"

Then make ~/.claude match the checkout before the hold expires, or the next send reverts them.
MSG
  exit 2
fi

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
    # Nothing can revert anything with no watcher, so none of the reading below is paid for then.
    [ -n "$(sc_watcher_cmd || true)" ] || exit 0
    # Only the paths in a WRITE POSITION, never every payload path in a command that happens to
    # contain a redirect somewhere. `cat payload/x 2>/dev/null` holds both and writes nothing, and
    # reading is the overwhelming majority of what a session does in a checkout: a gate that refused
    # those would be turned off within the hour (L36, L104).
    #
    # Judged by the DESTINATION (claude-config#647): a relative path is resolved against where the
    # command actually runs, the session's directory or a `cd` earlier in the same command, so a
    # write made from inside payload/ counts whether or not its words say payload.
    targets="$(printf '%s' "$cmd" | GATE_CWD="$cwd" python3 -c '
import os, re, sys

cmd = sys.stdin.read()
cwd = os.environ.get("GATE_CWD") or os.getcwd()
targets = []

def resolve(tok, base):
    tok = tok.strip().strip("\"\x27")
    if not tok:
        return None
    if tok.startswith("~"):
        tok = os.path.expanduser(tok)
    if tok.startswith("$") or "$(" in tok or "`" in tok:
        # A value only the shell knows. Counted only when its words name payload, as before.
        return tok if re.search(r"(^|/)payload/", tok) else None
    if not tok.startswith("/"):
        tok = os.path.join(base, tok)
    return os.path.normpath(tok)

def add(tok, base):
    p = resolve(tok, base)
    if p:
        targets.append(p)

# Heredoc BODIES are data, not shell: a python comparison like `a > b` in one is no redirect. They
# are taken out of the shell reading and kept for the inline script reading below.
shell = []
bodies = []
lines = cmd.split("\n")
i = 0
while i < len(lines):
    line = lines[i]
    shell.append(line)
    delims = re.findall(r"<<-?\s*[\"\x27]?([A-Za-z_][A-Za-z0-9_]*)[\"\x27]?", line)
    i += 1
    for delim in delims:
        while i < len(lines) and lines[i].strip() != delim:
            bodies.append(lines[i])
            i += 1
        i += 1
shell_text = "\n".join(shell)

# Commands whose arguments ARE what they write. Scanned per segment, in order, so a read in one
# segment is not blamed on a write in the next, and a `cd` moves where the rest resolve.
WRITERS = ("tee", "cp", "mv", "rm", "touch", "mkdir", "patch", "install", "rsync", "truncate",
           "ln", "ditto", "unlink", "rmdir")
GIT_WRITERS = ("checkout", "restore", "rm", "mv")
base = cwd
for seg in re.split(r"&&|\|\||;|\||\n", shell_text):
    # A redirect TARGET: the word after > or >> (or 2>, &>, a fd form), attached or separated.
    for m in re.finditer(r"(?:^|[^0-9<>&|])(?:[0-9]*|&)>>?\s*([^\s;&|<>]+)", seg):
        add(m.group(1), base)
    words = seg.split()
    if not words:
        continue
    k = 0
    while k < len(words) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[k]):
        k += 1
    if k >= len(words):
        continue
    head = words[k].lstrip("(").rsplit("/", 1)[-1]
    args = words[k + 1:]
    if head in ("cd", "pushd"):
        dest = next((w for w in args if not w.startswith("-")), "~")
        nb = resolve(dest, base)
        if nb and not nb.startswith("$"):
            base = nb
        continue
    # A flag is never a path, so none is resolved against where the command runs.
    if head == "sed" and any(w == "-i" or w.startswith("-i") for w in args):
        for w in args:
            if not w.startswith("-"):
                add(w, base)
    elif head in ("perl", "ruby") and any(re.match(r"^-[A-Za-z]*i", w) for w in args):
        for w in args:
            if not w.startswith("-"):
                add(w, base)
    elif head == "dd":
        for w in args:
            if w.startswith("of="):
                add(w[3:], base)
    elif head == "git":
        sub = next((w for w in args if not w.startswith("-")), "")
        if sub in GIT_WRITERS:
            rest = args[args.index(sub) + 1:]
            # checkout and restore name a branch or commit before `--`, and only the paths after
            # it are rewritten; a bare `git checkout main` switches branches and names no path.
            if sub in ("checkout", "restore") and "--" in rest:
                rest = rest[rest.index("--") + 1:]
            elif sub == "checkout":
                rest = []
            for w in rest:
                if not w.startswith("-"):
                    add(w, base)
    elif head in WRITERS:
        for w in args:
            if not w.startswith("-"):
                add(w, base)

# An inline script that can write, and names a payload path. Most of this repo own payload edits
# are made this way, and the path is routinely held in a variable before it is opened, so the test
# is the script holding a payload path AND any writing call at all, not the two on one line.
WRITE_CALLS = (r"open\([^)]*,\s*[\"\x27][^\"\x27]*[wax+]", r"\.write_(text|bytes)\(",
               r"shutil\.(copy|copy2|copyfile|copytree|move|rmtree)\(",
               r"os\.(replace|rename|remove|unlink|makedirs|mkdir|rmdir)\(", r"\.unlink\(",
               r"\.rename\(", r"\.touch\(", r"writeFileSync|appendFileSync|File\.write")
if any(re.search(p, cmd) for p in WRITE_CALLS):
    for m in re.finditer(r"[\"\x27]([^\"\x27\s]*payload/[^\"\x27\s]*)[\"\x27]", cmd):
        add(m.group(1), cwd)
# The original single line form, kept: a literal opened for writing in place.
for m in re.finditer(r"open\(\s*([\"\x27][^\"\x27]+[\"\x27])\s*,\s*[\"\x27][wa]", cmd):
    add(m.group(1), cwd)

seen = []
for t in targets:
    if t not in seen:
        seen.append(t)
print("\n".join(seen))
' 2>/dev/null || true)"
    ;;
  *) exit 0 ;;
esac

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

# BEFORE a Bash call it let through: a note of what each at risk payload/ holds, for the check after
# it to compare against (claude-config#647). Taken only in the state that loses work, a live watcher
# from another clone and no hold, and only for the checkouts this command could reach: the one it
# runs in, and any its words name. Two finds over a few hundred files, never one process per file.
note_payload_before(){
  local wcmd roots="" dir root
  [ "$tool" = "Bash" ] && [ "$use_id" != "-" ] || return 0
  wcmd="$(sc_watcher_cmd || true)"
  [ -n "$wcmd" ] || return 0
  sc_hold_live && return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    root="$(sc_clone_root_of "$dir" 2>/dev/null)" || continue
    [ -n "$root" ] || continue
    sc_is_this_clone "$root" "$wcmd" && continue
    case "
$roots
" in *"
$root
"*) continue ;; esac
    roots="${roots:+$roots
}$root"
  done <<DIRS
$cwd
$(printf '%s\n' "$targets" | sed -n 's#/[^/]*$##p')
$(printf '%s' "$cmd" | grep -oE "/[^[:space:]\"']*/payload/" | sed 's#/payload/$##' | LC_ALL=C sort -u)
DIRS
  [ -n "$roots" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  # A call another gate refused never reaches the check after it, so its note is left behind. One
  # find clears every such note older than a day, so the directory cannot grow with refusals.
  find "$STATE_DIR" -type f -mmin +1440 -delete 2>/dev/null
  # The roots file is written FIRST: its time is what "changed since" is measured from.
  printf '%s\n' "$roots" > "$STATE_DIR/$state_key.roots" || return 0
  printf '%s\n' "$roots" | while IFS= read -r root; do
    find "$root/payload" -type f 2>/dev/null
  done | LC_ALL=C sort > "$STATE_DIR/$state_key.list"
  return 0
}

if [ -z "$refuse_root" ]; then
  note_payload_before
  exit 0
fi

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
