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
#   * a hand off to something outside the sandbox (claude-config#3288): open, osascript, launchctl
#     and whatever else the wrapper lists each start without the wrapper and are refused with it,
#     by their own path and through a link; the requests behind them (to have something opened, to
#     send an Apple event, to have launchd make a job) are allowed without it and denied with it,
#     by asking the sandbox and making none of them; and a copy of open signed again on this Mac
#     still starts, and a service is still found by its name, each asserted as measured so the
#     wrapper's "what it does not cover" stays true. Every start here is the program with --help,
#     which prints its usage and ends, so nothing is opened, scripted, loaded or scheduled;
#   * ps, the one program the wrapper starts outside the sandbox (claude-config#3482): it runs
#     with the wrapper, by its path and through a link, where macOS refuses every setuid program
#     without the rule; the command that ran it is still refused the network and the three hand
#     offs; another program named ps stays in the sandbox; every other setuid program found on
#     disk is still refused; a program the command starts after ps is still refused the network; a
#     socket handed to ps as its output carries nothing out; a library the caller names is loaded
#     into a program compiled here and not into ps, started plainly, traced or paused; the task
#     port of a ps held traced or paused is refused where that of a program signed here to allow
#     it is given; what ps shows of another process (this user's environment, which the kernel
#     already gave without ps, and another user's arguments, which it did not) is asserted as
#     measured; and a copy of the wrapper without the rule still refuses ps;
#   * one program and never a list (the review of 2026-11-24): every profile the wrapper hands the
#     sandbox tool, read from a stand in for that tool, is the one this suite holds whole; and
#     twelve ways of writing a second program into the profile, each in a copy of the wrapper, are
#     each refused by the wrapper's own check of its profile with nothing handed to the sandbox
#     tool and nothing arriving, and, with that check taken out of the copy, each lets curl's post
#     arrive (which is what the rule does to a program it names) and each is caught by this suite;
#   * nothing is run when no command is given, when the first word starts with a dash, when the
#     sandbox tool is missing, when the profile cannot be applied, when the sandbox does not block
#     the wrapper's own connection, when that connection does not arrive even outside the sandbox,
#     when the check gets no answer, when the sandbox does not refuse to start a listed program,
#     and when a listed program does not start even outside the sandbox.
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

echo "no network run: a hand off to a program outside the sandbox is refused (claude-config#3288)"

# Every start below is one that prints and ends: --help makes each of these programs print its
# usage, and nothing is opened, scripted, loaded or scheduled, whether the start is refused or not.
cat > "$T/start.py" <<'PY'
"""start.py <program>: tries to start the program with --help. Prints started, refused (the
permission error the sandbox gives), absent, or the error it met."""
import errno
import subprocess
import sys

try:
    subprocess.run([sys.argv[1], "--help"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=20)
except FileNotFoundError:
    print("absent")
except subprocess.TimeoutExpired:
    print("no answer")
except OSError as e:
    print("refused" if e.errno == errno.EPERM else "error: %s" % e)
else:
    print("started")
PY
# What the sandbox this process is in answers for one operation, with nothing started. It is the
# question the system's own daemons put about a caller before they act for it.
cat > "$T/ask.py" <<'PY'
"""ask.py <operation> <none|global-name|appleevent> [value]: prints allowed or denied."""
import ctypes
import os
import sys

KIND = {"none": 0, "global-name": 2, "appleevent": 4}[sys.argv[2]]
NO_REPORT = 0x40000000
lib = ctypes.CDLL("/usr/lib/system/libsystem_sandbox.dylib")
lib.sandbox_check.restype = ctypes.c_int
lib.sandbox_check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
if KIND:
    rc = lib.sandbox_check(os.getpid(), sys.argv[1].encode(), KIND | NO_REPORT, ctypes.c_char_p(sys.argv[3].encode()))
else:
    rc = lib.sandbox_check(os.getpid(), sys.argv[1].encode(), NO_REPORT)
print({0: "allowed", 1: "denied"}.get(rc, "answer %d" % rc))
PY

# The three the issue names are this suite's own list, and whatever else the wrapper lists is
# measured with them, so a program added there cannot go unmeasured here (L96).
LISTED="$(sed -n "s/^HANDOFFS='\(.*\)'\$/\1/p" "$WRAP")"
if [ -n "$LISTED" ]; then check "the wrapper lists the programs it refuses to start" ok
else check "the wrapper lists the programs it refuses to start" "no line HANDOFFS='...' in $WRAP"; fi
PROGRAMS="/usr/bin/open /usr/bin/osascript /bin/launchctl"
for prog in $LISTED; do
  case " $PROGRAMS " in *" $prog "*) ;; *) PROGRAMS="$PROGRAMS $prog" ;; esac
done
for prog in /usr/bin/open /usr/bin/osascript /bin/launchctl; do
  case " $LISTED " in *" $prog "*) check "the wrapper's list names $prog" ok ;; *) check "the wrapper's list names $prog" "its list is '$LISTED'" ;; esac
done
for prog in $PROGRAMS; do
  run "$PY_FIXED" -I "$T/start.py" "$prog"
  if [ "$OUT" = "absent" ]; then
    echo "SUITE-PART-UNMEASURED $prog being refused under the wrapper: it is not on this machine"
    continue
  fi
  if [ "$OUT" != "started" ]; then
    check "without the wrapper $prog starts" "it said '$OUT', so its being refused under the wrapper would prove nothing"
    continue
  fi
  check "without the wrapper $prog starts" ok
  run "$WRAP" "$PY_FIXED" -I "$T/start.py" "$prog"
  if [ "$OUT" = "refused" ]; then check "with the wrapper $prog is refused" ok
  else check "with the wrapper $prog is refused" "it said '$OUT'"; fi
done

# As the wrapper's own command: the sandbox tool cannot start it, and says so with its own code.
# The words looked for are the sandbox tool's, not "Operation not permitted" alone, which the
# wrapper's own line about the network says on every run.
run "$WRAP" /usr/bin/open --help
exits "open as the wrapper's command is not started" 71
says "open as the wrapper's command says the sandbox tool could not start it" "execvp() of '/usr/bin/open' failed: Operation not permitted"

# By another path. A link is read through to the file it names, so it is refused as the file is.
ln -s /usr/bin/open "$T/open-link"
run "$PY_FIXED" -I "$T/start.py" "$T/open-link"
if [ "$OUT" = "started" ]; then
  check "without the wrapper a link to open starts it" ok
  run "$WRAP" "$PY_FIXED" -I "$T/start.py" "$T/open-link"
  if [ "$OUT" = "refused" ]; then check "with the wrapper a link to open is refused" ok
  else check "with the wrapper a link to open is refused" "it said '$OUT'"; fi
else
  check "without the wrapper a link to open starts it" "it said '$OUT'"
fi

