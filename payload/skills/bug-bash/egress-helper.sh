#!/bin/bash
#
# egress-helper.sh: the one thing a bug bash read only run does as root (claude-config#813).
#
# egress-setup.sh installs a copy of this file, once, as /usr/local/libexec/bug-bash-egress, owned
# by root so that no process of Dan's can change what it does, and lets Dan's user run that copy
# through sudo without a password for exactly these three verbs:
#
#   bug-bash-egress load <owner pid> <port> <address>...
#       Refuse every TCP and UDP connection from this Mac to those addresses on that port (and on
#       80 and 443 both, when the port is either), unless it comes from a process in the _bugbash
#       group, which is the read only proxy's. <owner pid> is the proxy the rule is for: a rule
#       whose owner is still running is never replaced, one whose owner is gone is.
#   bug-bash-egress unload [<owner pid>]
#       Take the rule away; with an owner, only when that process holds it.
#   bug-bash-egress status
#       What the packet filter holds now, one fact a line, for egress.sh to check.
#
# Every verb first sweeps: a rule whose owner has died, or whose pid now runs something that is not
# the read only proxy, is removed before anything else, so a proxy killed outright cannot leave the
# Mac refused a site for longer than the next call.
#
# The rule lives in one pf anchor of its own, com.apple/000.bug-bash-read-only. The system's own
# /etc/pf.conf already evaluates every anchor under com.apple/ (`anchor "com.apple/*"`), so this
# never loads, flushes or edits the main ruleset, and the 000 sorts it ahead of Apple's own anchors.
# pf is switched on by reference (-E, which hands back a token, released with -X), so a run never
# switches it off under anything else that uses it. Every argument is checked against a strict
# shape before anything reaches pfctl, since this runs as root, and the rules file is written here,
# in a directory only root can write.
#
# Exit codes: 0 done, 2 usage or a refused argument, 4 another live run holds the rule, 5 pfctl
# refused, 6 another load or unload is under way.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
IFS=$' \t\n'
umask 077

ANCHOR='com.apple/000.bug-bash-read-only'
TABLE='bug_bash_targets'
GROUP='_bugbash'
MAX_ADDRESSES=32

TAKEOVER_GATE=""
if [ "$(id -u)" = 0 ]; then
  PFCTL=/sbin/pfctl
  STATE=/var/run/bug-bash-egress
else
  # Test only: parks this helper just after it has found the lock's holder dead, until the named
  # file exists, so the suite can stage two helpers racing to take over one stale lock.
  TAKEOVER_GATE="${BUG_BASH_EGRESS_TEST_TAKEOVER_GATE:-}"
  # Not root: only the test suite runs it this way, with a stand in pfctl and a state directory of
  # its own. Nothing done here can change the real packet filter, which only root can.
  PFCTL="${BUG_BASH_EGRESS_PFCTL:-}"
  STATE="${BUG_BASH_EGRESS_STATE:-}"
  if [ -z "$PFCTL" ] || [ -z "$STATE" ]; then
    echo "bug-bash-egress: run it through sudo: it changes the packet filter, which only root can do." >&2
    exit 2
  fi
fi

die() { local code="$1"; shift; echo "bug-bash-egress: $*" >&2; exit "$code"; }
oneline() { tr '\n' ' ' <<< "$1" | sed 's/  */ /g; s/ $//'; }

PID_RE='^[1-9][0-9]{0,9}$'
PORT_RE='^[1-9][0-9]{0,4}$'
V4_RE='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
V6_RE='^[0-9A-Fa-f:]{2,39}$'
is_pid() { [[ $1 =~ $PID_RE ]]; }
is_port() { [[ $1 =~ $PORT_RE ]] && [ "$1" -le 65535 ]; }
is_address() {
  local a="$1" i
  if [[ $a =~ $V4_RE ]]; then
    for i in 1 2 3 4; do [ "${BASH_REMATCH[$i]}" -le 255 ] || return 1; done
    return 0
  fi
  # IPv6: hex digits and colons only, with at least two colons.
  [[ $a =~ $V6_RE ]] && [ "$(tr -cd ':' <<< "$a" | wc -c | tr -d ' ')" -ge 2 ]
}
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1
}

