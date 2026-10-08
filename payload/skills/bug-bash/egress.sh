#!/usr/bin/env bash
#
# egress.sh: the run's side of the bug bash egress rule (claude-config#813).
#
#   bash ~/.claude/skills/bug-bash/egress.sh load <host> <port> <owner pid>
#   bash ~/.claude/skills/bug-bash/egress.sh check <host> <port> <proxy group id>
#   bash ~/.claude/skills/bug-bash/egress.sh unload [<owner pid>]
#   bash ~/.claude/skills/bug-bash/egress.sh selftest
#
# The read only proxy refuses every write that passes through it, but a browser an explorer starts
# some other way never passes through it. For a run against a deployment, so for its whole length,
# a pf rule refuses every connection from this Mac to the deployment's addresses that does not come
# from the read only proxy (which runs in the _bugbash group, started with `sudo -n -g _bugbash`).
# The rule is loaded and taken away by the root owned helper egress-helper.sh, installed once by
# egress-setup.sh; this script is what the run calls it through.
#
#   load    resolves <host> as a browser would and loads the rule for every address, owned by the
#           proxy's pid. Exit 1 naming why when it cannot.
#   check   proves the rule is in force for <host>, independently of the load: pf on, the system
#           ruleset consulting the anchor, the rule letting through exactly the proxy's group, every
#           address <host> resolves to now in the rule, the installed helper the same as this one,
#           and a direct connection to each address on <port>, from here, refused. Exit 1 naming the
#           first that fails.
#   unload  takes the rule away (only if <owner pid> holds it, when one is given).
#   selftest measures once, on this Mac, what the tests can only stand in for: with the rule loaded
#           for a listener on this machine, a direct connection is refused, a connection from the
#           _bugbash group gets through, and once the rule is gone a direct one gets through again.
#
# What the rule does not cover, said here so nothing reads more into it: an address the target
# starts answering on after the check (DNS that changes mid run, or a browser using its own DNS),
# and a process that sets out to get round it, since the same sudo grant that lets the run load and
# unload the rule lets any process of Dan's do so, or join the _bugbash group. It stops a browser
# launched carelessly some other way. And while it is loaded, every other program on this Mac,
# Dan's own browser included, is refused those addresses on that port too, which for a site on a
# shared hosting address (a CDN) means its neighbours there as well, for the length of the run.
set -uo pipefail

HELPER=/usr/local/libexec/bug-bash-egress
GROUP=_bugbash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The setup adds a sudo grant, so it waits on Dan's sign off (claude-config#813) before it ships.
SETUP_CMD='the one time setup on claude-config#813, which waits on his sign off'
SELFTEST_CMD='bash ~/.claude/skills/bug-bash/egress.sh selftest'
PROBE_TIMEOUT_MS=3000

fail() { echo "$*" >&2; exit 1; }
need_node() { command -v node >/dev/null 2>&1 || fail "node is not on PATH, and resolving the target and probing it both need it."; }
is_number() { [ -n "$1" ] && [ -z "$(tr -d '0-9' <<< "$1")" ]; }
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1
}

# Every address <host> resolves to, one a line, through the resolver a browser on this Mac uses.
resolve() {
  local host="$1"
  host="${host#[}"
  host="${host%]}"
  node -e '
require("dns").lookup(process.argv[1], { all: true }, (e, all) => {
  if (e) { console.error(e.code || e.message); process.exit(1) }
  console.log([...new Set(all.map(a => a.address))].join("\n"))
})' "$host"
}

# Which of the given addresses accept a TCP connection on <port> from this process, one a line.
# Nothing is sent on a connection that opens: it is closed at once. A refusal, an unreachable
# address and no answer within the deadline all count as not reached.
PROBE_JS='
const net = require("net")
const [port, ms, ...addrs] = process.argv.slice(1)
const reached = []
let left = addrs.length
if (!left) process.exit(2)
const done = () => { if (--left === 0) { console.log(reached.join("\n")); process.exit(0) } }
for (const host of addrs) {
  const s = net.connect({ host, port: Number(port) })
  let settled = false
  const end = ok => { if (settled) return; settled = true; if (ok) reached.push(host); s.destroy(); done() }
  s.setTimeout(Number(ms), () => end(false))
  s.on("connect", () => end(true))
  s.on("error", () => end(false))
}'
reaches() { node -e "$PROBE_JS" "$1" "$PROBE_TIMEOUT_MS" "${@:2}"; }