# MEASURED NOT COVERED (2026-11-20, macOS 26.6.2). A plain copy of one of these programs is ended
# by macOS itself, with or without the wrapper (a launch constraint: the crash record says so),
# which is not run here because each try leaves a crash record in the user's own Library. A copy
# signed again on this Mac is no longer Apple's program, starts, and is not refused by its path.
# What then stands in its way is the rules on the requests themselves, asked below. This holds the
# wrapper's "what it does not cover" to what the sandbox does: it fails on the day that changes.
if [ -x /usr/bin/codesign ] && cp /usr/bin/open "$T/open-copy" && /usr/bin/codesign -f -s - "$T/open-copy" >/dev/null 2>&1; then
  run "$PY_FIXED" -I "$T/start.py" "$T/open-copy"
  if [ "$OUT" = "started" ]; then
    run "$WRAP" "$PY_FIXED" -I "$T/start.py" "$T/open-copy"
    if [ "$OUT" = "started" ]; then check "copy: NOT COVERED, a copy of open signed again on this Mac still starts under the wrapper" ok
    else check "copy: NOT COVERED, a copy of open signed again on this Mac still starts under the wrapper" "it said '$OUT': the sandbox no longer behaves as no-network-run.sh and the README say, so bring both up to date"; fi
  else
    echo "SUITE-PART-UNMEASURED whether a copy of open signed again on this Mac starts under the wrapper: outside it the copy said '$OUT'"
  fi
else
  echo "SUITE-PART-UNMEASURED whether a copy of open signed again on this Mac starts under the wrapper: it could not be copied and signed here"
fi

# The requests themselves, whoever makes them. Outside the wrapper each must be allowed, or its
# being denied inside would prove nothing.
# asked <what> <wanted under the wrapper> <operation> <kind> [value]
asked() {
  local what="$1" want="$2"
  shift 2
  run "$PY_FIXED" -I "$T/ask.py" "$@"
  if [ "$OUT" != "allowed" ]; then
    check "without the wrapper $what is allowed" "the sandbox answered '$OUT' ${ERR:0:200}"
    return
  fi
  check "without the wrapper $what is allowed" ok
  run "$WRAP" "$PY_FIXED" -I "$T/ask.py" "$@"
  if [ "$OUT" = "$want" ]; then check "with the wrapper $what is $want" ok
  else check "with the wrapper $what is $want" "the sandbox answered '$OUT' ${ERR:0:200}"; fi
}
asked "a request to have something opened (what open asks)" denied lsopen none
asked "an Apple event to another app (what osascript sends)" denied appleevent-send appleevent com.apple.finder
# ALREADY SO before #3288 (measured 2026-11-20, macOS 26.6.2: denied under the profile that named
# the network alone), so this case was never seen to fail. The rule is written out so that the
# profile does not lean on a default, and the case holds it there.
asked "a request to launchd to make a job (what launchctl asks)" denied job-creation none
# MEASURED NOT COVERED (2026-11-20). Finding a service by its name is still allowed, the clipboard's
# here: denying every such lookup also broke looking up a user's name, watching a folder and
# reading a preference in the same measurement, so it was left for Dan to decide (README).
asked "finding a service by name: NOT COVERED, and so it" allowed mach-lookup global-name com.apple.pasteboard.1

echo "no network run: ps, the one program that leaves the sandbox (claude-config#3482)"

# macOS refuses to start a setuid program from inside ANY sandbox (the kernel's log line is
# "deny(1) forbidden-exec-sugid", measured 2026-11-24 on macOS 26.6.2 under a profile that names
# the network alone), and /bin/ps is one. So every ps under the wrapper ended "Operation not
# permitted", and four suites that read a process through it could not pass there. A profile has
# one form that lets such a program start, and that form starts it OUTSIDE the sandbox. What that
# lets a wrapped command do, and what it does not, is measured below; nothing ps or the kernel
# returns about another process is printed, only whether a marker this suite planted was in it.
PS_PROG=/bin/ps
# after_ps <words>: under sh, ps first, then the words in its place. A ps that does not run ends
# the command with 99 and the words are never started, so a case about what follows a ps cannot
# pass where ps was refused.
AFTER_PS='/bin/ps -o pid= -p "$$" >/dev/null 2>&1 || { echo "ps did not run"; exit 99; }; exec "$@"'

OUTSIDE="$(sed -n "s/^OUTSIDE='\(.*\)'\$/\1/p" "$WRAP")"
if [ "$OUTSIDE" = "$PS_PROG" ]; then check "the wrapper lets one program leave the sandbox, and it is $PS_PROG" ok
else check "the wrapper lets one program leave the sandbox, and it is $PS_PROG" "its line OUTSIDE='...' holds '$OUTSIDE'"; fi

# ONE PROGRAM, NEVER A LIST (the review of 2026-11-24). The profile, whole, as the wrapper hands it
# to the sandbox tool, held here in this suite's own words and read from nowhere (L345).
HELD_PROFILE='(version 1)(allow default)(deny network*)(deny process-exec* (literal "/usr/bin/open") (literal "/usr/bin/osascript") (literal "/bin/launchctl") (literal "/usr/bin/crontab") (literal "/usr/bin/shortcuts"))(deny lsopen)(deny appleevent-send)(deny job-creation)(allow process-exec (literal "/bin/ps") (with no-sandbox))'
HELD_LINE="$(printf '%s\t%s' -p "$HELD_PROFILE")"
# What the wrapper says when its own profile lets more out, and when it holds what is no refusal.
MORE_OUT="lets more than /bin/ps out of the sandbox"
NOT_A_DENY="holds something other than"


# suite_holds <what a copy handed the sandbox tool>: HOLDS is ok when the copy handed a profile
# over at least once and every profile it handed over is the one held above, whole; otherwise it
# says what was handed. It reads what REACHED the sandbox tool and not the lines of the file, so
# it does not matter how a second rule was written or where: the check it replaces counted the
# lines saying 'with no-sandbox', and passed eleven of the twelve spellings below (the red run of
# 2026-11-24, 59 failures).
suite_holds() {
  local all other
  all="$(grep -c '' "$1" 2>/dev/null || true)"
  other="$(grep -c -v -x -F -e "$HELD_LINE" "$1" 2>/dev/null || true)"
  if [ "${all:-0}" -lt 1 ]; then HOLDS="it handed the sandbox tool nothing"
  elif [ "$other" != "0" ]; then HOLDS="$other of its $all hand overs to the sandbox tool were not '-p' and the profile held in this suite"
  else HOLDS=ok; fi
}
# occurs <text> <word>: how many times the word is in the text.
occurs() {
  local left="$1" n=0
  while [ "$left" != "${left#*"$2"}" ]; do left="${left#*"$2"}"; n=$((n + 1)); done
  echo "$n"
}