# One load or unload at a time. The lock, $STATE/held, is a symbolic link whose target is the
# holder's pid, so the lock and the record of who holds it come into being in one atomic step
# (`ln -s` refuses when the link exists): there is never a lock with no holder on it. A lock whose
# holder has died is taken over, but only under a second lock, held.takeover, and only after
# reading the holder again inside it, so a waiter that found the holder dead a moment ago can never
# remove a lock another waiter has taken since (lessons review of #938). A takeover lock left by a
# helper that died inside it, a window of two file operations, is cleared the same way.
LOCK_LINK=""
wait_at_gate() {
  [ -n "$TAKEOVER_GATE" ] || return 0
  touch "$TAKEOVER_GATE.seen"
  local _
  for _ in $(seq 1 200); do [ -e "$TAKEOVER_GATE" ] && return 0; sleep 0.05; done
}
holder_of() { readlink "$1" 2>/dev/null; }
is_dead() { [ -n "$1" ] && ! kill -0 "$1" 2>/dev/null; }
# Removes the lock only while its holder is still $1, the dead pid this waiter saw. Succeeds (0)
# only when it removed it, so a waiter that found the takeover already under way waits its turn
# rather than spending its whole budget in a burst (lessons review of #938).
take_over() {
  local guard="$LOCK_LINK.takeover" g removed=1
  if ! ln -s "$$" "$guard" 2>/dev/null; then
    g="$(holder_of "$guard")"
    if is_dead "$g" && [ "$(holder_of "$guard")" = "$g" ]; then rm -f "$guard"; fi
    return 1
  fi
  if [ "$(holder_of "$LOCK_LINK")" = "$1" ]; then rm -f "$LOCK_LINK" && removed=0; fi
  rm -f "$guard"
  return "$removed"
}
release_lock() {
  if [ "$(holder_of "$LOCK_LINK")" = "$$" ]; then rm -f "$LOCK_LINK"; fi
}
lock() {
  mkdir -p "$STATE" && chmod 700 "$STATE" || die 5 "could not make $STATE"
  LOCK_LINK="$STATE/held"
  local _ holder
  for _ in $(seq 1 100); do
    if ln -s "$$" "$LOCK_LINK" 2>/dev/null; then
      trap release_lock EXIT
      return 0
    fi
    holder="$(holder_of "$LOCK_LINK")"
    if is_dead "$holder"; then
      wait_at_gate
      take_over "$holder" && continue
    fi
    sleep 0.1
  done
  die 6 "another load or unload of the rule has not finished after 10 s (lock $LOCK_LINK, held by pid ${holder:-unknown})."
}

# Takes the rule away and releases this rule's pf reference. Whether the rule is gone is judged by
# reading the anchor back, never by the flush's exit code or by whether an owner is on file (a
# helper killed part way leaves a rule with none). Fails (1) when a rule is still there; a
# reference that will not release is reported and forgotten, since a token pf no longer knows can
# never be released.
remove_rule() {
  local out why=""
  out="$("$PFCTL" -a "$ANCHOR" -F rules 2>&1)" || why="$(oneline "$out")"
  out="$("$PFCTL" -a "$ANCHOR" -F Tables 2>&1)" || why="${why:+$why; }$(oneline "$out")"
  if [ -n "$("$PFCTL" -a "$ANCHOR" -s rules 2>/dev/null)" ]; then
    echo "bug-bash-egress: pfctl would not remove the rule${why:+: $why}" >&2
    # Its pf reference is kept while the rule stands, so pf is never switched off under a rule
    # that is still on record as loaded.
    return 1
  fi
  if [ -f "$STATE/token" ]; then
    out="$("$PFCTL" -X "$(cat "$STATE/token")" 2>&1)" \
      || echo "bug-bash-egress: pfctl would not release the rule's pf reference: $(oneline "$out")" >&2
    rm -f "$STATE/token"
  fi
  rm -f "$STATE/owner" "$STATE/request" "$STATE/rules.conf"
}

# Whether the process a rule is on record for is still the run that loaded it: alive, and still
# the read only proxy (or the self test), so a pid the system has since handed to something else
# does not keep a rule standing.
# Judged by the shape of the whole command, never a mention anywhere in it: node running the proxy
# script, or bash running the self test. A program that merely names the file (an editor, a pager)
# is not the proxy.
OWNER_SHAPES='^([^ ]*/)?node( [^ ]+)* [^ ]*/?read-only-proxy\.js( |$)|^([^ ]*/)?bash [^ ]*egress\.sh selftest$'
owner_is_live() {
  is_pid "$1" && kill -0 "$1" 2>/dev/null || return 1
  grep -Eq "$OWNER_SHAPES" <<< "$(ps -o command= -p "$1" 2>/dev/null)"
}

# The owner check that runs on its own, first thing under the lock in every verb: a rule whose
# owner has died or is no longer the proxy (a proxy killed outright, which never ran its own
# unload) is removed, and so is one with no owner on file, which only a helper killed part way
# leaves (a load records its owner before it lets go of the lock). SWEPT names what was removed.
SWEPT=""
sweep() {
  local holder
  holder="$(cat "$STATE/owner" 2>/dev/null)"
  if [ -n "$holder" ]; then
    owner_is_live "$holder" && return 0
  elif [ -z "$("$PFCTL" -a "$ANCHOR" -s rules 2>/dev/null)" ] && [ ! -f "$STATE/token" ]; then
    return 0
  fi
  if [ -n "$holder" ]; then
    remove_rule || die 5 "the rule left by pid $holder, whose run has ended, could not be taken away, so it is still loaded."
  else
    remove_rule || die 5 "the rule left by a helper that did not finish could not be taken away, so it is still loaded."
  fi
  SWEPT="${holder:-none}"
}

