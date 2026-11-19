#!/usr/bin/env bash
# Tests for no-network-run.sh (claude-config#3173), the wrapper that runs a command with no network
# access at all, which the Slack drafts gate lets through by its installed path.
#
# What is measured, each against a listener this suite opens on this Mac and nowhere else:
#   * a post arrives without the wrapper and does not arrive with it, on loopback and on this Mac's
#     own network address, so the block is seen to fail open before it is seen to hold (L1);
#   * the same for a child process, a child running the system's curl, a detached child that posts
#     only once the command has exited, and a child that starts a permissive sandbox of its own;
#   * a unix domain socket whose listener is outside the sandbox is refused as an address is, and a
#     connection opened BEFORE the wrapper starts and handed down to the command is NOT closed to
#     it, which is asserted as measured so the wrapper's "what it does not cover" stays true;
#   * the command's exit code, its words and its input come through unchanged;
#   * nothing is run when no command is given, when the first word starts with a dash, when the
#     sandbox tool is missing, when the profile cannot be applied, when the sandbox does not block
#     the wrapper's own connection, when that connection does not arrive even outside the sandbox,
#     and when the check gets no answer.
#
# The wrapper has no option and reads no setting, so the cases that need it to meet a broken sandbox
# run a COPY of it with one line changed, and each copy is checked to differ from the wrapper. The
# shipped file is never changed.
#
# The sandbox is macOS's. Anywhere else the parts that need it print SUITE-PART-UNMEASURED and the
# rest still run: there the wrapper must refuse and run nothing, which is measured.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/hang-wait.sh"
WRAP="$DIR/no-network-run.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$WRAP" ]; then
  echo "FAIL: there is no no-network-run.sh beside this suite at $DIR, so nothing runs with the network taken away."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/no-network-run.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
LISTENER=""
UNIX_LISTENER=""
cleanup() {
  if [ -n "$LISTENER" ]; then kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null; fi
  if [ -n "$UNIX_LISTENER" ]; then kill "$UNIX_LISTENER" 2>/dev/null; wait "$UNIX_LISTENER" 2>/dev/null; fi
  rm -rf "$T"
}
trap cleanup EXIT

