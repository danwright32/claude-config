#!/usr/bin/env bash
#
# mod-reload-failed.sh: tell Dan when a mod's reload has failed and this session is still running
# the older copy of it (claude-config#3309).
#
# When a mod changes on disk, an interactive session reloads it. When that reload fails, Claude Code
# writes one row into the session's transcript, "<mod>: reload failed, the previous version stays
# loaded: <why>", and goes on running the copy it already had. Nothing else says so, and the row is
# repeated at every later attempt. On the work MacBook a session ran on an old mod-kit from 16 to 22
# October 2026, 52 such rows, while the mods depending on it said 240 times that they were "out of
# step in this session"; on 21 October the old code wrongly refused a builder's edit. On this Mac a
# session ran three days on an old picker-manners (5 to 8 November, 13 rows). claude-sync status
# was right to stay quiet (the installed mods were current), and rule-files-changed.sh speaks of a
# mod a pull added, removed or replaced, never of one whose reload was refused.
#
# WHAT IT READS. The transcript, whose path every hook payload carries. Measured over this Mac's
# transcripts on 2026-11-23: the failure is a row of type system, subtype informational, whose
# content opens with the mod's name; a reload that worked is the same kind of row, "<mod>: reloaded
# (...)" or "<mod>: plugin.json changed <dash> reloaded (...)". The same words quoted anywhere else
# (a brief, an issue, a tool result) are not that row, so they count for nothing. A mod's own "out
# of step" sentence is a different cause, which that mod already tells (skew.ts's skewNews), so it
# counts for nothing here either (L11). Being a settings hook, this depends on no mod, so a frozen
# mod cannot silence it (L71).
#
# WHEN IT SPEAKS. On a prompt, once per mod per failure: the first failed reload after the copy
# loaded is told, the ones after it are not, a reload that works ends it quietly, and a failure after
# that is a new one. Told again only when the same old copy is still running a day after it was last
# told (CLAUDE_MOD_RELOAD_RETELL_AFTER, 86400 seconds): long enough that a session in daily use hears
# it at most once a day, short enough that a session left frozen for a week is reminded (L36). It
# says it to Dan as a systemMessage, the channel shown to him (lib/hook-notice.sh), and hands the
# session the same words with Claude Code's reason and how to report a refusal from that mod.
#
# WHICH PROCESS. A process loads every mod afresh when it starts (a new session, or a resume in a new
# process), so a failure row written before this process started says nothing about the copy running
# now, and a change of process forgets every failure recorded under the last one. The process is
# this hook's parent, Claude Code itself (measured for rule-files-changed.sh, claude-config#1684).
#
# COST. It reads only what the transcript gained since the last prompt, and only whole lines: a row
# still being written is read at the next prompt. The first prompt of a session that started before
# this hook reads the whole file once (a 266 MB transcript here).
#
# Env, for the suite:
#   CLAUDE_MOD_RELOAD_STATE_DIR      where the per session record is kept (default TMPDIR)
#   CLAUDE_MOD_RELOAD_PROCESS        the process's identity (default PPID)
#   CLAUDE_MOD_RELOAD_PROCESS_START  when it started, in seconds since the epoch (default from ps)
#   CLAUDE_MOD_RELOAD_NOW            the clock, in seconds since the epoch (default now)
#   CLAUDE_MOD_RELOAD_RETELL_AFTER   seconds before an unchanged failure is told again (default 86400)
set -uo pipefail

