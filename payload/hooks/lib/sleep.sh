# sleep.sh: the shell's reader of the machine wide sleep record (claude-config#840).
#
# Sourced, never run. Sleep mode keeps one record for the whole Mac, ~/.claude/state/sleep/current.json,
# written by the scope modes mod at /sleep. While it holds, the Mac is asleep: every session is kept
# quiet and only the sessions it names in `workers` work on. This answers the same question as the
# mod's readSleep (mods/scope-modes/hooks/sleep.ts), checked in the same order, and the two are held
# to one committed fixture set (mods/scope-modes/tests/sleep-fixtures.ts, test-sleep-state.sh, L26).
# It reads the file every time it is asked; nothing here caches whether the Mac is asleep (L175).
#
#   . "$HOME/.claude/hooks/lib/sleep.sh"
#   if sleep_active; then ...stay quiet...; fi
#   state="$(sleep_state)"        # asleep, none, expired, other-boot or unreadable
#   why="$(sleep_why)"            # why it reads as unreadable; empty otherwise
#
# Only asleep is asleep. A record past its `until` (noon ET the day after the night) or written in
# another boot reads as awake, and so does one that cannot be read, since a mute that cannot say when
# it ends must never hold (L523): a page that should not have come beats a silence nobody can see.
#
# Arguments, each optional, for a caller that already has them and for the tests: the record's path,
# now in ms since the epoch, and this boot's start in seconds (`none` when it is not known, when only
# the record's end decides). Every
# answer comes back on stdout, never through a variable, since a caller reads it in a subshell.

# This boot's start in seconds, from what `sysctl -n kern.boottime` prints ("{ sec = N, usec = M }
# ..."): the number after the first `sec =`, as the mod's bootOf reads it, never the microseconds
# after it. Nothing when the text names none. Held to the mod's cases in BOOT_FIXTURES (#838).
sleep_boot_of() {
  printf '%s\n' "${1:-}" | sed -n '1s/^[^0-9]*sec *= *\([0-9][0-9]*\).*/\1/p'
}

# The state on the first line and why on the second (empty but for unreadable).
_sleep_read() {
  local file="${1:-$HOME/.claude/state/sleep/current.json}" now="${2:-}" boot="${3:-}" out
  if [ ! -e "$file" ]; then
    printf 'none\n\n'
    return 0
  fi
  [ -n "$now" ] || now="$(date +%s)000"
  [ -n "$boot" ] || boot="$(sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)")"
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'unreadable\npython3 is not installed, so the sleep record cannot be read\n'
    return 0
  fi
  out="$(python3 - "$file" "$now" "$boot" <<'PY' 2>&1
import json, math, sys

def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)

def say(state, why=""):
    print(state)
    print(why)
    sys.exit(0)

path, now, boot = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(path) as fh:
        text = fh.read()
except Exception as e:
    say("unreadable", "the sleep record could not be read (%s)" % e)
try:
    r = json.loads(text)
except Exception:
    say("unreadable", "the sleep record is not JSON")
if not isinstance(r, dict):
    say("unreadable", "the sleep record is not a record")
if not num(r.get("v")) or r["v"] < 1:
    say("unreadable", "the sleep record has no version this reader knows")
if not num(r.get("until")):
    say("unreadable", "the sleep record names no end")
if not num(r.get("bootTime")):
    say("unreadable", "the sleep record names no boot")
# This boot unknown (sysctl failed) only skips the boot check: the end of the record still bounds it.
# (No apostrophe in this program: macOS bash 3.2 reads quotes inside a heredoc in a command substitution.)
if boot.isdigit() and r["bootTime"] != int(boot):
    say("other-boot")
if now >= r["until"]:
    say("expired")
say("asleep")
PY
)"
  case "${out%%$'\n'*}" in
    asleep|expired|other-boot|unreadable)
      local why="${out#*$'\n'}"
      [ "$why" = "$out" ] && why=""
      printf '%s\n%s\n' "${out%%$'\n'*}" "$why" ;;
    *)
      local flat="${out//$'\n'/ }"
      printf 'unreadable\n%s\n' "the sleep record's reader failed: ${flat:0:200}" ;;
  esac
}

# asleep, none, expired, other-boot or unreadable.
sleep_state() {
  local r
  r="$(_sleep_read "$@")"
  printf '%s\n' "${r%%$'\n'*}"
}

# Why the record reads as it does, for the caller that reports it: empty unless unreadable.
sleep_why() {
  local r
  r="$(_sleep_read "$@")"
  [ "$r" = "${r#*$'\n'}" ] || printf '%s\n' "${r#*$'\n'}"
}

# Exit 0 only while the Mac is asleep.
sleep_active() {
  [ "$(sleep_state "$@")" = asleep ]
}

# The one writer of the night's notes (claude-config#835), for every phase that has something for
# the morning report: a question, a finding, a proposed issue or lesson, done, parked or failed
# work, a heartbeat, a rate limit wait. Never write the notes file or the report yourself.
#
#   sleep_note '{"kind":"done","by":"<session id>","repo":"owner/name","issue":12,"pr":34,"text":"..."}'
#
# The argument is one JSON object with a `kind`; the kinds the report knows and the fields each
# reads are listed in lib/sleep-report.py. It is written only while the Mac is asleep (this file's
# own predicate, asked first), appended as one line to notes/<generation>.jsonl, and the report in
# Downloads is rendered again. Exit 0 once the note is written, even when the report could not be
# rendered after it (said on stderr: the note is the record, and the report is rendered again at
# wake); 1 when the note was refused or not written, with why on stderr. The record, now and this
# boot may follow, as for sleep_state, for the tests.
# The script beside this file when bash sourced it; under a shell with no BASH_SOURCE (zsh) this
# file cannot know where it is, so the installed copy is used, never one in the caller's folder.
_SLEEP_LIB_DIR=""
[ -n "${BASH_SOURCE[0]:-}" ] && _SLEEP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
sleep_note() {
  local line="${1:-}" file="${2:-$HOME/.claude/state/sleep/current.json}" state script
  state="$(sleep_state "$file" "${3:-}" "${4:-}")"
  if [ "$state" != asleep ]; then
    printf 'sleep_note: not written, since the Mac is not asleep (the sleep record reads as %s)\n' "$state" >&2
    return 1
  fi
  script="$HOME/.claude/hooks/lib/sleep-report.py"
  [ -n "$_SLEEP_LIB_DIR" ] && [ -f "$_SLEEP_LIB_DIR/sleep-report.py" ] && script="$_SLEEP_LIB_DIR/sleep-report.py"
  if [ ! -f "$script" ]; then
    printf 'sleep_note: not written, since sleep-report.py is neither beside sleep.sh (%s) nor installed (%s)\n' "${_SLEEP_LIB_DIR:-not known}" "$script" >&2
    return 1
  fi
  python3 "$script" note --record "$file" --line "$line" || return 1
}