RC=0; OUT=""; ERR=""
# run <program> [words]: OUT, ERR and RC of one run, its input empty.
run() {
  OUT="$("$@" 2>"$T/err.txt" </dev/null)"; RC=$?
  ERR="$(cat "$T/err.txt")"
}
exits() { if [ "$RC" -eq "$2" ]; then check "$1" ok; else check "$1" "exit $RC, wanted $2, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
ran() { if [ -e "$T/ran.$2" ]; then check "$1" ok; else check "$1" "the command was not run"; fi; }
not_ran() { if [ -e "$T/ran.$2" ]; then check "$1" "the command WAS run"; else check "$1" ok; fi; }

# changed <name> <sed expression>: a copy of the wrapper at $T/<name>.sh with one line changed, and
# a check that the change landed (L100: a pattern matching nothing leaves the wrapper itself).
changed() {
  sed "$2" "$WRAP" > "$T/$1.sh"
  chmod +x "$T/$1.sh"
  if cmp -s "$WRAP" "$T/$1.sh"; then check "the changed copy $1 differs from the wrapper" "the change matched no line"
  else check "the changed copy $1 differs from the wrapper" ok; fi
}

echo "no network run: what it refuses before anything is run"

run "$WRAP"
exits "no command given is refused" 64
says "no command given says so" "no command was given"

run "$WRAP" --local /usr/bin/touch "$T/ran.option"
exits "a first word starting with a dash is refused" 64
says "a first word starting with a dash says it takes no option" "takes no option"
not_ran "a first word starting with a dash runs nothing" option

run "$WRAP" -- /usr/bin/touch "$T/ran.dashes"
exits "a bare -- is refused like any other option" 64
not_ran "a bare -- runs nothing" dashes

changed missing 's|^SANDBOX=.*|SANDBOX=/nonexistent-3173/sandbox-exec|'
run "$T/missing.sh" /usr/bin/touch "$T/ran.missing"
exits "a missing sandbox tool is refused" 69
says "a missing sandbox tool is named" "/nonexistent-3173/sandbox-exec"
says "a missing sandbox tool says nothing was run" "Nothing was run"
not_ran "a missing sandbox tool runs nothing" missing

if [ ! -x /usr/bin/sandbox-exec ]; then
  run "$WRAP" /usr/bin/touch "$T/ran.here"
  exits "where there is no sandbox tool the wrapper itself refuses" 69
  not_ran "where there is no sandbox tool the wrapper itself runs nothing" here
  echo "SUITE-PART-UNMEASURED the network being taken away, the sandbox being proved on each run and the command's exit code coming through: /usr/bin/sandbox-exec is macOS's, and this is $(uname -s)"
  echo
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

# The python3 that makes the wrapper's check is one file at a fixed path, the command line
# developer tools' own, which only an administrator can write. One found on the PATH would run
# outside the sandbox at the start of every run, and a command run under the wrapper can write a
# file named python3 into a PATH folder of the user's (the review of 2026-11-19).
PY_FIXED=/Library/Developer/CommandLineTools/usr/bin/python3
if grep -q "^PYTHON=$PY_FIXED\$" "$WRAP"; then check "the wrapper names its python3 by one fixed path" ok
else check "the wrapper names its python3 by one fixed path" "no line PYTHON=$PY_FIXED in $WRAP"; fi

changed nopython 's|^PYTHON=.*|PYTHON=/nonexistent-3173/python3|'
run "$T/nopython.sh" /usr/bin/touch "$T/ran.nopython"
exits "a missing python3 at the fixed path is refused" 69
says "a missing python3 is named by its path" "/nonexistent-3173/python3"
says "a missing python3 says nothing was run" "Nothing was run"
not_ran "a missing python3 runs nothing" nopython

if [ ! -x "$PY_FIXED" ]; then
  run "$WRAP" /usr/bin/touch "$T/ran.notools"
  exits "where the command line tools' python3 is not there the wrapper itself refuses" 69
  not_ran "where the command line tools' python3 is not there the wrapper itself runs nothing" notools
  echo "SUITE-PART-UNMEASURED the network being taken away, the sandbox being proved on each run and the command's exit code coming through: $PY_FIXED, which makes the wrapper's check, is not on this machine"
  echo
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "SUITE-PART-UNMEASURED whether this user can write the wrapper's python3: the suite is running as root, which can write any file"
elif [ -w "$PY_FIXED" ] || [ -w "$(dirname "$PY_FIXED")" ]; then
  check "the wrapper's python3 and its folder are not this user's to write" "$PY_FIXED or its folder is writable by $(id -un)"
else
  check "the wrapper's python3 and its folder are not this user's to write" ok
fi

echo "no network run: the command runs, and what it is given comes through"

run "$WRAP" /usr/bin/touch "$T/ran.plain"
exits "a plain command runs and exits 0" 0
ran "a plain command is run" plain
says "a run says the network is off" "no network access"

run "$WRAP" /bin/sh -c 'exit 37'
exits "a failing command's exit code comes through unchanged" 37

run "$WRAP" /bin/sh -c 'kill -TERM $$'
exits "a command ended by a signal reports that signal's code" 143

run "$WRAP" /usr/bin/printf '%s|' "two words" "" 'a"b' "-n"
exits "words with a space, an empty word and a quote are handed over" 0
if [ "$OUT" = 'two words||a"b|-n|' ]; then check "each word arrives as it was written" ok
else check "each word arrives as it was written" "got: $OUT"; fi

OUT="$(printf 'line one\nline two\n' | "$WRAP" /bin/cat 2>/dev/null)"
if [ "$OUT" = "$(printf 'line one\nline two')" ]; then check "the command reads the wrapper's own input" ok
else check "the command reads the wrapper's own input" "got: $OUT"; fi

# A file bash would source at start (BASH_ENV) is not read: it would run before the wrapper's first
# line and outside the sandbox.
printf '%s\n' "/usr/bin/touch '$T/ran.bashenv'" > "$T/env.sh"
BASH_ENV="$T/env.sh" run "$WRAP" /usr/bin/true
exits "a run with BASH_ENV set still runs" 0
not_ran "a BASH_ENV file is not sourced by the wrapper" bashenv

# A python3 that stands first on the PATH is not the one the wrapper runs: the stand in records
# that it was started and then hands on to the real one, so the run would pass either way and only
# the record shows which was used.
REAL_PYTHON="$(command -v python3)"
mkdir -p "$T/fakebin"
printf '%s\n' '#!/bin/sh' "/usr/bin/touch '$T/ran.fakepython'" "exec '$REAL_PYTHON' \"\$@\"" > "$T/fakebin/python3"
chmod +x "$T/fakebin/python3"
PATH="$T/fakebin:$PATH" run "$WRAP" /usr/bin/touch "$T/ran.pathpython"
exits "with another python3 first on the PATH the command still runs" 0
ran "with another python3 first on the PATH the command is run" pathpython
not_ran "a python3 that stands first on the PATH is not started by the wrapper" fakepython
if [ "$(PATH="$T/fakebin:$PATH" command -v python3)" = "$T/fakebin/python3" ]; then check "and that stand in is the python3 the PATH finds first" ok
else check "and that stand in is the python3 the PATH finds first" "the PATH found $(PATH="$T/fakebin:$PATH" command -v python3)"; fi

echo "no network run: a post arrives without it and not with it"

cat > "$T/listen.py" <<'PY'
"""listen.py <port file> <log> [address]: answers every POST on loopback, on a port the system
picks, and on this Mac's own network address too when one is given, and writes one line for each:
its body, then the address it arrived at. The port file gets the loopback port, then the other
address's port on a second line. It never listens on every address at once."""
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer

PORT_FILE = sys.argv[1]
LOG = sys.argv[2]
WRITING = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(size).decode("utf-8", "replace")
        with WRITING:
            with open(LOG, "a", encoding="utf-8", errors="replace") as log:
                log.write(body + " via " + self.request.getsockname()[0] + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler)]