# spelled <name> <kept|out> [sed expression ...]: a copy of the wrapper at $T/<name>.sh with the
# expressions applied. Its sandbox tool is a stand in that writes down the first two words it is
# handed, one line a hand over in $T/<name>.handed, and then is the real tool. With "out" the
# wrapper's own check of its profile is taken out of the copy. Each change is checked to have
# landed (L100).
spelled() {
  local name="$1" guard="$2" e
  local -a base own
  shift 2
  printf '%s\n' '#!/bin/sh' "printf '%s\\t%s\\n' \"\$1\" \"\$2\" >> '$T/$name.handed'" 'exec /usr/bin/sandbox-exec "$@"' > "$T/$name.tool"
  chmod +x "$T/$name.tool"
  : > "$T/$name.handed"
  base=(-e "s|^SANDBOX=.*|SANDBOX=$T/$name.tool|")
  if [ "$guard" = out ]; then base+=(-e '/^ONE_OUT=/,/^readonly PROFILE$/d'); fi
  own=("${base[@]}")
  for e in "$@"; do own+=(-e "$e"); done
  sed "${base[@]}" "$WRAP" > "$T/$name.base"
  sed "${own[@]}" "$WRAP" > "$T/$name.sh"
  chmod +x "$T/$name.sh"
  if ! grep -q "^SANDBOX=$T/$name.tool\$" "$T/$name.sh"; then check "the copy $name holds its changes" "its sandbox tool was not replaced by the one that writes down what it is handed"
  elif [ "$#" -gt 0 ] && cmp -s "$T/$name.base" "$T/$name.sh"; then check "the copy $name holds its changes" "the change matched no line"
  elif [ "$guard" = out ] && grep -q -e '^ONE_OUT=' -e '^readonly PROFILE' "$T/$name.sh"; then check "the copy $name holds its changes" "the wrapper's own check of its profile was not taken out"
  else check "the copy $name holds its changes" ok; fi
}

# spelling <name> <refused|unchanged> <the wrapper's words> <what it is> <sed expression>...: one
# way of writing a second program into the profile, measured twice with curl's post to this suite's
# listener. With the wrapper's own check taken out, the post must ARRIVE (so the spelling is a real
# way out and the two refusals below are of something, L1) and this suite's check alone must catch
# it. With the wrapper as it ships plus the spelling, the wrapper must refuse and hand the sandbox
# tool nothing, or (unchanged) the write to its profile must fail and every profile handed over be
# the one held here; and nothing may arrive.
spelling() {
  local name="$1" kept="$2" words="$3" what="$4" other
  shift 4
  spelled "$name-out" out "$@"
  one curl 127.0.0.1 "$name-out" "$T/$name-out.sh"
  if [ "$OUTCOME" = "sent" ] && [ "$(arrived "$name-out")" = "1" ]; then check "$what, with the wrapper's own check taken out: curl's post ARRIVES" ok
  else check "$what, with the wrapper's own check taken out: curl's post ARRIVES" "outcome '$OUTCOME', arrived $(arrived "$name-out"), stderr: $(head -c 300 "$T/err.txt")"; fi
  suite_holds "$T/$name-out.handed"
  if [ "$HOLDS" = ok ]; then check "$what, with the wrapper's own check taken out: this suite's check catches it" "this suite's check passed it"
  else check "$what, with the wrapper's own check taken out: this suite's check catches it" ok; fi

  spelled "$name-kept" kept "$@"
  one curl 127.0.0.1 "$name-kept" "$T/$name-kept.sh"
  ERR="$(cat "$T/err.txt")"
  other="$(grep -c -v -x -F -e "$HELD_LINE" "$T/$name-kept.handed" || true)"
  if [ "$kept" = refused ]; then
    exits "$what: the wrapper refuses" 70
    says "$what: the wrapper says its profile is not the one signed off" "$words"
    if [ -s "$T/$name-kept.handed" ]; then check "$what: the wrapper hands the sandbox tool nothing" "it handed over $(grep -c '' "$T/$name-kept.handed") times, $other of them a profile that is not the one held here"
    else check "$what: the wrapper hands the sandbox tool nothing" ok; fi
  else
    says "$what: the write to the profile fails" "PROFILE: readonly variable"
    if [ -s "$T/$name-kept.handed" ] && [ "$other" = "0" ]; then check "$what: every profile handed to the sandbox tool is the one held here" ok
    else check "$what: every profile handed to the sandbox tool is the one held here" "$(grep -c '' "$T/$name-kept.handed") hand overs, $other of them another profile"; fi
    case "$OUTCOME" in
      failed:*) check "$what: curl's post fails" ok ;;
      *) check "$what: curl's post fails" "outcome '$OUTCOME'" ;;
    esac
  fi
  if [ "$(arrived "$name-kept")" = "0" ]; then check "$what: nothing arrives" ok
  else check "$what: nothing arrives" "arrived $(arrived "$name-kept")"; fi
}

# The wrapper as it ships, with nothing changed but the stand in for its sandbox tool.
ONE_RULE='(allow process-exec (literal "/bin/ps") (with no-sandbox))'
spelled shipped kept
run "$T/shipped.sh" /usr/bin/touch "$T/ran.shipped"
exits "the wrapper as it ships, its sandbox tool written down: the command's exit code comes through" 0
ran "the wrapper as it ships, its sandbox tool written down: the command is run" shipped
suite_holds "$T/shipped.handed"
check "the wrapper's profile has one rule that lets a program out: every profile it hands the sandbox tool is the one held here, whole" "$HOLDS"
HANDED="$(grep -c '' "$T/shipped.handed" || true)"
if [ "$HANDED" -ge 2 ]; then check "the wrapper hands its profile to the sandbox tool for its proof and again for the command" ok
else check "the wrapper hands its profile to the sandbox tool for its proof and again for the command" "$HANDED hand overs were written down"; fi
# The same promise counted in what was handed over for the command, so that it does not rest on
# the copy of the profile held above being right.
LAST="$(tail -n 1 "$T/shipped.handed")"
if [ "$(occurs "$LAST" no-sandbox)" = "1" ]; then check "the profile handed over for the command says no-sandbox once" ok
else check "the profile handed over for the command says no-sandbox once" "it says it $(occurs "$LAST" no-sandbox) times"; fi
if [ "$(occurs "$LAST" allow)" = "2" ] && [ "$(occurs "$LAST" "(allow default)")" = "1" ]; then check "the profile handed over for the command holds two allows, its opening and the one rule" ok
else check "the profile handed over for the command holds two allows, its opening and the one rule" "it says allow $(occurs "$LAST" allow) times and (allow default) $(occurs "$LAST" "(allow default)") times"; fi
if [ "$(occurs "$LAST" "$ONE_RULE")" = "1" ]; then check "the profile handed over for the command holds the one rule for $PS_PROG, word for word" ok
else check "the profile handed over for the command holds the one rule for $PS_PROG, word for word" "that rule is in it $(occurs "$LAST" "$ONE_RULE") times"; fi
# Everything above reads what the stand in was handed, so the wrapper must have no second way to
# the sandbox tool: its code names the tool once, on the line the stand in replaces.
NAMED="$(grep -v '^ *#' "$WRAP" | grep -o 'sandbox-exec' | grep -c '' || true)"
if [ "$NAMED" = "1" ] && grep -q '^SANDBOX=/usr/bin/sandbox-exec$' "$WRAP"; then check "the wrapper's code names the sandbox tool once, on its SANDBOX line" ok
else check "the wrapper's code names the sandbox tool once, on its SANDBOX line" "its lines that are not comments name sandbox-exec $NAMED times"; fi
# And the wrapper's own check holds the same rule, written out and not built from OUTSIDE.
if [ "$(grep -c -x -F -e "ONE_OUT='$ONE_RULE'" "$WRAP" || true)" = "1" ]; then check "the wrapper's own check holds the one rule for $PS_PROG, word for word" ok
else check "the wrapper's own check holds the one rule for $PS_PROG, word for word" "no line ONE_OUT='$ONE_RULE' in $WRAP"; fi