# Runs the installed helper through sudo, telling a refusal by sudo itself (the one time setup has
# not been done) from the helper's own refusal, which it passes on as it is.
helper() {
  local out rc
  out="$(sudo -n "$HELPER" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q '^bug-bash-egress: ' <<< "$out"; then
    out="sudo would not run the egress helper without a password ($(tr '\n' ' ' <<< "$out" | sed 's/ *$//')), so the one time setup has not been done on this Mac. It needs Dan: $SETUP_CMD, then $SELFTEST_CMD."
  fi
  printf '%s\n' "$out"
  return "$rc"
}

cmd_load() {
  [ "$#" -eq 3 ] || fail "usage: egress.sh load <host> <port> <owner pid>"
  local host="$1" port="$2" owner="$3" addrs out
  is_number "$port" && is_number "$owner" || fail "egress.sh load: the port and the owner are numbers, got: $port $owner"
  need_node
  addrs="$(resolve "$host" 2>&1)" || fail "$host does not resolve ($addrs), so there is no address to hold the rule to."
  # Word split on purpose: one address a line, none with spaces.
  # shellcheck disable=SC2086
  out="$(helper load "$owner" "$port" $addrs)" || fail "${out#bug-bash-egress: }"
  printf '%s\n' "$out"
}

cmd_check() {
  [ "$#" -eq 3 ] || fail "usage: egress.sh check <host> <port> <proxy group id>"
  local host="$1" port="$2" egid="$3" addrs status rules want got a lets reached
  is_number "$port" && is_number "$egid" || fail "egress.sh check: the port and the proxy's group id are numbers, got: $port $egid"
  need_node
  addrs="$(resolve "$host" 2>&1)" || fail "$host does not resolve ($addrs)."
  status="$(helper status)" || fail "${status#bug-bash-egress: }"
  want="$(sha256_of "$DIR/egress-helper.sh")"
  got="$(sed -n 's/^helper //p' <<< "$status")"
  [ "$got" = "$want" ] || fail "the egress helper installed on this Mac is not this version of it, so what it loads is not what this check expects. It needs Dan to run the setup again: $SETUP_CMD"
  grep -qx 'enabled yes' <<< "$status" || fail "the packet filter is off, so the rule is loaded but does nothing."
  grep -qx 'anchored yes' <<< "$status" || fail "the system's packet filter rules (/etc/pf.conf) no longer consult the com.apple anchors, so the rule would never be read."
  rules="$(grep '^rule block return out quick proto [a-z]* from any to <bug_bash_targets> ' <<< "$status")"
  [ -n "$rules" ] || fail "the egress rule is not loaded for $host."
  lets="$(sed -n 's/.* group != \([0-9][0-9]*\).*/\1/p' <<< "$rules" | sort -u | tr '\n' ' ' | sed 's/ $//')"
  if [ "$lets" != "$egid" ]; then
    fail "the rule lets through group ${lets:-none}, but the read only proxy runs as group $egid, so it would be refused too. Start the proxy in the $GROUP group: sudo -n -g $GROUP \"\$(command -v node)\" ~/.claude/skills/bug-bash/read-only-proxy.js --state <run dir>/proxy --egress"
  fi
  # Both halves, for the target's own port. pfctl may print a port by its service name (443 as
  # https), so either spelling counts. UDP matters though the direct connection check below cannot
  # see it: a browser speaking HTTP/3 reaches the site over UDP.
  local proto names ported name found
  for proto in tcp udp; do
    names="$port $(awk -v pp="$port/$proto" '$2 == pp { print $1; exit }' /etc/services 2>/dev/null)"
    ported="$(grep "^rule block return out quick proto $proto from any to <bug_bash_targets> port = " <<< "$rules" | sed -n 's/.* port = \([^ ]*\) .*/\1/p')"
    found=0
    for name in $names; do grep -qxF -- "$name" <<< "$ported" && found=1; done
    [ "$found" = 1 ] || fail "the rule does not refuse $proto to $host on port $port, so a browser could reach it that way."
  done
  for a in $addrs; do
    grep -qx "target $a" <<< "$status" || fail "$host resolves to $a, which the rule does not hold, so a browser could reach the site there."
  done
  # The deciding measurement, from outside the helper: from here, not in the proxy's group, the
  # target cannot be reached at all.
  # shellcheck disable=SC2086
  reached="$(reaches "$port" $addrs)" || fail "the direct connection check could not run, so the rule is not proved."
  [ -z "$reached" ] || fail "a direct connection to $host ($(tr '\n' ' ' <<< "$reached" | sed 's/ $//')) on port $port got through, so the rule is not in force."
  echo "in force: only group $egid reaches $host ($(tr '\n' ' ' <<< "$addrs" | sed 's/ $//')) on port $port"
}