if len(sys.argv) > 3:
    servers.append(ThreadingHTTPServer((sys.argv[3], 0), Handler))
with open(PORT_FILE + ".tmp", "w", encoding="utf-8", errors="replace") as f:
    for server in servers:
        f.write(str(server.server_address[1]) + "\n")
os.rename(PORT_FILE + ".tmp", PORT_FILE)
for server in servers[1:]:
    threading.Thread(target=server.serve_forever, daemon=True).start()
servers[0].serve_forever()
PY

cat > "$T/post.py" <<'PY'
"""post.py <how> <host> <port> <label> <result file>: one POST of the label to the listener, made
the way <how> says, and its outcome written to the result file: "sent", or "failed: " and why."""
import http.client
import os
import select
import socket
import subprocess
import sys

HOW = sys.argv[1]
HOST = sys.argv[2]
PORT = sys.argv[3]
LABEL = sys.argv[4]
RESULT = sys.argv[5]


def post():
    try:
        conn = http.client.HTTPConnection(HOST, int(PORT), timeout=10)
        conn.request("POST", "/hook", body=LABEL.encode("utf-8"))
        conn.getresponse().read()
        return "sent"
    except Exception as e:
        return "failed: " + type(e).__name__ + ": " + str(e)


def write(outcome):
    with open(RESULT + ".tmp", "w", encoding="utf-8", errors="replace") as f:
        f.write(outcome + "\n")
    os.rename(RESULT + ".tmp", RESULT)


def again(how):
    return [sys.executable, os.path.abspath(__file__), how, HOST, PORT, LABEL, RESULT]


if HOW == "direct":
    write(post())
elif HOW == "child":
    subprocess.run(again("direct"), stdin=subprocess.DEVNULL)