if [ -n "$PORT" ]; then
  NL='
'
  # The end of the line that makes the profile, and the rule's own filter, as sed finds them; and
  # the same rule naming curl, as sed writes it.
  END='(with no-sandbox))"$'
  LIT='(literal \\"\$OUTSIDE\\")'
  CURL_RULE='(allow process-exec (literal \\"/usr/bin/curl\\") (with no-sandbox))'
  LATER='PROFILE="$PROFILE(allow process-exec (literal \\"/usr/bin/curl\\") (with no-""sandbox))"'
  printf '%s\n' '(version 1)' '(allow process-exec (literal "/usr/bin/curl") (with no-sandbox))' > "$T/more.sb"

  spelling same-line refused "$MORE_OUT" "a second rule on the same line" \
    "/^PROFILE=/s|$END|(with no-sandbox))$CURL_RULE\"|"
  spelling continued refused "$MORE_OUT" "a second rule on a continued line" \
    "/^PROFILE=/s|$END|(with no-sandbox))"'(allow process-exec (literal \\"/usr/bin/curl\\") (with no-\\\'"$NL"'sandbox))"|'
  spelling variable refused "$MORE_OUT" "a second rule built from a variable" \
    "/^PROFILE=/s|$END|(with no-sandbox))"'(allow process-exec (literal \\"/usr/bin/curl\\") (with no-$WORD))"|' \
    '/^PROFILE=/s|^|WORD=sandbox\'"$NL"'|'
  spelling star refused "$MORE_OUT" "a second rule written process-exec*" \
    "/^PROFILE=/s|$END|(with no-sandbox))"'(allow process-exec* (literal \\"/usr/bin/curl\\") (with no-sandbox))"|'
  spelling regex refused "$MORE_OUT" "a regex in place of the literal" \
    "/^PROFILE=/s,$LIT,"'(regex #\\"^/(bin/ps|usr/bin/curl)$\\"),'
  spelling subpath refused "$MORE_OUT" "a second rule with a subpath" \
    "/^PROFILE=/s|$END|(with no-sandbox))"'(allow process-exec (subpath \\"/usr/bin/curl\\") (with no-sandbox))"|'
  spelling prefix refused "$MORE_OUT" "a second rule with a prefix" \
    "/^PROFILE=/s|$END|(with no-sandbox))"'(allow process-exec (prefix \\"/usr/bin/cur\\") (with no-sandbox))"|'
  spelling second-literal refused "$MORE_OUT" "a second literal inside the one rule" \
    "/^PROFILE=/s,$LIT,"'(literal \\"$OUTSIDE\\") (literal \\"/usr/bin/curl\\"),'
  spelling later-line refused "$MORE_OUT" "a later line that adds to the profile" \
    '/^PROFILE=/s|$|\'"$NL$LATER"'|'
  spelling last-line unchanged "" "a line just before the command is run that adds to the profile" \
    '/^exec "\$SANDBOX"/s|^|'"$LATER"'\'"$NL"'|'
  spelling import refused "$NOT_A_DENY" "a second rule in a file the profile imports" \
    "/^PROFILE=/s|$END|(with no-sandbox))"'(import \\"'"$T"'/more.sb\\")"|'
  # MEASURED: what the rule does to the program it names. A copy of the wrapper whose rule names
  # curl in place of ps lets curl's post arrive, with every other line as shipped: the program
  # named is outside the sandbox altogether, network and all. That is why the shipped rule names
  # one program, and why adding a second one is a decision of Dan's and not a line to add.
  spelling names-curl refused "$MORE_OUT" "the one rule naming curl in place of ps" \
    "s|^OUTSIDE=.*|OUTSIDE='/usr/bin/curl'|"
  one direct 127.0.0.1 out-direct "$T/names-curl-out.sh"
  case "$OUTCOME" in
    failed:*) check "the one rule naming curl in place of ps: a post by any other program still fails" ok ;;
    *) check "the one rule naming curl in place of ps: a post by any other program still fails" "outcome '$OUTCOME'" ;;
  esac
  if [ "$(arrived out-direct)" = "0" ]; then check "the one rule naming curl in place of ps: nothing arrives from any other program" ok
  else check "the one rule naming curl in place of ps: nothing arrives from any other program" "arrived $(arrived out-direct)"; fi
fi