# A load that failed part way: whatever pf took of it, rule or address table, goes again.
undo_partial_load() {
  "$PFCTL" -a "$ANCHOR" -F rules >/dev/null 2>&1
  "$PFCTL" -a "$ANCHOR" -F Tables >/dev/null 2>&1
  rm -f "$STATE/rules.conf"
}

do_load() {
  [ "$#" -ge 3 ] || die 2 "usage: load <owner pid> <port> <address>..."
  local owner="$1" port="$2" a list="" ports out token prior
  shift 2
  is_pid "$owner" || die 2 "the owner must be a process id, got: $owner"
  is_port "$port" || die 2 "the port must be a number from 1 to 65535, got: $port"
  [ "$#" -le "$MAX_ADDRESSES" ] || die 2 "at most $MAX_ADDRESSES addresses, got $#"
  for a in "$@"; do
    is_address "$a" || die 2 "not an IP address: $a"
    case ", $list, " in *", $a, "*) ;; *) list="${list:+$list, }$a" ;; esac
  done
  ports="$port"
  case "$port" in 80|443) ports="80, 443" ;; esac
  lock
  sweep
  prior="$(cat "$STATE/owner" 2>/dev/null)"
  if [ -n "$prior" ] && [ "$prior" != "$owner" ] && owner_is_live "$prior"; then
    die 4 "another read only run holds the rule (its proxy, pid $prior, is still running; $(cat "$STATE/request" 2>/dev/null)). End that run first."
  fi
  # Whatever is on record goes first, owner or none (a helper killed part way leaves a rule, or a
  # pf reference, with no owner), so nothing an earlier load took is overwritten and lost.
  remove_rule || die 5 "could not take away the rule already loaded${prior:+ (left by pid $prior)}, so a new one was not loaded."
  printf 'table <%s> const { %s }\nblock return out quick proto { tcp udp } from any to <%s> port { %s } group != %s\n' \
    "$TABLE" "$list" "$TABLE" "$ports" "$GROUP" > "$STATE/rules.conf"
  if ! out="$("$PFCTL" -a "$ANCHOR" -f "$STATE/rules.conf" 2>&1)"; then
    undo_partial_load
    die 5 "pfctl would not load the rule: $(oneline "$out")"
  fi
  out="$("$PFCTL" -E 2>&1)"
  token="$(sed -n 's/^Token : \([0-9][0-9]*\).*$/\1/p' <<< "$out" | head -n 1)"
  if [ -z "$token" ]; then
    undo_partial_load
    die 5 "the packet filter could not be switched on, so the rule was taken away again: $(oneline "$out")"
  fi
  echo "$token" > "$STATE/token"
  echo "$owner" > "$STATE/owner"
  echo "port $ports, addresses $list" > "$STATE/request"
  echo "loaded: connections to $list on port $ports are refused unless they come from the $GROUP group"
}

do_unload() {
  [ "$#" -le 1 ] || die 2 "usage: unload [<owner pid>]"
  local owner="${1:-}" holder
  [ -z "$owner" ] || is_pid "$owner" || die 2 "the owner must be a process id, got: $owner"
  lock
  sweep
  holder="$(cat "$STATE/owner" 2>/dev/null)"
  # For one process, only a rule on record as that process's: another live run's is left (the sweep
  # above has already taken any leftover). An unload with no owner takes whatever is there.
  if [ -n "$owner" ] && [ "$holder" != "$owner" ]; then
    if [ -n "$holder" ]; then
      echo "left in place: the rule belongs to pid $holder, not $owner"
    else
      echo "left in place: no rule is on record for pid $owner"
    fi
    return 0
  fi
  remove_rule || die 5 "the rule is still loaded."
  echo "unloaded"
}

do_status() {
  [ "$#" -eq 0 ] || die 2 "usage: status"
  local info main
  lock
  sweep
  [ -z "$SWEPT" ] || echo "swept $SWEPT"
  echo "request $(cat "$STATE/request" 2>/dev/null || echo none)"
  info="$("$PFCTL" -s info 2>/dev/null)"
  main="$("$PFCTL" -s rules 2>/dev/null)"
  if grep -q '^Status: Enabled' <<< "$info"; then echo "enabled yes"; else echo "enabled no"; fi
  if grep -q '^anchor "com.apple/\*"' <<< "$main"; then echo "anchored yes"; else echo "anchored no"; fi
  echo "owner $(cat "$STATE/owner" 2>/dev/null || echo none)"
  "$PFCTL" -a "$ANCHOR" -s rules 2>/dev/null | sed 's/^/rule /'
  "$PFCTL" -a "$ANCHOR" -t "$TABLE" -T show 2>/dev/null | sed 's/^ *//; /^$/d; s/^/target /'
  echo "helper $(sha256_of "$0")"
}

case "${1:-}" in
  load) shift; do_load "$@" ;;
  unload) shift; do_unload "$@" ;;
  status) shift; do_status "$@" ;;
  *) die 2 "usage: bug-bash-egress load <owner pid> <port> <address>... | unload [<owner pid>] | status" ;;
esac