elif HOW == "curl":
    done = subprocess.run(["/usr/bin/curl", "-s", "-m", "10", "--noproxy", "*", "-X", "POST", "-d", LABEL,
                           "http://" + HOST + ":" + PORT + "/hook"],
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    write("sent" if done.returncode == 0 else "failed: curl ended " + str(done.returncode))
elif HOW == "detached":
    # The child is in a session of its own and waits on a pipe only this process holds open, so
    # it posts once this process, the command, has exited.
    subprocess.Popen(again("after-parent"), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
elif HOW == "after-parent":
    sys.stdin.buffer.read()
    write(post())
elif HOW == "own-sandbox":
    done = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)"] + again("direct"),
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(RESULT):
        write("failed: the child's own sandbox ended " + str(done.returncode) + " and ran nothing")
elif HOW == "unix":
    # HOST is the path of a unix domain socket here, whose listener is outside the sandbox.
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(HOST)
        s.sendall(LABEL.encode("utf-8"))
        s.shutdown(socket.SHUT_WR)
        s.recv(16)
        write("sent")
    except Exception as e:
        write("failed: " + type(e).__name__ + ": " + str(e))
elif HOW == "held":
    # A connection made before this process started and handed down to it on descriptor 7
    # (hold.py): nothing is connected here, the request is only written to what is already open.
    body = LABEL.encode("utf-8")
    try:
        os.write(7, b"POST /hook HTTP/1.1\r\nHost: held\r\nContent-Length: " + str(len(body)).encode("ascii")
                 + b"\r\nConnection: close\r\n\r\n" + body)
        ready = select.select([7], [], [], 10)[0]
        answer = os.read(7, 64) if ready else b""
        write("sent" if answer.startswith(b"HTTP/") else "failed: no answer on the held connection")
    except OSError as e:
        write("failed: " + type(e).__name__ + ": " + str(e))
else:
    sys.exit("post.py: unknown way " + HOW)
PY

# This Mac's own network address, read from the route a packet would take with none sent: the
# address stands in for a host that is not this Mac. 192.0.2.1 is reserved for documentation.
LAN="$(python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("192.0.2.1", 9))
    print(s.getsockname()[0])
except OSError:
    pass
')"
case "$LAN" in ''|127.*) LAN=""; NO_LAN="this Mac has no address but loopback now" ;; esac
# A listener on that address raises the macOS firewall's dialog where the firewall is on, on every
# run of this suite, so it is opened only where the firewall is read as off (L411).
if [ -n "$LAN" ]; then
  FIREWALL="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)"
  case "$FIREWALL" in
    *"State = 0"*) ;;
    *) LAN=""; NO_LAN="the macOS firewall is on or could not be read, and a listener on that address would raise its dialog" ;;
  esac
fi

: > "$T/arrivals.log"
if [ -n "$LAN" ]; then
  python3 "$T/listen.py" "$T/port" "$T/arrivals.log" "$LAN" >/dev/null 2>&1 &
  LISTENER=$!
else
  python3 "$T/listen.py" "$T/port" "$T/arrivals.log" >/dev/null 2>&1 &
  LISTENER=$!
fi
if hang_wait '[ -s "$T/port" ]'; then check "the suite's own listener is up" ok
else check "the suite's own listener is up" "no port was written within $HANG_S seconds"; fi
PORT="$(sed -n 1p "$T/port" 2>/dev/null)"
LAN_PORT="$(sed -n 2p "$T/port" 2>/dev/null)"