run "$PS_PROG" -o pid= -p "$$"
if [ "$RC" -eq 0 ] && [ "${OUT//[[:space:]]/}" = "$$" ]; then
  check "without the wrapper ps prints the pid it is asked for" ok

  run "$WRAP" /bin/sh -c '/bin/ps -o pid= -p "$1"' ps-case "$$"
  if [ "$RC" -eq 0 ] && [ "${OUT//[[:space:]]/}" = "$$" ]; then check "with the wrapper a command can run ps" ok
  else check "with the wrapper a command can run ps" "exit $RC, it printed '${OUT:0:60}', stderr: ${ERR:0:300}"; fi

  run "$WRAP" "$PS_PROG" -o pid= -p "$$"
  if [ "$RC" -eq 0 ] && [ "${OUT//[[:space:]]/}" = "$$" ]; then check "with the wrapper ps runs as the wrapper's own command" ok
  else check "with the wrapper ps runs as the wrapper's own command" "exit $RC, it printed '${OUT:0:60}', stderr: ${ERR:0:300}"; fi

  # A link is read through to the file it names, as it is for a program the wrapper refuses.
  ln -s "$PS_PROG" "$T/ps-link"
  run "$WRAP" "$T/ps-link" -o pid= -p "$$"
  if [ "$RC" -eq 0 ] && [ "${OUT//[[:space:]]/}" = "$$" ]; then check "with the wrapper a link to ps runs it" ok
  else check "with the wrapper a link to ps runs it" "exit $RC, it printed '${OUT:0:60}', stderr: ${ERR:0:300}"; fi

  # WHY THE RULE IS THERE, kept measured. A copy of the wrapper without it passes the wrapper's own
  # check of its profile (a profile made narrower is not refused) and runs its command, and ps does
  # not start in it. Should ps start there one day, macOS has stopped refusing it inside a sandbox
  # and the rule is no longer needed: that is Dan's to hear, since the rule would go on starting
  # ps outside with nothing else here turning red.
  changed norule 's| *(allow process-exec (literal \\"\$OUTSIDE\\") (with no-sandbox))||'
  run "$T/norule.sh" /usr/bin/touch "$T/ran.norule"
  exits "a copy without the one rule passes the wrapper's own check of its profile" 0
  ran "a copy without the one rule: the command is run" norule
  run "$T/norule.sh" /bin/sh -c '/bin/ps -o pid= -p "$1"' ps-case "$$"
  PRINTED=no
  case "$OUT" in *[![:space:]]*) PRINTED=yes ;; esac
  if [ "$RC" -ne 0 ] && [ "$PRINTED" = no ]; then check "a copy without the one rule: ps does not start, which is why the rule is there" ok
  else check "a copy without the one rule: ps does not start, which is why the rule is there" "exit $RC, it printed '${OUT:0:60}': macOS now starts ps inside a sandbox, so the rule is no longer needed and Dan should hear of it"; fi
  # The wrapper's own notice names that error on every run, so the shell's line about ps is matched.
  case "$ERR" in *"ps: Operation not permitted"*) check "a copy without the one rule: ps is refused with the sandbox's permission error" ok ;;
    *) check "a copy without the one rule: ps is refused with the sandbox's permission error" "stderr: ${ERR:0:300}" ;; esac

  # WHAT THE RULE DOES NOT LET THROUGH.
  # The command that ran ps is still in the sandbox: its post fails and nothing arrives.
  if [ -n "$PORT" ]; then
    one direct 127.0.0.1 open-after-ps /bin/sh -c "$AFTER_PS" after-ps
    if [ "$OUTCOME" = "sent" ] && [ "$(arrived open-after-ps)" = "1" ]; then check "after ps: without the wrapper the post arrives" ok
    else check "after ps: without the wrapper the post arrives" "outcome '$OUTCOME', arrived $(arrived open-after-ps)"; fi
    one direct 127.0.0.1 shut-after-ps "$WRAP" /bin/sh -c "$AFTER_PS" after-ps
    case "$OUTCOME" in
      failed:*) check "after ps: with the wrapper the post of the command that ran ps fails" ok ;;
      *) check "after ps: with the wrapper the post of the command that ran ps fails" "outcome '$OUTCOME'" ;;
    esac
    if [ "$(arrived shut-after-ps)" = "0" ]; then check "after ps: with the wrapper nothing arrives" ok
    else check "after ps: with the wrapper nothing arrives" "arrived $(arrived shut-after-ps)"; fi

    # And so is a NEW program the command starts once ps has run (the review of 2026-11-24): the
    # post is made by a child of the command, started after the ps.
    one child 127.0.0.1 open-child-after-ps /bin/sh -c "$AFTER_PS" after-ps
    if [ "$OUTCOME" = "sent" ] && [ "$(arrived open-child-after-ps)" = "1" ]; then check "a child started after ps: without the wrapper its post arrives" ok
    else check "a child started after ps: without the wrapper its post arrives" "outcome '$OUTCOME', arrived $(arrived open-child-after-ps)"; fi
    one child 127.0.0.1 shut-child-after-ps "$WRAP" /bin/sh -c "$AFTER_PS" after-ps
    case "$OUTCOME" in
      failed:*) check "a child started after ps: with the wrapper its post fails" ok ;;
      *) check "a child started after ps: with the wrapper its post fails" "outcome '$OUTCOME'" ;;
    esac
    if [ "$(arrived shut-child-after-ps)" = "0" ]; then check "a child started after ps: with the wrapper nothing arrives" ok
    else check "a child started after ps: with the wrapper nothing arrives" "arrived $(arrived shut-child-after-ps)"; fi
  fi

  # A SOCKET HANDED TO ps (the review of 2026-11-24). ps runs outside the sandbox, so what it writes
  # is not held back, and a command can give it any descriptor as its output. What stops that
  # carrying anything out is that the command cannot connect the socket first: the sandbox refuses
  # the connection, and ps is handed a socket that leads nowhere. Measured with a listener of this
  # case's own on loopback, and ps asked only for the pid of the process asking, so what arrives
  # without the wrapper is a number.
  cat > "$T/hand.py" <<'PY'
"""hand.py outer [front ...] | hand.py inner <port>. outer opens a UDP listener on loopback, runs
"<front> python3 hand.py inner <port>" and prints what inner said and how many datagrams arrived.
inner makes a UDP socket, tries to connect it to the listener, runs ps once into a pipe to see that
ps runs at all, and once with the socket as its output."""
import os
import socket
import subprocess
import sys

PS = ["/bin/ps", "-o", "pid=", "-p", str(os.getpid())]
if sys.argv[1] == "inner":
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("127.0.0.1", int(sys.argv[2])))
        state = "connected"
    except PermissionError:
        state = "refused"
    except OSError as e:
        state = "failed:%d" % e.errno
    try:
        plain = subprocess.run(PS, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        ran = "ran" if plain.returncode == 0 and plain.stdout.decode().strip() == str(os.getpid()) else "odd"
        subprocess.run(PS, stdin=subprocess.DEVNULL, stdout=s.fileno(), stderr=subprocess.DEVNULL)
    except OSError:
        ran = "unstarted"
    print(state + " ps-" + ran)
else:
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", 0))
    done = subprocess.run(sys.argv[2:] + [sys.executable, "-I", os.path.abspath(__file__), "inner",
                                          str(sink.getsockname()[1])],
                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    said = done.stdout.decode("utf-8", "replace").strip() or "nothing (exit %d)" % done.returncode
    # A datagram on loopback is in the listener's queue before the write that sent it returns,
    # and ps has ended, so what is there now is all there will be.
    sink.setblocking(False)
    count = 0
    while True:
        try:
            sink.recv(4096)
        except OSError:
            break
        count += 1
    print("%s arrived-%d" % (said, count))
PY
  run "$PY_FIXED" -I "$T/hand.py" outer
  if [ "$OUT" = "connected ps-ran arrived-1" ]; then
    check "a socket handed to ps: without the wrapper what ps prints arrives" ok
    run "$PY_FIXED" -I "$T/hand.py" outer "$WRAP"
    case "$OUT" in
      "refused ps-ran "*) check "a socket handed to ps: with the wrapper its connection is refused before ps has it, and ps runs" ok ;;
      *) check "a socket handed to ps: with the wrapper its connection is refused before ps has it, and ps runs" "it said '$OUT'" ;;
    esac
    case "$OUT" in
      *" arrived-0") check "a socket handed to ps: with the wrapper nothing arrives" ok ;;
      *) check "a socket handed to ps: with the wrapper nothing arrives" "it said '$OUT'" ;;
    esac
  else
    check "a socket handed to ps: without the wrapper what ps prints arrives" "it said '$OUT' (exit $RC), so nothing arriving with the wrapper would prove nothing"
  fi

  if [ -n "$PORT" ]; then

    # The rule names a file, not a name: another program called ps, found first on the PATH, stays
    # in the sandbox, and so does what it starts.
    mkdir "$T/psbin"
    printf '#!/bin/sh\nexec "$@"\n' > "$T/psbin/ps"
    chmod +x "$T/psbin/ps"
    one direct 127.0.0.1 open-named-ps /usr/bin/env PATH="$T/psbin:$PATH" ps
    if [ "$OUTCOME" = "sent" ] && [ "$(arrived open-named-ps)" = "1" ]; then check "another program named ps: without the wrapper its post arrives" ok
    else check "another program named ps: without the wrapper its post arrives" "outcome '$OUTCOME', arrived $(arrived open-named-ps)"; fi
    one direct 127.0.0.1 shut-named-ps "$WRAP" /usr/bin/env PATH="$T/psbin:$PATH" ps
    case "$OUTCOME" in
      failed:*) check "another program named ps: with the wrapper its post fails" ok ;;
      *) check "another program named ps: with the wrapper its post fails" "outcome '$OUTCOME'" ;;
    esac
    if [ "$(arrived shut-named-ps)" = "0" ]; then check "another program named ps: with the wrapper nothing arrives" ok
    else check "another program named ps: with the wrapper nothing arrives" "arrived $(arrived shut-named-ps)"; fi
  fi

  # The three hand offs are still refused to a command that has run ps.
  for prog in /usr/bin/open /usr/bin/osascript /bin/launchctl; do
    run "$WRAP" /bin/sh -c "$AFTER_PS" after-ps "$PY_FIXED" -I "$T/start.py" "$prog"
    if [ "$OUT" = "refused" ]; then check "after ps: with the wrapper $prog is still refused" ok
    else check "after ps: with the wrapper $prog is still refused" "it said '$OUT' (exit $RC)"; fi
  done

  # Every other setuid program in the system's folders is still refused, found on disk so that one
  # macOS adds is measured too (L96). Left out: ps itself, the programs the wrapper refuses by name
  # (measured above), and the three that ask for a password, which this suite never starts, refused
  # or not. Each start is the program with --help, and under the wrapper none of them starts.
  run "$PY_FIXED" -I "$T/start.py" /usr/bin/atq
  if [ "$OUT" = "started" ]; then
    check "without the wrapper another setuid program, atq, starts" ok
    MEASURED_SUID=0
    for prog in $(find /bin /usr/bin /sbin /usr/sbin -maxdepth 1 -type f -perm -4000 2>/dev/null | sort); do
      case "$prog" in "$PS_PROG"|/usr/bin/sudo|/usr/bin/su|/usr/bin/login) continue ;; esac
      case " $LISTED " in *" $prog "*) continue ;; esac
      run "$WRAP" "$PY_FIXED" -I "$T/start.py" "$prog"
      if [ "$OUT" = "refused" ]; then check "with the wrapper the setuid program $prog is still refused" ok
      else check "with the wrapper the setuid program $prog is still refused" "it said '$OUT'"; fi
      MEASURED_SUID=$((MEASURED_SUID + 1))
    done
    if [ "$MEASURED_SUID" -ge 1 ]; then check "at least one other setuid program was found and measured" ok
    else check "at least one other setuid program was found and measured" "none was found in /bin, /usr/bin, /sbin or /usr/sbin"; fi
  else
    echo "SUITE-PART-UNMEASURED every other setuid program being refused under the wrapper: outside it atq said '$OUT', so a refusal inside would prove nothing"
  fi

  # The caller cannot put its own code into the ps that leaves. A library named in
  # DYLD_INSERT_LIBRARIES is loaded into a program compiled here, under the wrapper, and is not
  # loaded into ps, which macOS starts without it as it does every program of its own.
  cat > "$T/with-library.py" <<'PY'
