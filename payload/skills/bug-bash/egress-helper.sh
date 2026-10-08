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

if [ "$(id -u)" = 0 ]; then
  PFCTL=/sbin/pfctl
  STATE=/var/run/bug-bash-egress
else
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

# One load or unload at a time. The holder's pid is recorded, so a lock left by a helper that died
# is taken over rather than waited on for ever.
lock() {
  mkdir -p "$STATE" && chmod 700 "$STATE" || die 5 "could not make $STATE"
  local _ holder
  for _ in $(seq 1 100); do
    if mkdir "$STATE/lock" 2>/dev/null; then
      echo $$ > "$STATE/lock/pid"
      trap 'rm -rf "$STATE/lock"' EXIT
      return 0
    fi
    holder="$(cat "$STATE/lock/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$STATE/lock"; continue; fi
    sleep 0.1
  done
  die 6 "another load or unload of the rule has not finished after 10 s (lock $STATE/lock, pid ${holder:-unknown})."
}

# Takes the rule away and releases this rule's pf reference. Fails (1) only when the rule itself
# could not be flushed; a reference that will not release is reported and forgotten, since a token
# pf no longer knows can never be released.
remove_rule() {
  local out bad=0 had_rule=0
  [ -f "$STATE/owner" ] && had_rule=1
  if ! out="$("$PFCTL" -a "$ANCHOR" -F rules 2>&1)" && [ "$had_rule" = 1 ]; then
    echo "bug-bash-egress: pfctl would not remove the rule: $(oneline "$out")" >&2
    bad=1
  fi
  if ! out="$("$PFCTL" -a "$ANCHOR" -F Tables 2>&1)" && [ "$had_rule" = 1 ]; then
    echo "bug-bash-egress: pfctl would not remove the rule's address table: $(oneline "$out")" >&2
    bad=1
  fi
  if [ -f "$STATE/token" ]; then
    out="$("$PFCTL" -X "$(cat "$STATE/token")" 2>&1)" \
      || echo "bug-bash-egress: pfctl would not release the rule's pf reference: $(oneline "$out")" >&2
    rm -f "$STATE/token"
  fi
  [ "$bad" = 0 ] || return 1
  rm -f "$STATE/owner" "$STATE/request" "$STATE/rules.conf"
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
  if [ -f "$STATE/owner" ]; then
    prior="$(cat "$STATE/owner")"
    if [ "$prior" != "$owner" ] && is_pid "$prior" && kill -0 "$prior" 2>/dev/null; then
      die 4 "another read only run holds the rule (its proxy, pid $prior, is still running; $(cat "$STATE/request" 2>/dev/null)). End that run first."
    fi
    remove_rule || die 5 "could not take away the rule left by pid $prior, so a new one was not loaded."
  fi
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
  holder="$(cat "$STATE/owner" 2>/dev/null)"
  if [ -n "$owner" ] && [ -n "$holder" ] && [ "$holder" != "$owner" ]; then
    echo "left in place: the rule belongs to pid $holder, not $owner"
    return 0
  fi
  remove_rule || die 5 "the rule is still loaded."
  echo "unloaded"
}

do_status() {
  [ "$#" -eq 0 ] || die 2 "usage: status"
  local info main
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