arrived() { grep -c "^$1 via " "$T/arrivals.log" || true; }
# one <how> <host> <label> <front...>: one post made the way <how> says, with <front> before it,
# waited for until its outcome is written.
one() {
  local how="$1" host="$2" label="$3" port="$PORT"
  shift 3
  if [ "$host" != 127.0.0.1 ]; then port="$LAN_PORT"; fi
  RESULT="$T/result.$label"
  "$@" python3 "$T/post.py" "$how" "$host" "$port" "$label" "$RESULT" >/dev/null 2>"$T/err.txt" </dev/null
  RC=$?
  # Only a detached child writes its outcome after the command returns, and only when the command
  # started it, so nothing else is waited for: a wrapper that cannot run must fail the case, not
  # hold the suite at each wait's ceiling.
  if [ "$how" = detached ] && [ "$RC" -eq 0 ] && ! hang_wait '[ -e "$RESULT" ]'; then
    echo "failed: no outcome was written within $HANG_S seconds" > "$RESULT"
  fi
  if [ ! -e "$RESULT" ]; then echo "no outcome: the command ended $RC and wrote none: $(head -c 300 "$T/err.txt")" > "$RESULT"; fi
  OUTCOME="$(cat "$RESULT")"
}
# both <how> <host> <name>: the post without the wrapper, which must arrive, then with it, which
# must not.
both() {
  local how="$1" host="$2" name="$3"
  one "$how" "$host" "open-$name"
  if [ "$OUTCOME" = "sent" ] && [ "$(arrived "open-$name")" = "1" ]; then check "$name: without the wrapper the post arrives" ok
  else check "$name: without the wrapper the post arrives" "outcome '$OUTCOME', arrived $(arrived "open-$name")"; fi
  one "$how" "$host" "shut-$name" "$WRAP"
  case "$OUTCOME" in
    failed:*) check "$name: with the wrapper the post fails" ok ;;
    *) check "$name: with the wrapper the post fails" "outcome '$OUTCOME'" ;;
  esac
  if [ "$(arrived "shut-$name")" = "0" ]; then check "$name: with the wrapper nothing arrives" ok
  else check "$name: with the wrapper nothing arrives" "arrived $(arrived "shut-$name")"; fi
}

if [ -n "$PORT" ]; then
  both direct 127.0.0.1 loopback
  case "$OUTCOME" in *"not permitted"*) check "the blocked post fails with the permission error the wrapper names" ok ;;
    *) check "the blocked post fails with the permission error the wrapper names" "outcome '$OUTCOME'" ;; esac
  both child 127.0.0.1 child
  both curl 127.0.0.1 curl
  both detached 127.0.0.1 detached
  both own-sandbox 127.0.0.1 own-sandbox
  if [ -n "$LAN" ] && [ -n "$LAN_PORT" ]; then
    both direct "$LAN" network-address
    both detached "$LAN" network-address-detached
  else
    echo "SUITE-PART-UNMEASURED a post to this Mac's own network address: ${NO_LAN:-the listener gave no port on it}, so only loopback was measured"
  fi
fi

echo "no network run: a hand off that is not a new connection to an address"

# A unix domain socket whose listener is outside the sandbox (the design on #3173 listed this hand
# off as not measured). macOS takes a socket path of at most 103 bytes.
cat > "$T/unix-listen.py" <<'PY'
"""unix-listen.py <socket path> <log>: takes each connection to a unix domain socket, reads what it
is sent to the end, and writes one line for it: the text, then "via unix"."""
import os
import socket
import sys

PATH = sys.argv[1]
LOG = sys.argv[2]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(PATH + ".tmp")
server.listen(8)
os.rename(PATH + ".tmp", PATH)
while True:
    conn, _ = server.accept()
    conn.settimeout(10)
    data = b""
    try:
        while True:
            more = conn.recv(4096)
            if not more:
                break
            data += more
    except OSError:
        pass
    # The line is written before the answer, so the sender never hears "ok" ahead of the record.
    with open(LOG, "a", encoding="utf-8", errors="replace") as log:
        log.write(data.decode("utf-8", "replace") + " via unix\n")
    try:
        conn.sendall(b"ok")
    except OSError:
        pass
    conn.close()
PY
UNIX="$T/u.s"
if [ "${#UNIX}" -gt 98 ]; then
  echo "SUITE-PART-UNMEASURED a unix domain socket whose listener is outside the sandbox: the throwaway folder's path is ${#T} bytes long, and a socket path under it would pass the 103 macOS takes"
else
  python3 "$T/unix-listen.py" "$UNIX" "$T/arrivals.log" >/dev/null 2>&1 &
  UNIX_LISTENER=$!
  if hang_wait '[ -S "$UNIX" ]'; then
    check "the suite's own unix socket listener is up" ok
    both unix "$UNIX" unix-socket
  else
    check "the suite's own unix socket listener is up" "no socket was there within $HANG_S seconds"
  fi
fi