"""with-library.py <library> <marker file> <program> [words]: the program in this one's place,
with the library named for the loader and the marker file named for the library."""
import os
import sys

os.environ["DYLD_INSERT_LIBRARIES"] = sys.argv[1]
os.environ["MARK_3482"] = sys.argv[2]
os.execv(sys.argv[3], sys.argv[3:])
PY
  printf '%s\n' '#include <stdio.h>' '#include <stdlib.h>' \
    '__attribute__((constructor)) static void loaded(void) {' \
    '  const char *path = getenv("MARK_3482");' \
    '  if (path) { FILE *f = fopen(path, "w"); if (f) { fputs("loaded\n", f); fclose(f); } }' \
    '}' > "$T/inject.c"
  printf '%s\n' '#include <unistd.h>' '#include <stdlib.h>' \
    'int main(int argc, char **argv) { if (argc > 1) sleep((unsigned)atoi(argv[1])); return 0; }' > "$T/own.c"
  if [ -x /usr/bin/cc ] && /usr/bin/cc -dynamiclib -o "$T/inject.dylib" "$T/inject.c" 2>"$T/cc.txt" && /usr/bin/cc -o "$T/own-prog" "$T/own.c" 2>>"$T/cc.txt"; then
    run "$WRAP" "$PY_FIXED" -I "$T/with-library.py" "$T/inject.dylib" "$T/loaded.own" "$T/own-prog"
    if [ -e "$T/loaded.own" ]; then
      check "with the wrapper a library the caller names is loaded into a program compiled here" ok
      run "$WRAP" "$PY_FIXED" -I "$T/with-library.py" "$T/inject.dylib" "$T/loaded.ps" "$PS_PROG" -o pid= -p "$$"
      if [ "$RC" -eq 0 ] && [ "${OUT//[[:space:]]/}" = "$$" ]; then check "with the wrapper ps runs when the caller names a library for it" ok
      else check "with the wrapper ps runs when the caller names a library for it" "exit $RC, it printed '${OUT:0:60}', stderr: ${ERR:0:300}"; fi
      if [ -e "$T/loaded.ps" ]; then check "with the wrapper ps does not load a library the caller names" "the library WAS loaded into ps, which runs outside the sandbox: a wrapped command can run its own code there"
      else check "with the wrapper ps does not load a library the caller names" ok; fi
    else
      check "with the wrapper a library the caller names is loaded into a program compiled here" "it was not loaded (exit $RC, ${ERR:0:200}), so its not loading into ps would prove nothing"
    fi

    # A TRACED OR A PAUSED ps (the review of 2026-11-24). A wrapped command can start ps under a
    # debugger's hold (fork, PT_TRACE_ME, exec) or paused (posix_spawn, START_SUSPENDED). The
    # traced one then runs as the user, OUTSIDE the sandbox, stopped, with the sandboxed command
    # holding it: the one state in which a wrapped command holds a process that has the network.
    # It is safe only because macOS refuses that command the process's task port and loads no
    # library the command names into it, and both are macOS's to change. So both are held here,
    # each beside a program compiled on the spot for which the same step succeeds (L248). Where a
    # control does not hold on this Mac the case is unmeasured, never passed (L411).
    cat > "$T/held.c" <<'C'