cmd_unload() {
  [ "$#" -le 1 ] || fail "usage: egress.sh unload [<owner pid>]"
  local out
  out="$(helper unload "$@")" || fail "${out#bug-bash-egress: }"
  printf '%s\n' "$out"
}

# What the self test must undo, kept outside the function: its EXIT trap runs after the function has
# returned on a pass, when a local of the function no longer exists.
SELFTEST_LISTENER=""
SELFTEST_DIR=""
selftest_cleanup() {
  helper unload $$ >/dev/null 2>&1
  [ -n "$SELFTEST_LISTENER" ] && kill "$SELFTEST_LISTENER" 2>/dev/null
  [ -n "$SELFTEST_DIR" ] && rm -rf "$SELFTEST_DIR"
}

cmd_selftest() {
  need_node
  local node exempt port got
  node="$(command -v node)"
  exempt="$(sudo -n -g "$GROUP" id -g 2>&1)" \
    || fail "FAIL: sudo would not start a process in the $GROUP group without a password ($exempt). The one time setup has not been done: $SETUP_CMD"
  is_number "$exempt" || fail "FAIL: a process started in the $GROUP group did not report a group id: $exempt"
  [ "$exempt" != "$(id -g)" ] || fail "FAIL: the $GROUP group has your own group's id ($exempt), so the rule could not tell the proxy from anything else."
  SELFTEST_DIR="$(mktemp -d)"
  # Undone however the test ends: the rule taken away, the listener stopped.
  trap selftest_cleanup EXIT
  # Its output goes nowhere, so a listener that outlived the test could not hold its caller's open.
  node -e '
const s = require("net").createServer(c => c.destroy())
s.listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[1], String(s.address().port)))' "$SELFTEST_DIR/port" >/dev/null 2>&1 &
  SELFTEST_LISTENER=$!
  for _ in $(seq 1 100); do [ -s "$SELFTEST_DIR/port" ] && break; sleep 0.05; done
  port="$(cat "$SELFTEST_DIR/port" 2>/dev/null)"
  is_number "$port" || fail "FAIL: the self test's listener on this machine did not start."
  got="$(reaches "$port" 127.0.0.1)"
  [ "$got" = 127.0.0.1 ] || fail "FAIL: the self test's own listener could not be reached before any rule was loaded, so nothing below would mean anything."
  ( cmd_load 127.0.0.1 "$port" "$$" >/dev/null ) || fail "FAIL: the rule could not be loaded."
  echo "loaded: the rule for 127.0.0.1 port $port"
  got="$( (cmd_check 127.0.0.1 "$port" "$exempt") 2>&1)" || fail "FAIL: $got"
  echo "blocked: a direct connection is refused, and the rule reads back as loaded"
  got="$(sudo -n -g "$GROUP" "$node" -e "$PROBE_JS" "$port" "$PROBE_TIMEOUT_MS" 127.0.0.1 2>&1)"
  [ "$got" = 127.0.0.1 ] || fail "FAIL: a connection from the $GROUP group was refused too, so the read only proxy could not reach a site behind the rule ($got)."
  echo "exempt: a connection from the $GROUP group gets through"
  got="$(helper unload "$$")" || fail "FAIL: the rule could not be taken away again: $got. Remove it with: bash ~/.claude/skills/bug-bash/egress.sh unload"
  got="$(reaches "$port" 127.0.0.1)"
  [ "$got" = 127.0.0.1 ] || fail "FAIL: with the rule taken away, a direct connection is still refused."
  echo "removed: with the rule gone, a direct connection gets through again"
  echo "PASS: the bug bash egress rule works on this Mac."
}

case "${1:-}" in
  load) shift; cmd_load "$@" ;;
  check) shift; cmd_check "$@" ;;
  unload) shift; cmd_unload "$@" ;;
  selftest) shift; cmd_selftest "$@" ;;
  *) fail "usage: egress.sh load <host> <port> <owner pid> | check <host> <port> <proxy group id> | unload [<owner pid>] | selftest" ;;
esac