# A connection made BEFORE the wrapper starts, by a program outside the sandbox, and handed down to
# the command on a descriptor: the command connects nothing, it writes to what is already open.
cat > "$T/hold.py" <<'PY'
"""hold.py <host> <port> <command> [its words]: makes one connection to the listener, puts it on
descriptor 7, and becomes the command, which inherits it."""
import os
import socket
import sys

s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=10)
s.settimeout(None)
os.dup2(s.fileno(), 7)
os.execvp(sys.argv[3], sys.argv[3:])
PY
if [ -n "$PORT" ]; then
  one held 127.0.0.1 open-held python3 "$T/hold.py" 127.0.0.1 "$PORT"
  if [ "$OUTCOME" = "sent" ] && [ "$(arrived open-held)" = "1" ]; then check "held: without the wrapper the post on a connection already open arrives" ok
  else check "held: without the wrapper the post on a connection already open arrives" "outcome '$OUTCOME', arrived $(arrived open-held)"; fi
  # MEASURED NOT COVERED (2026-11-19, macOS 26.6.2: outcome sent, arrived 1). The sandbox refuses
  # a new connection and does not stop a write to one already open, so this holds the wrapper's
  # "what it does not cover" to what the sandbox does: the case fails on the day that changes,
  # either way. The gate's rule is what keeps a call from opening one first: nothing but a cd may
  # stand before the wrapper, and none of its words may name /dev/tcp or /dev/udp
  # (test-slack-drafts-no-network-route.sh).
  one held 127.0.0.1 shut-held python3 "$T/hold.py" 127.0.0.1 "$PORT" "$WRAP"
  if [ "$OUTCOME" = "sent" ] && [ "$(arrived shut-held)" = "1" ]; then check "held: NOT COVERED, with the wrapper a post on a connection opened before it still arrives" ok
  else check "held: NOT COVERED, with the wrapper a post on a connection opened before it still arrives" "outcome '$OUTCOME', arrived $(arrived shut-held): the sandbox no longer behaves as no-network-run.sh and the README say, so bring both up to date"; fi
fi

echo "no network run: the sandbox is proved on every run, and a run that cannot prove it runs nothing"

changed unapplied "s|^PROFILE=.*|PROFILE='(version 1)(allow default'|"
run "$T/unapplied.sh" /usr/bin/touch "$T/ran.unapplied"
exits "a profile that cannot be applied is refused" 70
says "a profile that cannot be applied says the check was not made" "could not be checked"
not_ran "a profile that cannot be applied runs nothing" unapplied

changed open "s|^PROFILE=.*|PROFILE='(version 1)(allow default)'|"
run "$T/open.sh" /usr/bin/touch "$T/ran.open"
exits "a sandbox that does not block the wrapper's own connection is refused" 70
says "a sandbox that does not block says so" "did NOT block"
not_ran "a sandbox that does not block runs nothing" open

changed deaf 's|^listener\.listen(.*|pass|'
run "$T/deaf.sh" /usr/bin/touch "$T/ran.deaf"
exits "a connection that does not arrive even outside the sandbox is refused" 70
says "a control that fails says a block would prove nothing" "would prove nothing"
not_ran "a control that fails runs nothing" deaf

# A sandbox tool that never answers: the check gives up at its limit, shortened here on the copy,
# and nothing is run. The stand in is ended by the check itself.
printf '%s\n' '#!/bin/sh' 'exec /bin/sleep 600' > "$T/silent-tool"
chmod +x "$T/silent-tool"
sed -e "s|^SANDBOX=.*|SANDBOX=$T/silent-tool|" -e 's|^PROBE_SECONDS=.*|PROBE_SECONDS=1|' "$WRAP" > "$T/silent.sh"
chmod +x "$T/silent.sh"
if grep -q "^SANDBOX=$T/silent-tool" "$T/silent.sh" && grep -q '^PROBE_SECONDS=1$' "$T/silent.sh"; then check "the changed copy silent differs from the wrapper" ok
else check "the changed copy silent differs from the wrapper" "a change matched no line"; fi
run "$T/silent.sh" /usr/bin/touch "$T/ran.silent"
exits "a check that gets no answer is refused" 70
not_ran "a check that gets no answer runs nothing" silent

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
