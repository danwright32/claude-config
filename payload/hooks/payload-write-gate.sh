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
# no hold in force that covers the writing session, in a checkout the daemon can overwrite. A
# session editing the clone the watcher itself runs from is editing the source of the mirror and is
# not at risk, and neither is one holding the watcher off.
#
# The hold has to be the WRITING session's own, or one taken from a terminal, which records no
# session and covers anyone (claude-config#1886). Any session's hold used to do: session B wrote on
# session A's hold, and B's half written files were sent the moment A released. The refusal then
# names whose hold it is and that this session needs its own.
#
# Nor is an agent's linked worktree on a branch other than the default (claude-config#800): the
# daemon never writes into it, and its work reaches main only by a reviewed merge. Both halves
# below, the refusal before a call and the report after it, let it through.
#
# The questions come from lib/sync-clone.sh, shared with the warning hook, so the two cannot come
# to two different answers about whether a hold is in force (L370).
#
# Env:
#   SYNC_WATCH_PID_FILE  the watcher's pid file (default ~/.claude-sync-watch.pid)
#   SYNC_HOLD_FILE       the hold marker (default ~/.claude-sync-hold)
#   PAYLOAD_WRITE_INSTALLED_DIR  the installed config a changed file is compared with (default ~/.claude)
# Override, per this repo's convention, explained to the person first and never silently:
#   SKIP_PAYLOAD_WRITE_CHECK=1 as an inline prefix on a Bash command, for that one command.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"