/* held <t|s> <library|-> <program> [words]: start the program traced (t) or paused (s), with the
   library named for it alone, never for this launcher. While it is held, print whether it is in a
   sandbox and whether its task port is given. Then let it run and print how it ended. Nothing is
   written into the program: the port is only asked for. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <mach/mach.h>

extern char **environ;
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

int main(int argc, char **argv) {
  pid_t pid;
  int st;
  mach_port_t task = MACH_PORT_NULL;
  if (argc < 4) return 64;
  if (argv[1][0] == 't') {
    pid = fork();
    if (pid < 0) { printf("held=no: fork failed\n"); return 2; }
    if (pid == 0) {
      if (strcmp(argv[2], "-")) setenv("DYLD_INSERT_LIBRARIES", argv[2], 1);
      if (ptrace(PT_TRACE_ME, 0, 0, 0) != 0) _exit(126);
      execv(argv[3], argv + 3);
      _exit(127);
    }
    if (waitpid(pid, &st, WUNTRACED) != pid || !WIFSTOPPED(st)) {
      printf("held=no: the program did not stop when it was started traced\n");
      return 3;
    }
    printf("held=traced\n");
  } else {
    posix_spawnattr_t attr;
    int r;
    if (strcmp(argv[2], "-")) setenv("DYLD_INSERT_LIBRARIES", argv[2], 1);
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
    r = posix_spawn(&pid, argv[3], NULL, &attr, argv + 3, environ);
    if (r) { printf("held=no: the program could not be started paused (%d)\n", r); return 2; }
    printf("held=paused\n");
  }
  printf("sandboxed=%d\n", sandbox_check(pid, NULL, 0));
  printf("port=%d\n", (int)task_for_pid(mach_task_self(), pid, &task));
  fflush(stdout);
  if (argv[1][0] == 't') ptrace(PT_CONTINUE, pid, (caddr_t)1, 0);
  else kill(pid, SIGCONT);
  waitpid(pid, &st, 0);
  printf("ended=%d\n", WIFEXITED(st) ? WEXITSTATUS(st) : -WTERMSIG(st));
  return 0;
}
C
    # held_run <t|s> <library|-> <marker name> <program> [words]: the program started traced or
    # paused under the wrapper. HELD, BOXED, GIVEN and ENDED are what the launcher printed (GIVEN
    # is 0 when the task port was given), and LOADED is whether the library wrote its marker.
    said() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
    held_run() {
      local how="$1" library="$2" mark="$T/loaded.$3"
      shift 3
      rm -f "$mark"
      run "$WRAP" /usr/bin/env MARK_3482="$mark" "$T/held" "$how" "$library" "$@"
      HELD="$(said held)"; BOXED="$(said sandboxed)"; GIVEN="$(said port)"; ENDED="$(said ended)"
      if [ -e "$mark" ]; then LOADED=yes; else LOADED=no; fi
    }
    if /usr/bin/cc -o "$T/held" "$T/held.c" 2>"$T/cc-held.txt"; then
      # The control for the task port: a program signed here to allow it, started paused under
      # the wrapper, whose port IS given to the wrapped command.
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>' > "$T/allow.plist"
      cp "$T/own-prog" "$T/own-allowed"
      PORT_CONTROL=no
      HELD="not started"; GIVEN=""
      if /usr/bin/codesign -s - -f --entitlements "$T/allow.plist" "$T/own-allowed" >"$T/sign.txt" 2>&1; then
        held_run s - allowed "$T/own-allowed"
        if [ "$HELD" = paused ] && [ "$GIVEN" = "0" ]; then PORT_CONTROL=yes; fi
      fi
      if [ "$PORT_CONTROL" = yes ]; then check "held: with the wrapper the task port of a program signed here to allow it IS given to the wrapped command" ok
      else echo "SUITE-PART-UNMEASURED whether a wrapped command is refused the task port of a traced or a paused ps: the program to compare with, signed here to allow it and started paused under the wrapper, said held='$HELD' port='$GIVEN' ($(head -c 200 "$T/sign.txt" 2>/dev/null)), so a refusal for ps would prove nothing"; fi

      held_run t "$T/inject.dylib" traced-own "$T/own-prog"
      if [ "$HELD" = traced ] && [ "$LOADED" = yes ] && [ "$BOXED" = "1" ]; then
        check "traced: with the wrapper a program compiled here, started traced, is in the sandbox and loads the library named for it" ok
        held_run t "$T/inject.dylib" traced-ps "$PS_PROG" -o pid= -p "$$"
        if [ "$HELD" = traced ]; then
          if [ "$ENDED" = "0" ]; then check "traced: with the wrapper a ps started traced is held, let go and runs to its end" ok
          else check "traced: with the wrapper a ps started traced is held, let go and runs to its end" "it ended '$ENDED', stderr: ${ERR:0:300}"; fi
          if [ "$BOXED" = "0" ]; then check "traced: MEASURED, the traced ps is outside the sandbox while the wrapped command holds it" ok
          else check "traced: MEASURED, the traced ps is outside the sandbox while the wrapped command holds it" "the launcher said sandboxed='$BOXED': the sandbox no longer behaves as no-network-run.sh and the README say, so bring both up to date"; fi
          if [ "$LOADED" = no ]; then check "traced: with the wrapper the traced ps does not load a library the caller names" ok
          else check "traced: with the wrapper the traced ps does not load a library the caller names" "the library WAS loaded into a ps that runs outside the sandbox: a wrapped command can run its own code there"; fi
          if [ "$PORT_CONTROL" = yes ]; then
            if [ -n "$GIVEN" ] && [ "$GIVEN" != "0" ]; then check "traced: the wrapped command is refused the task port of the traced ps" ok
            else check "traced: the wrapped command is refused the task port of the traced ps" "the launcher said port='$GIVEN': a wrapped command can take control of a ps that runs outside the sandbox"; fi
          fi
        else
          echo "SUITE-PART-UNMEASURED a traced ps under the wrapper: the launcher said '${HELD:-nothing}' (exit $RC, stderr: ${ERR:0:200})"
        fi
      else
        echo "SUITE-PART-UNMEASURED a traced ps under the wrapper: the control did not hold (a program compiled here, started traced under the wrapper, said held='$HELD' sandboxed='$BOXED', library loaded: $LOADED), so nothing read from a traced ps would prove anything"
      fi

      held_run s "$T/inject.dylib" paused-own "$T/own-prog"
      if [ "$HELD" = paused ] && [ "$LOADED" = yes ]; then
        check "paused: with the wrapper a program compiled here, started paused, loads the library named for it" ok
        held_run s "$T/inject.dylib" paused-ps "$PS_PROG" -o pid= -p "$$"
        if [ "$HELD" = paused ]; then
          if [ "$ENDED" = "0" ]; then check "paused: with the wrapper a ps started paused is held, let go and runs to its end" ok
          else check "paused: with the wrapper a ps started paused is held, let go and runs to its end" "it ended '$ENDED', stderr: ${ERR:0:300}"; fi
          if [ "$LOADED" = no ]; then check "paused: with the wrapper the paused ps does not load a library the caller names" ok
          else check "paused: with the wrapper the paused ps does not load a library the caller names" "the library WAS loaded into a ps that runs outside the sandbox: a wrapped command can run its own code there"; fi
          if [ "$PORT_CONTROL" = yes ]; then
            if [ -n "$GIVEN" ] && [ "$GIVEN" != "0" ]; then check "paused: the wrapped command is refused the task port of the paused ps" ok
            else check "paused: the wrapped command is refused the task port of the paused ps" "the launcher said port='$GIVEN': a wrapped command can take control of a ps that runs outside the sandbox"; fi
          fi
        else
          echo "SUITE-PART-UNMEASURED a paused ps under the wrapper: the launcher said '${HELD:-nothing}' (exit $RC, stderr: ${ERR:0:200})"
        fi
      else
        echo "SUITE-PART-UNMEASURED a paused ps under the wrapper: the control did not hold (a program compiled here, started paused under the wrapper, said held='$HELD', library loaded: $LOADED), so nothing read from a paused ps would prove anything"
      fi
    else
      echo "SUITE-PART-UNMEASURED a traced and a paused ps under the wrapper: /usr/bin/cc could not compile the launcher the cases need ($(head -c 200 "$T/cc-held.txt" 2>/dev/null))"
    fi

    # WHAT THE RULE DOES LET THROUGH, asserted as measured so the wrapper's own account stays true.
    # A process of this user's, started outside the sandbox, with one marker among its arguments
    # and one in its environment.
    cat > "$T/procargs.py" <<'PY'
"""procargs.py <pid> <marker>: whether the marker is in what the kernel hands back for the pid's
arguments and environment (sysctl KERN_PROCARGS2). Prints found, absent or refused, and nothing
of what was read."""
import ctypes
import ctypes.util
import sys

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
mib = (ctypes.c_int * 3)(1, 49, int(sys.argv[1]))
size = ctypes.c_size_t(1 << 20)
buf = ctypes.create_string_buffer(size.value)
if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
    print("refused")
else:
    print("found" if sys.argv[2].encode() in buf.raw[:size.value] else "absent")
PY
    MARK_ENV_3482=environment-marker-3482 "$T/own-prog" 300 argument-marker-3482 </dev/null >/dev/null 2>&1 &
    OTHER=$!
    hang_wait 'kill -0 "$OTHER" 2>/dev/null && [ "$("$PS_PROG" -o comm= -p "$OTHER" 2>/dev/null)" = "$T/own-prog" ]' || true
    # ALREADY SO before the rule (measured 2026-11-24 under the profile without it): a wrapped
    # command reads another of this user's processes' environment from the kernel, with no ps.
    run "$WRAP" "$PY_FIXED" -I "$T/procargs.py" "$OTHER" environment-marker-3482
    if [ "$OUT" = "found" ]; then check "environment: ALREADY SO without ps, a wrapped command reads another of this user's processes' environment from the kernel" ok
    else check "environment: ALREADY SO without ps, a wrapped command reads another of this user's processes' environment from the kernel" "it said '$OUT': the sandbox no longer behaves as no-network-run.sh and the README say, so bring both up to date"; fi
    # And ps, under the rule, shows the same environment: the same thing by a second route.
    run "$WRAP" /bin/sh -c 'case "$(/bin/ps eww -o command= -p "$1" 2>/dev/null)" in *environment-marker-3482*) echo found ;; *) echo absent ;; esac' ps-env "$OTHER"
    if [ "$OUT" = "found" ]; then check "environment: LET THROUGH, ps under the wrapper shows another of this user's processes' environment" ok
    else check "environment: LET THROUGH, ps under the wrapper shows another of this user's processes' environment" "it said '$OUT': the sandbox no longer behaves as no-network-run.sh and the README say, so bring both up to date"; fi
    kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
  else
    echo "SUITE-PART-UNMEASURED whether a library the caller names is loaded into ps (started plainly, traced or paused), whether a wrapped command is refused the task port of a ps it holds, and what ps shows of another process's environment: /usr/bin/cc could not compile the two small programs the cases need ($(head -c 200 "$T/cc.txt" 2>/dev/null))"
  fi

  # NEW with the rule: the arguments of a process that is NOT this user's. The kernel refuses them
  # to a wrapped command that asks it directly, and ps, which is root's while it runs, shows them.
  # Process 1 is launchd, root's on every Mac. Only the length of what came back is looked at.
  if [ "$(id -u)" -ne 0 ]; then
    run "$WRAP" "$PY_FIXED" -I "$T/procargs.py" 1 launchd
    if [ "$OUT" = "refused" ]; then check "arguments: without ps the kernel refuses a wrapped command the arguments of a process that is not this user's" ok
    else check "arguments: without ps the kernel refuses a wrapped command the arguments of a process that is not this user's" "it said '$OUT'"; fi
    run "$WRAP" /bin/sh -c 'a="$(/bin/ps ww -o args= -p 1 2>/dev/null)"; if [ -n "$a" ]; then echo shown; else echo nothing; fi' ps-args
    if [ "$OUT" = "shown" ]; then check "arguments: LET THROUGH, ps under the wrapper shows the arguments of a process that is not this user's" ok
    else check "arguments: LET THROUGH, ps under the wrapper shows the arguments of a process that is not this user's" "it said '$OUT': the sandbox no longer behaves as no-network-run.sh and the README say, so bring both up to date"; fi
  else
    echo "SUITE-PART-UNMEASURED what ps adds for a process that is not this user's: the suite is running as root, which reads every process"
  fi
else
  check "without the wrapper ps prints the pid it is asked for" "exit $RC, it printed '${OUT:0:60}', stderr: ${ERR:0:200}, so nothing about ps under the wrapper could be measured"
fi

echo "no network run: the sandbox is proved on every run, and a run that cannot prove it runs nothing"

# A profile the sandbox tool cannot read. It ends in a refusal that is never closed, which the
# wrapper's own check of its profile lets by (that check looks for what is let out, not for a
# profile that reads), so this is refused by the proof.
changed unapplied "s|^PROFILE=.*|PROFILE='(version 1)(allow default)(deny network*'|"
run "$T/unapplied.sh" /usr/bin/touch "$T/ran.unapplied"
exits "a profile that cannot be applied is refused" 70
says "a profile that cannot be applied says the check was not made" "could not be checked"
not_ran "a profile that cannot be applied runs nothing" unapplied

# A profile that does not start with the opening is refused before that, by the wrapper's own
# check of its profile: it cannot be told what such a profile lets through.
changed headless "s|^PROFILE=.*|PROFILE='(version 1)(allow default'|"
run "$T/headless.sh" /usr/bin/touch "$T/ran.headless"
exits "a profile without its opening is refused" 70
says "a profile without its opening is refused by the wrapper's own check of it" "$NOT_A_DENY"
not_ran "a profile without its opening runs nothing" headless

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

# The programs the profile refuses to start are proved the same way on every run (#3288). A
# profile that still takes the network away and no longer refuses them: nothing is run.
changed nostarts 's|(deny process-exec\*\$DENY_STARTS)||'
run "$T/nostarts.sh" /usr/bin/touch "$T/ran.nostarts"
exits "a sandbox that does not refuse to start a listed program is refused" 70
says "a sandbox that does not refuse to start a listed program says so" "did NOT refuse to start"
not_ran "a sandbox that does not refuse to start a listed program runs nothing" nostarts

# A listed program that cannot be started even outside the sandbox, here a file that is there and
# is no program: its not starting inside would prove nothing, so nothing is run.
changed unstartable "s|^HANDOFFS=.*|HANDOFFS='/etc/hosts'|"
run "$T/unstartable.sh" /usr/bin/touch "$T/ran.unstartable"
exits "a listed program that does not start even outside the sandbox is refused" 70
says "a start control that fails says a refusal would prove nothing" "would prove nothing"
not_ran "a start control that fails runs nothing" unstartable

# A listed program that is not on the machine at all cannot be handed anything, so it is passed
# over and the command runs.
changed absent "s|^HANDOFFS=.*|HANDOFFS='/nonexistent-3288/open'|"
run "$T/absent.sh" /usr/bin/touch "$T/ran.absent"
exits "a listed program that is not on this machine does not stop the run" 0
ran "a listed program that is not on this machine: the command is run" absent

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