input="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) MRF_DIR="${BASH_SOURCE[0]%/*}" ;; *) MRF_DIR=. ;; esac
MRF_DIR="$(cd "${MRF_DIR:-/}" && pwd)"
# A lone surrogate escape anywhere in the payload makes it unreadable as JSON (claude-config#1944).
. "$MRF_DIR/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"
# shellcheck source=lib/hook-notice.sh
. "$MRF_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

command -v python3 >/dev/null 2>&1 || exit 0

PROC="${CLAUDE_MOD_RELOAD_PROCESS:-$PPID}"
PROC_START="${CLAUDE_MOD_RELOAD_PROCESS_START:-}"
if [ -z "$PROC_START" ]; then
  PROC_START="$(ps -o lstart= -p "$PROC" 2>/dev/null || true)"
fi
STATE_DIR="${CLAUDE_MOD_RELOAD_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# One python prints the person's text and the session's context, joined by the unit separator, or
# nothing. The record is written before anything is printed, so a notice cannot repeat itself if the
# printing fails: once too few is the safe side here (L36).
said="$(printf '%s' "$input" | MRF_STATE_DIR="$STATE_DIR" MRF_PROC="$PROC" MRF_PROC_START="$PROC_START" \
  MRF_NOW="${CLAUDE_MOD_RELOAD_NOW:-}" MRF_RETELL="${CLAUDE_MOD_RELOAD_RETELL_AFTER:-86400}" python3 -c '
import datetime, hashlib, json, os, re, sys, time
sys.stdout.reconfigure(errors="replace")

try:
    payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "{}")
except Exception:
    payload = {}
session = str(payload.get("session_id") or payload.get("transcript_path") or "")
path = str(payload.get("transcript_path") or "")
if not session:
    sys.exit()

now = float(os.environ["MRF_NOW"]) if os.environ["MRF_NOW"] else time.time()
try:
    retell = float(os.environ["MRF_RETELL"])
except ValueError:
    retell = 86400.0

def proc_start():
    v = os.environ["MRF_PROC_START"].strip()
    if not v:
        return 0.0
    try:
        return float(v)
    except ValueError:
        pass
    try:
        return time.mktime(time.strptime(" ".join(v.split()), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return 0.0  # unknown: every row counts, which misreads only a resume in a new process

key = hashlib.sha1(session.encode("utf-8", "replace")).hexdigest()[:12]
state_path = os.path.join(os.environ["MRF_STATE_DIR"], "claude-mod-reload-%s.json" % key)
try:
    with open(state_path) as f:
        st = json.load(f)
    if not isinstance(st, dict):
        st = {}
except Exception:
    st = {}

proc = os.environ["MRF_PROC"]
start = proc_start()
if st.get("proc") != proc:
    # A new process loaded every mod afresh: what the last one recorded is about copies gone now.
    st = {"proc": proc, "start": start, "offset": st.get("offset", 0), "path": st.get("path"),
          "unread": st.get("unread"), "loaded": {}, "failing": {}}
start = st.get("start", start) or 0.0
if st.get("path") != path:
    st["path"], st["offset"] = path, 0

def save():
    try:
        tmp = state_path + ".%d" % os.getpid()
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, state_path)
    except Exception:
        pass

FAIL = re.compile(r"^([\w.@-]+): reload failed, the previous version stays loaded(?:: (.*))?$", re.S)
# "reloaded (" right after the name, or after one "<file> changed <dash> " (Claude Code names the file
# that changed). mod-kit saying a mod "could not be asked to load again after mod-kit reloaded (" is
# neither.
GOOD = re.compile(r"^([\w.@-]+): (?:\S+ changed \S+ )?reloaded \(")

def when(iso):
    try:
        return datetime.datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None

try:
    f = open(path, "rb")
except Exception:
    if not st.get("unread"):
        st["unread"] = True
        save()
        print("mod-reload-failed: could not read the transcript of this session (%s), so a mod whose reload fails in this session will not be noticed by this check. A new session starts a new transcript." % (path or "no path was given"))
    sys.exit()
st["unread"] = False

loaded, failing = st.setdefault("loaded", {}), st.setdefault("failing", {})
with f:
    off = int(st.get("offset") or 0)
    f.seek(0, 2)
    if f.tell() < off:
        off = 0  # the file was replaced under the same path: read it again from the start
    f.seek(off)
    data = f.read()
end = data.rfind(b"\n") + 1  # a row still being written is read at the next prompt
st["offset"] = off + end
for line in data[:end].split(b"\n"):
    if b"informational" not in line or (b"reload" not in line):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "system" or d.get("subtype") != "informational":
        continue
    text = d.get("content")
    t = when(str(d.get("timestamp") or ""))
    if not isinstance(text, str) or t is None or t < start:
        continue
    m = FAIL.match(text)
    if m:
        mod = m.group(1)
        e = failing.get(mod)
        if e is None:
            failing[mod] = {"first": t, "count": 1, "why": (m.group(2) or "").strip(), "told": None}
        else:
            e["count"] += 1
        continue
    g = GOOD.match(text)
    if g:
        loaded[g.group(1)] = t
        failing.pop(g.group(1), None)

due = [m for m in sorted(failing, key=lambda n: failing[n]["first"])
       if failing[m]["told"] is None or now - failing[m]["told"] >= retell]
if not due:
    save()
    sys.exit()
for m in due:
    failing[m]["told"] = now
save()

try:
    from zoneinfo import ZoneInfo
    ET = ZoneInfo("America/New_York")
except Exception:
    ET = None

def et(ts):
    if ET is None:
        return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%H:%M UTC on %d %B").lstrip("0")
    t = datetime.datetime.fromtimestamp(ts, ET)
    return "%d:%02d %s ET on %d %s" % ((t.hour % 12) or 12, t.minute, "AM" if t.hour < 12 else "PM", t.day, t.strftime("%B"))

def sentence(m):
    e = failing[m]
    copy = ("the copy of it loaded at %s" % et(loaded[m])) if m in loaded else "the copy of it this session loaded when it started"
    if e["count"] == 1:
        head = "%s failed to reload at %s" % (m, et(e["first"]))
    else:
        head = "%s has failed to reload %d times since %s" % (m, e["count"], et(e["first"]))
    return "%s, so this session is still running %s." % (head, copy)

names = " and ".join([", ".join(due[:-1]), due[-1]] if len(due) > 1 else due)
if len(due) == 1:
    tail = "Its hooks, gates and guards may act on rules that have changed since, so a refusal from it may be wrong."
else:
    tail = "Their hooks, gates and guards may act on rules that have changed since, so a refusal from one of them may be wrong."
person = " ".join([sentence(m) for m in due] + [tail, "Start a new session to run the current %s." % names])
reasons = " ".join("Claude Code gave this reason for %s: %s." % (m, failing[m]["why"].rstrip(".")) for m in due if failing[m]["why"])
context = " ".join(x for x in (person, reasons,
    "Until a new session, when %s refuses or blocks something, say in your reply that the refusal came from an out of date copy and may be wrong. The refusal still stands; tell Dan rather than working around it." % names) if x)
sys.stdout.write(person + "\x1f" + context)
' 2>/dev/null || true)"

[ -n "$said" ] || exit 0
case "$said" in
  *$'\x1f'*) hook_allow_notice "${said%%$'\x1f'*}" UserPromptSubmit "${said#*$'\x1f'}" ;;
  *) hook_allow_notice "$said" ;;
esac