# A LIBRARY THIS GATE CANNOT LOAD IS NOT NOTHING TO CHECK (claude-config#1900, L10, L1033).
#
# Both libraries below answer every question this gate asks: whether a watcher could revert the
# write, whether it runs from here, whether a hold covers it, and what the command writes. They were
# sourced with `|| exit 0`, so a hook dir missing either let every payload write through with
# nothing said, which looks exactly like a write nothing could revert. Now the call is refused when
# its raw payload names payload/ at all, since nothing here can read more than that, and the
# refusal names the file. A library that sources but lacks the function asked for (an empty or cut
# short file) is the same failure. After a call there is nothing left to refuse.
unloaded(){   # $1 = the library file that could not be loaded
  case "$payload" in *SKIP_PAYLOAD_WRITE_CHECK=1*) exit 0 ;; esac
  case "$payload" in *'"hook_event_name":"PostToolUse"'*|*'"hook_event_name": "PostToolUse"'*) exit 0 ;; esac
  case "$payload" in *payload/*) ;; *) exit 0 ;; esac
  cat >&2 <<MSG
claude-sync: REFUSED a write that may be under a development checkout's payload/.

payload-write-gate.sh could not load lib/$1 from $HOOK_DIR/lib, and that library is how it tells whether a watch daemon could revert this write and whether a hold covers it. A library this gate cannot load is not a sign there is nothing to check, so a call naming payload/ is refused until it is back. Reinstall the hooks with: claude-sync pull

For one Bash command, and only after reading this: SKIP_PAYLOAD_WRITE_CHECK=1 <the same command>
MSG
  exit 2
}
# shellcheck source=lib/sync-clone.sh
{ . "$HOOK_DIR/lib/sync-clone.sh" 2>/dev/null && declare -F sc_hold_covers >/dev/null; } || unloaded sync-clone.sh
# shellcheck source=lib/push-scope.sh
{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_parse_payload >/dev/null; } || unloaded push-scope.sh
# Taken raw above, for the refusal a missing library gives, and cleaned now, before anything parses
# it: a lone surrogate escape reads as nothing to jq and raises in python3's print (claude-config#1944).
payload="$(ps_clean_payload "$payload")"
# Missing, a file differing only by the home placeholder is reported rather than left out, which is
# the safe side of that question.
# shellcheck source=lib/home-token.sh
. "$HOOK_DIR/lib/home-token.sh" 2>/dev/null || true

# WHICH SESSION is writing, because only its own hold protects its writes (claude-config#1886).
# Another session's hold lets this one write today and is released whenever that session is done,
# which sends this session's half written files with it. Read from the payload without python3, so
# the branch below that has none still knows; lib/sync-clone.sh adds CLAUDE_CODE_SESSION_ID.
sid="$(sc_payload_session "$payload")"
# The paragraph that names who does hold the watcher, when it is somebody else, and where this
# message gives the command that takes this session's own hold, in OTHERS_NOTE with the blank line
# that follows it. Empty otherwise, so a message reads exactly as before when nobody else holds.
OTHERS_NOTE=""
others_note(){   # $1 = where the command is in this message
  local s
  OTHERS_NOTE=""
  s="$(sc_hold_others_sentence "$sid")"
  [ -n "$s" ] || return 0
  # Pointed at the command only when another session holds; the same call also says when no hold
  # can count at all because the hold reader is missing, and then no hold would help.
  [ -z "$(sc_hold_others "$sid")" ] || s="$s Take it with $1."
  OTHERS_NOTE="$s

"
}

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
# call on such a machine is one nobody keeps (L36, L54). The questions that decide whether
# anything is at risk (is there a watcher, does it run from HERE, is it an own worktree, is a hold in
# force) are pure
# shell in lib/sync-clone.sh, so they are asked here exactly as they are below, and a machine where
# nothing could revert the write is not refused.
#
# The same refusal serves a payload python3 is present for and still cannot read (claude-config
# #1900): before it read its stdin in text mode, a byte that is not UTF-8 anywhere in the payload
# raised, the tool name came back as a dash, and the write was allowed. The readers now decode as jq
# does, so that byte is read, and whatever is left that they cannot read is refused here, never
# allowed (L1033). $1 is the paragraph saying why the call could not be read.
refuse_unread(){
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
    sc_is_own_worktree "$unreadable_root" && exit 0
  fi
  sc_hold_covers "$sid" && exit 0
  others_note "the second way below"
  cat >&2 <<MSG
claude-sync: REFUSED a write that may be under a development checkout's payload/.

$1

${OTHERS_NOTE}A watch daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ in a development checkout is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit.

Two ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
}
if ps_reader_missing python3; then
  refuse_unread "$(ps_reader_absent_why "python3 is not on PATH" "payload-write-gate.sh reads which tool is being called and which files it would write with it, so with python3 absent it cannot tell a write under payload/ from any other write, and a watch daemon is live on this Mac running from another clone." "python3")"
fi
UNREAD="payload-write-gate.sh could not read this tool call: the hook payload could not be read as JSON, so which tool is being called and which files it would write are unknown, and a watch daemon is live on this Mac running from another clone. A payload this gate cannot read is not one with nothing in it, so the call is refused rather than allowed (claude-config#1900)."

# Read as jq reads it: a byte that is not UTF-8 becomes U+FFFD rather than raising, on the way in
# and on the way out (claude-config#1900).
fields="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
sys.stdout.reconfigure(errors="replace")
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
if not isinstance(d, dict):
    sys.exit(3)
def f(k):
    v = d.get(k) or "-"
    return re.sub(r"[\t\n]", " ", str(v))
print("\t".join([f("tool_name"), f("cwd"), f("hook_event_name"), f("tool_use_id")]))
' 2>/dev/null)" || refuse_unread "$UNREAD"
IFS=$'\t' read -r tool cwd event use_id <<EOF
$fields
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
  roots_list="$(cat "$roots_f")"
  rm -f "$roots_f" "$list_f"
  changed="$(printf '%s\n' "$changed" | sed '/^$/d' | LC_ALL=C sort -u)"
  [ -n "$changed" ] || exit 0
  # Protected since it ran: a hold of this session's own taken meanwhile, or the watcher gone, is
  # what makes it safe now. Another session's hold is not (claude-config#1886).
  wcmd="$(sc_watcher_cmd || true)"
  [ -n "$wcmd" ] || exit 0
  sc_hold_covers "$sid" && exit 0
  # Left out: a file that already matches the installed config, which the daemon mirrors FROM, so
  # it has nothing to revert there (claude-config#1211). On 2026-10-15 a fast forward pull of the
  # checkout right after the same commit was installed listed 27 files, every one identical to its
  # installed copy, and a report wrong whenever a checkout catches up teaches skimming (L36). A
  # file matches when its bytes do, or when the only difference is the home placeholder the install
  # expands, and a removed one when the installed config lacks it too. Anything else is reported,
  # an installed copy merged with local settings included, since a match cannot be shown there.
  installed="${PAYLOAD_WRITE_INSTALLED_DIR:-$HOME/.claude}"
  differ=""; matched=0
  while IFS= read -r f; do
    rel=""
    while IFS= read -r root; do
      case "$f" in "$root/payload/"*) rel="${f#"$root/payload/"}"; break ;; esac
    done <<LOOP_INPUT
$roots_list
LOOP_INPUT
    inst="$installed/$rel"
    if [ -n "$rel" ] && {
      { [ ! -e "$f" ] && [ ! -e "$inst" ]; } ||
      { [ -f "$f" ] && [ -f "$inst" ] && { cmp -s "$f" "$inst" ||
        { [ -n "${HOME_TOKEN:-}" ] && grep -Iq -F -- "$HOME_TOKEN" "$f" 2>/dev/null &&
          home_detok "$installed" < "$f" | cmp -s - "$inst"; }; }; }
    }; then matched=$((matched + 1)); else differ="$differ$f
"; fi
  done <<LOOP_INPUT
$changed
LOOP_INPUT
  changed="$(printf '%s' "$differ" | sed '/^$/d')"
  [ -n "$changed" ] || exit 0
  n="$(printf '%s\n' "$changed" | grep -c .)"
  shown="$(printf '%s\n' "$changed" | awk 'NR <= 20 { print "  " $0 }')"
  [ "$n" -gt 20 ] && shown="$shown
  ... and $((n - 20)) more"
  [ "$matched" -gt 0 ] && shown="$shown

  $matched more already matched the installed config at $installed, so the daemon has nothing to revert there, and are left out."
  others_note "the command below"
  cat >&2 <<MSG
claude-sync: $n file(s) changed under a development checkout's payload/ while that command ran, with a watch daemon live from another clone and no hold of this session's in force. What was measured is what changed while it ran, so another session or a parallel command writing there at the same moment would show here too:

$shown

${OTHERS_NOTE}Nothing in the command's words showed those writes, so they could not be refused before it ran. The daemon mirrors ~/.claude up over payload/ and pushes, so these edits can be reverted silently, as 84 files were on 2026-09-03. Protect them now, before anything else:

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
    # A reader that fails here is refused rather than taken for a call that writes nothing
    # (claude-config#1900, L1033).
    targets="$(printf '%s' "$payload" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
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
' 2>/dev/null)" || refuse_unread "$UNREAD"
    ;;
  Bash)
    cmd="$(ps_parse_payload "$payload" raw 2>/dev/null)" || refuse_unread "$UNREAD"
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
    targets="$(printf '%s' "$cmd" | GATE_CWD="$cwd" PS_SHELL_WORDS="$PS_SHELL_WORDS" python3 -B -c '
import importlib.util, os, re, sys

sys.stdout.reconfigure(errors="replace")
cmd = sys.stdin.buffer.read().decode("utf-8", "replace")
GIT_WRITERS = ("checkout", "restore", "rm", "mv")
# Which git subcommand a command runs is read by lib/shell-words.py (git_command), the one reading
# of git every gate asks (claude-config#1188): past assignments, rtk, env and sudo, and the options
# git takes itself. With that file missing, any command naming git and a subcommand that writes is
# taken for it, the reading that sees more writes, never fewer (L42).
try:
    _spec = importlib.util.spec_from_file_location("shell_words", os.environ["PS_SHELL_WORDS"])
    _sw = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_sw)
    git_command, GIT_VALUED = _sw.git_command, _sw.GIT_VALUED
except Exception:
    GIT_VALUED = {"-C"}
    def git_command(words):
        names = [w.lstrip("({").split("/")[-1] for w in words]
        for k, w in enumerate(words):
            if "git" in names and w in GIT_WRITERS:  # gh-reader: the crude reading, when there is no other
                return (w, [], words[k + 1:])
        return None
cwd = os.environ.get("GATE_CWD") or os.getcwd()
targets = []

# A directory only the shell can work out (a cd to a variable, or to an OLDPWD this cannot know) is
# kept as its words behind this mark, never taken for the directory it was moved from: that let a
# write after `cd "$P"` be judged where the session was and let through (claude-config#2128).
UNKNOWN = "\x00"
SHELL_VALUE = re.compile(r"\$[A-Za-z_{(0-9@*#?$!-]|`")
HOME = os.environ.get("HOME", "")

def place(tok, base):
    """Where tok names, read from base as the shell reads it: (path, True), or (its words, False)
    when only the shell can work it out. HOME is the same for this hook and the command, and PWD is
    the directory the command runs in, so both are expanded; any other value is not guessed at."""
    tok = tok.strip().strip("\"\x27")
    if not tok:
        return None, True
    if tok.startswith("~"):
        tok = os.path.expanduser(tok)
    if HOME:
        tok = re.sub(r"\$(?:HOME|\{HOME\})(?![A-Za-z0-9_])", lambda m: HOME, tok)
    known = not base.startswith(UNKNOWN)
    if known:
        tok = re.sub(r"\$(?:PWD|\{PWD\})(?![A-Za-z0-9_])", lambda m: base, tok)
    elif not tok.startswith("/"):
        return base[len(UNKNOWN):].rstrip("/") + "/" + tok, False
    if SHELL_VALUE.search(tok):
        return tok, False
    if not tok.startswith("/"):
        tok = os.path.join(base, tok)
    return os.path.normpath(tok), True

def resolve(tok, base):
    p, known = place(tok, base)
    if not p:
        return None
    if known:
        return p
    # A value only the shell knows. Counted only when its words name payload, as before, and then
    # judged as the payload write it may be, marked with a leading ? (claude-config#2128).
    return "?" + p if re.search(r"(^|/)payload(/|$)", p) else None

def move(dest, base):
    """Where a cd to dest leaves the commands after it: a path, or the words behind UNKNOWN."""
    if dest == "-":
        return UNKNOWN + "-"
    p, known = place(dest, base)
    if not p:
        return base
    return p if known else UNKNOWN + p.lstrip(UNKNOWN)

def add(tok, base):
    p = resolve(tok, base)
    if p:
        targets.append(p)

# Every line is read as shell, a heredoc body line included (Dan, 2026-11-02, "Also read heredoc
# text", claude-config#2080). A body is data the shell never runs, so a `a > b` in one can be refused
# as a redirect; that was chosen over a reading of where a body ends that could ever hide a command
# after it, as the pattern this gate kept did with <<'E'OF, <<END-OF and a << inside a quoted string.
# Where a body really ends is read by lib/shell-words.py, below, for the commands the shell runs.
shell_text = cmd

# Commands whose arguments ARE what they write. Scanned per segment, in order, so a read in one
# segment is not blamed on a write in the next, and a `cd` moves where the rest resolve.
WRITERS = ("tee", "cp", "mv", "rm", "touch", "mkdir", "patch", "install", "rsync", "truncate",
           "ln", "ditto", "unlink", "rmdir")
base = cwd
CD_TO = object()  # marks a segment that is a directory the commands after it run in
segments = re.split(r"&&|\|\||;|\||\n", shell_text)
# The commands a shell runs from its -c string, eval from its words and env -S from its string
# (claude-config#1478), read by lib/shell-words.py as commands of their own, each after a cd to the
# directory it runs in, so a cd inside one moves only what follows it there. Only added to the
# segments of the whole command above, which still read every line of it, heredoc bodies included.
# So are the commands inside a substitution, which those segments never read as commands of their
# own, those in the body of a heredoc whose end marker is unquoted among them, since the shell runs
# them too (claude-config#2053). And with a heredoc, every command it runs, each in the directory it
# runs in: the segments above read a cd in a body as moving the commands after it, which the shell
# never does (claude-config#2080).
try:
    for d, text, _, _, depth in _sw.every_command(cmd):
        if depth > 0 or "$(" in cmd or "`" in cmd or "<<" in cmd:
            # The directory itself, never a `cd` segment: those are cut into words at each space,
            # so a checkout whose path holds one resolved against its first word (#2080). One the
            # reading could not work out is kept as its words, never as where the session is (#2128).
            segments += [(CD_TO, move(d, cwd) if d else cwd)] + re.split(r"&&|\|\||;|\||\n", text)
except Exception:
    # With no reading of the wrapped commands, a command naming a wrapper has every payload path it
    # holds taken for a write: the reading that sees more writes, never fewer (L42). So does one
    # with a heredoc, whose body lines the cut above reads as shell: a cd in a body moves the writes
    # after it there, and only this reading put them back where the shell runs them (#2080).
    # Each path is judged where the session is AND wherever any cd in the command could have left
    # it, since which of those it runs in cannot be read here (claude-config#2128).
    if "<<" in cmd or re.search(r"(^|[^A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh|eval|env|find|watch|script|parallel)([^A-Za-z0-9_.-]|$)", cmd):
        bases, last = [cwd], cwd
        for m in re.finditer(r"(?:^|[\s;&|(])(?:cd|pushd)\s+([^\s;&|<>()]+)", cmd):
            last = move(m.group(1), last)
            bases += [move(m.group(1), cwd), last]
        for m in re.finditer(r"[^\s\"\x27;&|<>()]*payload/[^\s\"\x27;&|<>()]*", cmd):
            for b in bases:
                add(m.group(0), b)
# An inline script that can write, and names a payload path. Most of this repo own payload edits
# are made this way, and the path is routinely held in a variable before it is opened, so the test
# is the script holding a payload path AND any writing call at all, not the two on one line.
WRITE_CALLS = (r"open\([^)]*,\s*[\"\x27][^\"\x27]*[wax+]", r"\.write_(text|bytes)\(",
               r"shutil\.(copy|copy2|copyfile|copytree|move|rmtree)\(",
               r"os\.(replace|rename|remove|unlink|makedirs|mkdir|rmdir)\(", r"\.unlink\(",
               r"\.rename\(", r"\.touch\(", r"writeFileSync|appendFileSync|File\.write")
WRITE_SCRIPT = any(re.search(p, cmd) for p in WRITE_CALLS)
SCRIPT_PATH = r"[\"\x27]([^\"\x27\s]*payload/[^\"\x27\s]*)[\"\x27]"
# The original single line form, kept: a literal opened for writing in place.
OPENED_PATH = r"open\(\s*([\"\x27][^\"\x27]+[\"\x27])\s*,\s*[\"\x27][wa]"
placed = set()
for seg in segments:
    if isinstance(seg, tuple) and seg[0] is CD_TO:
        base = seg[1]
        continue
    # A redirect TARGET: the word after > or >> (or 2>, &>, a fd form), attached or separated.
    for m in re.finditer(r"(?:^|[^0-9<>&|])(?:[0-9]*|&)>>?\s*([^\s;&|<>]+)", seg):
        add(m.group(1), base)
    # A script opens a relative path from where it runs, which is where a cd earlier in the command
    # left it, not the session directory (claude-config#2128).
    for m in (re.finditer(SCRIPT_PATH, seg) if WRITE_SCRIPT else ()):
        add(m.group(1), base)
        placed.add(m.group(1))
    for m in re.finditer(OPENED_PATH, seg):
        add(m.group(1), base)
        placed.add(m.group(1))
    words = seg.split()
    if not words:
        continue
    k = 0
    while k < len(words) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[k]):
        k += 1
    if k >= len(words):
        continue
    # Past the launchers that run the command after them, sudo, env, nohup, timeout, xargs and the rest
    # (lib/shell-words.py RUNNERS, claude-config#1478), so `sudo cp x payload/y` is the copy it runs.
    try:
        past = _sw.command_rest(" ".join(words[k:]))[0].split() or words[k:]
    except Exception:
        past = words[k:]
    head = past[0].lstrip("(").rsplit("/", 1)[-1]
    args = past[1:]
    found = git_command(words[k:])
    if found:
        # Past the options git itself takes to the subcommand: -C names the directory the paths
        # resolve against, and the others that take a value are not the subcommand.
        gbase, (sub, front, rest) = base, found
        i = 0
        while i < len(front):
            if front[i] == "-C" and i + 1 < len(front):
                gbase = move(front[i + 1], gbase)
            i += 2 if front[i] in GIT_VALUED else 1
        if sub in GIT_WRITERS:
            # checkout and restore name a branch or commit before `--`, and only the paths after
            # it are rewritten; a bare `git checkout main` switches branches and names no path.
            if sub == "restore":
                # --staged alone rewrites the index, never the file; -s/--source names a commit.
                if ("--staged" in rest or "-S" in rest) and not ("--worktree" in rest or "-W" in rest):
                    rest = []
                kept, skip = [], False
                for w in rest:
                    if skip:
                        skip = False
                    elif w in ("-s", "--source"):
                        skip = True
                    elif w != "--":
                        kept.append(w)
                rest = kept
            elif sub == "checkout" and "--" in rest:
                rest = rest[rest.index("--") + 1:]
            elif sub == "checkout":
                rest = []
            for w in rest:
                if not w.startswith("-"):
                    add(w, gbase)
        continue
    if head in ("cd", "pushd"):
        dest = next((w for w in args if w == "-" or not w.startswith("-")), "~")
        base = move(dest, base)
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
    elif head in WRITERS:
        for w in args:
            if not w.startswith("-"):
                add(w, base)

# Read over the whole command too, for a script path the cut into segments split (a quoted path
# holding a ; or |): one no segment placed is judged where the session is, as it always was,
# rather than not at all (L42).
for m in (re.finditer(SCRIPT_PATH, cmd) if WRITE_SCRIPT else ()):
    if m.group(1) not in placed:
        add(m.group(1), cwd)
for m in re.finditer(OPENED_PATH, cmd):
    if m.group(1) not in placed:
        add(m.group(1), cwd)

seen = []
for t in targets:
    if t not in seen:
        seen.append(t)
print("\n".join(seen))
' 2>/dev/null)" || refuse_unread "payload-write-gate.sh read this command and then could not work out which files it writes: the reading of where a shell command writes failed partway, and a watch daemon is live on this Mac running from another clone. A reading that failed is not one that found nothing, so the call is refused rather than allowed (claude-config#1900)."
    ;;
  *) exit 0 ;;
esac

# Which clone each target is in, and whether that clone is at risk. Asked per target, because one
# command can name paths in two checkouts.
refuse_root=""
refuse_path=""
refuse_unplaced=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$t" in
    # A path only the shell can work out, whose words name payload/ (claude-config#2128). Which
    # checkout it lands in cannot be read, so it is judged as the payload write it may be: refused
    # while a watcher could revert it, unless this session holds the watcher off. Never let through
    # for want of a place to judge it, which is what every such path was before.
    "?"*)
      [ -n "$(sc_watcher_cmd || true)" ] || continue
      sc_hold_covers "$sid" && continue
      refuse_unplaced="${t#?}"; break ;;
    /*) ;;
    *)  t="$cwd/$t" ;;
  esac
  # Judged from the nearest directory that exists: one a command is about to make (mkdir -p, a copy
  # into a new folder) cannot be entered, and was skipped unjudged when this read only the target's
  # own directory (claude-config#2128).
  d="$(dirname "$t")"
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d="$(dirname "$d")"; done
  root="$(sc_clone_root_of "$d")" || continue
  [ -n "$root" ] || continue
  # Only payload/ is mirrored. An edit to claude-sync itself, or to tests/, is this checkout's own
  # work and the daemon never touches it. The part of the path below that directory is kept, so a
  # target that IS payload/, or a folder in it not made yet, is still read as under payload/.
  case "$(cd "$d" 2>/dev/null && pwd -P)${t#"$d"}/" in "$root/payload/"*) ;; *) continue ;; esac
  wcmd="$(sc_watcher_cmd || true)"
  [ -n "$wcmd" ] || continue                       # no watcher: nothing can revert anything
  sc_is_this_clone "$root" "$wcmd" && continue     # the watcher runs from HERE: this is its source
  sc_is_own_worktree "$root" && continue          # a linked worktree on its own branch (#800)
  sc_hold_covers "$sid" && continue                # held off by THIS session, or a terminal (#1886)
  refuse_root="$root"; refuse_path="$t"; break
done <<TARGETS
$targets
TARGETS

# BEFORE a Bash call it let through: a note of what each at risk payload/ holds, for the check after
# it to compare against (claude-config#647). Taken only in the state that loses work, a live watcher
# from another clone and no hold covering this session (the same question the refusal asks, so a
# call let through on another session's hold still has its note, claude-config#1886), and only for
# the checkouts this command could reach: the one it runs in, and any its words name. Two finds
# over a few hundred files, never one process per file.
note_payload_before(){
  local wcmd roots="" dir root
  [ "$tool" = "Bash" ] && [ "$use_id" != "-" ] || return 0
  wcmd="$(sc_watcher_cmd || true)"
  [ -n "$wcmd" ] || return 0
  sc_hold_covers "$sid" && return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    root="$(sc_clone_root_of "$dir" 2>/dev/null)" || continue
    [ -n "$root" ] || continue
    sc_is_this_clone "$root" "$wcmd" && continue
    sc_is_own_worktree "$root" && continue    # nothing mirrors into it, so nothing to report (#800)
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

if [ -n "$refuse_unplaced" ]; then
  others_note "the third way below"
  cat >&2 <<MSG
claude-sync: REFUSED a write to $refuse_unplaced, a path only the shell can work out.

Its words name payload/, but they hold a value this gate cannot read (a variable, a command's output, or a cd to one of those), so which checkout it lands in is unknown, and a watch daemon is live on this Mac running from another clone. That daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to a development checkout's payload/ is overwritten by it, silently. A path that cannot be placed is judged as the payload write it may be, never let through (claude-config#2128).

${OTHERS_NOTE}Three ways on:

  1. Write the path out in full, so it can be judged where it really lands.
  2. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  3. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
fi

if [ -z "$refuse_root" ]; then
  note_payload_before
  exit 0
fi

others_note "the second way below"
cat >&2 <<MSG
claude-sync: REFUSED a write to $refuse_path.

This is a development checkout at $refuse_root, and a watch daemon is live on this Mac running from another clone. That daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ here is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit and deleted a file that existed only in the repo.

${OTHERS_NOTE}Two ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"

A hold expires. When it does, make ~/.claude match what is in the checkout, or the next send reverts it again.
MSG
exit 2
