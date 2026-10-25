#!/usr/bin/env bash
# Tests for the order lessons reviews start in, so reviews started together share the cached
# lessons (claude-config#1619).
#
# Since #1599 the lessons are the appended system prompt and are cached for five minutes, so a
# review that sends its first request after another's has begun answering reads them back (57k
# tokens). Reviews launched at the same moment (the groups of a branch too large for one review, the
# review score's parallel runs) each wrote them instead: measured 2026-10-23, the first three
# reviews launched together each read back only the 19k tool and system prefix. So the runner
# (lib/ai-review-run.py) takes a turn before it starts claude: the first review with a given model
# and lessons goes at once and holds a lock until its reviewer begins answering (the first event of
# claude's stream, when the cache has been written), and every review behind it waits for that,
# within its own bound, then starts. A failed first review releases the lock as it ends, so the
# next one takes over rather than waiting out the bound.
#
# Every wait here is on a condition or an injected clock, never a fixed sleep (L290, L524), and no
# test reaches a real model: the claude below is a fake that writes the stream's events itself.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

# Every wait on a condition gives up at the one ceiling only a hang reaches (lib/hang-wait.sh,
# claude-config#1679), handed to the stand in reviewer as FAKE_HANG_S, since it runs as a process of
# its own.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
export FAKE_HANG_S="$HANG_S"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/lib/ai-review-run.py"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

# Reads PASS/FAIL lines from a Python block, and fails when it ran fewer cases than it names, so a
# block that crashed on import reads as a failure, never a pass.
tally(){   # $1 = what the block tests, $2 = cases expected, $3 = its output
  local ran=0 verdict rest
  while IFS=$'\t' read -r verdict rest; do
    case "$verdict" in
      PASS) ok; ran=$((ran + 1)) ;;
      FAIL) bad "$1: $rest"; ran=$((ran + 1)) ;;
      *) [ -n "$verdict" ] && bad "$1 printed something unexpected: $verdict $rest" ;;
    esac
  done <<< "$3"
  [ "$ran" -eq "$2" ] && ok || bad "$1 ran $ran of $2 cases"
}

# ===========================================================================
# 1. The turn, with an injected clock and sleep. A second open of the lock file in this process is a
#    separate holder, as another review would be, so a case can hold the lock itself.
# ===========================================================================
turn_out="$(python3 - "$RUNNER" "$WORKDIR/turns" <<'EOF'
import fcntl, importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("ai_review_run", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = sys.argv[2]
os.makedirs(root, exist_ok=True)

def result(name, cond, detail=""):
    print(("PASS\t" if cond else "FAIL\t") + name + ("" if cond else f": {detail}"))

class Clock:
    """A clock that moves only when the code under test sleeps, and a sleep that can act."""
    def __init__(self, on_sleep=None):
        self.t, self.sleeps, self.on_sleep = 100.0, 0, on_sleep
    def clock(self):
        return self.t
    def sleep(self, s):
        self.sleeps += 1
        self.t += s
        if self.on_sleep:
            self.on_sleep(self.sleeps)

NOW = 1_800_000_000.0
def now():
    return NOW

def fresh_dir(name):
    d = os.path.join(root, name)
    os.makedirs(d, exist_ok=True)
    return d

def hold(d, key):
    fd = os.open(os.path.join(d, key + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return fd

def free(d, key):
    """True when nobody holds the lock (this process can take it, and lets it go again)."""
    fd = os.open(os.path.join(d, key + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False
    finally:
        os.close(fd)

def warm(d, key, age=0):
    p = os.path.join(d, key + ".warm")
    with open(p, "w"):
        pass
    os.utime(p, (NOW - age, NOW - age))

K = "k"

# a. Nobody ahead and nothing warm: this review goes first, at once, and holds the turn until its
#    reviewer begins answering, which marks the lessons warm and lets the turn go.
d = fresh_dir("a"); c = Clock()
t = m.take_turn(d, K, 60, clock=c.clock, sleep=c.sleep, now=now)
result("a review with nobody ahead goes first", t.order == "first", t.order)
result("and waits for nothing", c.sleeps == 0 and t.waited == 0, (c.sleeps, t.waited))
result("and holds the turn while its reviewer has not begun answering", not free(d, K))
t.answering()
result("its reviewer beginning to answer marks the lessons warm", os.path.exists(os.path.join(d, K + ".warm")))
result("and lets the turn go", free(d, K))
t.answering(); t.release()
result("a second answering or release changes nothing", free(d, K))

# b. Warm within the life of the cache: start at once, without taking the lock.
d = fresh_dir("b"); warm(d, K, age=30); c = Clock()
t = m.take_turn(d, K, 60, clock=c.clock, sleep=c.sleep, now=now)
result("lessons warm from a review that began answering 30 s ago: start at once", t.order == "warm" and c.sleeps == 0, (t.order, c.sleeps))
result("without holding the turn", free(d, K))
t.release()

# c. Warm too long ago for the cache to still hold them: go first.
d = fresh_dir("c"); warm(d, K, age=m.WARM_FRESH_SECONDS + 1); c = Clock()
t = m.take_turn(d, K, 60, clock=c.clock, sleep=c.sleep, now=now)
result("lessons last warm past the freshness window are cold: go first", t.order == "first", t.order)
t.release()

# d. A review ahead holds the turn and begins answering on the third look: follow it.
d = fresh_dir("d"); fd = hold(d, K)
c = Clock(on_sleep=lambda n: n == 3 and warm(d, K))
t = m.take_turn(d, K, 60, clock=c.clock, sleep=c.sleep, now=now, poll=0.5)
result("a review behind one that holds the turn waits, and follows once it begins answering", t.order == "followed", t.order)
result("having waited exactly as long as the injected clock says", t.waited == 1.5 and c.sleeps == 3, (t.waited, c.sleeps))
result("and never took the turn from the review ahead", not free(d, K))
os.close(fd); t.release()

# e. The review ahead ends WITHOUT beginning to answer (it failed): the next one takes over at once,
#    rather than waiting out its bound (a failed first review never blocks the rest).
d = fresh_dir("e"); held = [hold(d, K)]
def let_go(n):
    if n == 2:
        os.close(held[0])
c = Clock(on_sleep=let_go)
t = m.take_turn(d, K, 60, clock=c.clock, sleep=c.sleep, now=now, poll=0.5)
result("a review ahead that ended without answering is taken over at once", t.order == "took-over", t.order)
result("on the next look, not at the bound", c.sleeps == 2 and t.waited == 1.0, (c.sleeps, t.waited))
result("and the one taking over now holds the turn for the rest", not free(d, K))
t.release()
result("which it lets go when it ends", free(d, K))

# f. The review ahead never answers and never ends: give up at the bound, and say so.
d = fresh_dir("f"); fd = hold(d, K); c = Clock()
t = m.take_turn(d, K, 3, clock=c.clock, sleep=c.sleep, now=now, poll=0.5)
result("a review ahead that never begins answering is waited for only up to the bound", t.order == "gave-up", t.order)
result("which is the bound the caller set, by the injected clock", t.waited == 3.0 and c.sleeps == 6, (t.waited, c.sleeps))
result("and giving up does not take the turn", not free(d, K))
os.close(fd)

# g. A bound of nothing (a deadline too short to spend on waiting): give up without sleeping.
d = fresh_dir("g"); fd = hold(d, K); c = Clock()
t = m.take_turn(d, K, 0, clock=c.clock, sleep=c.sleep, now=now)
result("a bound of 0 gives up at once", t.order == "gave-up" and c.sleeps == 0, (t.order, c.sleeps))
os.close(fd)

# h. Nowhere to keep the turn: start at once, saying the turn could not be taken (never a block).
blocker = os.path.join(root, "a-file")
open(blocker, "w").close()
c = Clock()
t = m.take_turn(os.path.join(blocker, "warm"), K, 60, clock=c.clock, sleep=c.sleep, now=now)
result("a folder the turn cannot be kept in starts the review at once, saying so", t.order == "unavailable" and c.sleeps == 0, (t.order, c.sleeps))
t.answering(); t.release()
result("and its answering and release are harmless", True)

# i. A different model or different lessons is a different cache, so a different turn.
k1 = m.start_key("sonnet", "lessons A")
result("the turn is keyed on model and lessons", len({k1, m.start_key("opus", "lessons A"), m.start_key("sonnet", "lessons B")}) == 3)
result("and the same model and lessons always name the same turn", k1 == m.start_key("sonnet", "lessons A"))

# j. The bound: START_WAIT_SECONDS by default, never more than a quarter of the deadline, and set by
#    AI_REVIEW_START_WAIT_SECONDS; a value that is not a number is the default.
result("the bound is 60 s by default", m.start_wait_bound(600, {}) == 60, m.start_wait_bound(600, {}))
result("and at most a quarter of the deadline", m.start_wait_bound(40, {}) == 10)
result("and set by AI_REVIEW_START_WAIT_SECONDS", m.start_wait_bound(600, {"AI_REVIEW_START_WAIT_SECONDS": "5"}) == 5)
result("a value that is not a number is the default", m.start_wait_bound(600, {"AI_REVIEW_START_WAIT_SECONDS": "soon"}) == 60)

# k. Where the turn is kept: AI_REVIEW_WARM_DIR, else beside the review state.
result("the turn is kept where AI_REVIEW_WARM_DIR says", m.warm_dir({"AI_REVIEW_WARM_DIR": "/x/w"}) == "/x/w")
result("else in a folder of the review state", m.warm_dir({"AI_REVIEW_STATE_DIR": "/x/s"}) == "/x/s/warm")
EOF
)"
tally "the turn" 30 "$turn_out"

# ===========================================================================
# 2. Assume it runs twice: eight reviews take the turn at the same instant, with real locks, a real
#    clock and a short poll. Exactly one goes first, and the rest follow it once it begins answering.
# ===========================================================================
race_out="$(python3 - "$RUNNER" "$WORKDIR/race" <<'EOF'
import importlib.util, os, sys, threading
spec = importlib.util.spec_from_file_location("ai_review_run", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = sys.argv[2]
barrier = threading.Barrier(8)
orders, lock = [], threading.Lock()
def review():
    barrier.wait()
    t = m.take_turn(d, "race", 30, poll=0.01)
    with lock:
        orders.append(t.order)
    t.answering()
    t.release()
threads = [threading.Thread(target=review) for _ in range(8)]
for th in threads:
    th.start()
for th in threads:
    th.join(60)
firsts = orders.count("first")
print(("PASS" if len(orders) == 8 else "FAIL") + f"\tevery one of 8 reviews started together got a turn ({len(orders)})")
print(("PASS" if firsts == 1 else "FAIL") + f"\texactly one of them went first ({orders})")
behind = [o for o in orders if o != "first"]
print(("PASS" if behind and all(o in ("followed", "warm") for o in behind) else "FAIL")
      + f"\tand every other followed it, none giving up or taking over ({orders})")
EOF
)"
tally "eight reviews at once" 3 "$race_out"

# ===========================================================================
# 3. Reading claude's stream: the first event of the reviewer's answer marks the turn, once; the
#    result event holds the review; a line that is not an event is kept as what was printed.
# ===========================================================================
stream_out="$(python3 - "$RUNNER" <<'EOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ai_review_run", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def result(name, cond, detail=""):
    print(("PASS\t" if cond else "FAIL\t") + name + ("" if cond else f": {detail}"))

def feed(lines):
    got, seen = m.new_stream(), []
    for i, line in enumerate(lines):
        m.read_event(line.encode("utf-8"), got, lambda i=i: seen.append(i))
    return got, seen

init = json.dumps({"type": "system", "subtype": "init", "session_id": "s"})
start = json.dumps({"type": "stream_event", "event": {"type": "message_start", "message": {}}})
delta = json.dumps({"type": "stream_event", "event": {"type": "content_block_delta"}})
whole = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "No issues found."}]}})
res = json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "No issues found."})

got, seen = feed([init, start, delta, delta, whole, res])
result("the turn is marked at the first stream event, the start of the answer", seen[:1] == [1], seen)
result("the init event, before any request, does not mark it", 0 not in seen, seen)
result("the result event holds the review", (got["result"] or {}).get("result") == "No issues found.", got["result"])
result("every line was read as an event", got["events"] == 6 and not got["other"], got)

got, seen = feed([init, whole, res])
result("with no partial events, the whole answer marks it instead", seen[:1] == [1], seen)

synthetic = json.dumps({"type": "assistant", "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "API Error: 401"}]}})
failed = json.dumps({"type": "result", "subtype": "success", "is_error": True, "result": "API Error: 401"})
got, seen = feed([init, synthetic, failed])
result("an error Claude Code writes when no request reached the model marks nothing", not seen, seen)
result("though its result is still read", (got["result"] or {}).get("is_error") is True, got["result"])

got, seen = feed(["", "   "])
result("blank lines are nothing at all", got["events"] == 0 and not got["other"] and not seen, got)

got, seen = feed(["I could not review this.", "[1, 2]"])
result("a line that is not an event is kept as printed text", got["other"] == ["I could not review this.", "[1, 2]"], got["other"])
result("and marks nothing", not seen and got["result"] is None, seen)
EOF
)"
tally "the stream" 10 "$stream_out"

# ===========================================================================
# 4. The runner itself, end to end, against a fake claude that writes the stream. Each run gets its
#    own copy of the diff (the runner removes the one it was given).
# ===========================================================================
FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
export FAKE_LOG="$WORKDIR/fakelog"; mkdir -p "$FAKE_LOG"
cat > "$FAKEBIN/claude" <<'EOS'
#!/usr/bin/env python3
# A fake claude writing the events of `claude -p --output-format stream-json --verbose
# --include-partial-messages`. FAKE_MODE picks the outcome; FAKE_HOLD names a file the answer waits
# for (bounded) once it has begun, so a case can look at the turn while the reviewer is answering.
import json, os, sys, time
log = os.environ["FAKE_LOG"]
with open(os.path.join(log, "calls"), "a") as f:
    f.write("called\n")
with open(os.path.join(log, "args"), "w") as f:
    f.write("\x1e".join(sys.argv[1:]))
sys.stdin.read()
mode = os.environ.get("FAKE_MODE", "ok")
text = os.environ.get("FAKE_TEXT", "No issues found.")
def out(ev):
    sys.stdout.write(json.dumps(ev) + "\n")
    sys.stdout.flush()
if mode == "fail":
    sys.stderr.write("fake claude: could not start\n")
    sys.exit(1)
if mode == "nothing":
    sys.exit(0)
if mode == "text":
    print(text)
    sys.exit(0)
out({"type": "system", "subtype": "init", "session_id": "fake"})
if mode == "no-result":
    sys.exit(0)
out({"type": "stream_event", "event": {"type": "message_start", "message": {"usage": {}}}})
hold = os.environ.get("FAKE_HOLD")
if hold:
    open(os.path.join(log, "answering"), "w").close()
    t0 = time.time()
    while not os.path.exists(hold) and time.time() - t0 < float(os.environ.get("FAKE_HANG_S", "300")):
        time.sleep(0.05)
usage = {"input_tokens": 12, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 57000, "output_tokens": 40}
if mode == "error-result":
    out({"type": "result", "subtype": "error_max_turns", "is_error": True, "result": "", "total_cost_usd": 0.01, "usage": usage})
    sys.exit(0)
out({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
out({"type": "result", "subtype": "success", "is_error": False, "result": text, "total_cost_usd": 0.0421, "usage": usage})
EOS
chmod +x "$FAKEBIN/claude"

E2E="$WORKDIR/e2e"; mkdir -p "$E2E/state" "$E2E/repo" "$E2E/lessons"
printf -- '- L1. A test or guard is only real once it has been seen to fail.\n' > "$E2E/lessons/LESSONS-INDEX-one.md"
printf 'Review the diff below.\n' > "$E2E/prompt.txt"
printf 'diff --git a/x b/x\n' > "$E2E/input.diff"
export AI_REVIEW_WARM_DIR="$E2E/warm"
unset AI_REVIEW_START_WAIT_SECONDS 2>/dev/null || true
KEY="$(python3 - "$RUNNER" "$E2E/lessons" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ai_review_run", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.start_key("sonnet", m.lessons_block(sys.argv[2])[0]))
EOF
)"

review(){   # $1 = name; runs the runner in the foreground, reviewing a fresh copy of the diff
  cp "$E2E/input.diff" "$E2E/$1.diff"
  PATH="$FAKEBIN:$PATH" python3 "$RUNNER" --state-dir "$E2E/state" --key k --sha "$1" --name "$1" \
    --repo-label repo --branch b --repo-dir "$E2E/repo" --model sonnet --prompt-file "$E2E/prompt.txt" \
    --lessons-dir "$E2E/lessons" --diff-file "$E2E/$1.diff" --deadline "${DEADLINE:-120}" --started "$(date +%s)"
}
body_of(){ cat "$E2E/state/$1.txt" 2>/dev/null; }
lock_free(){ python3 -c 'import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)' "$AI_REVIEW_WARM_DIR/$KEY.lock"; }

# 4a. The flags that ask claude for the stream, each exactly once.
FAKE_MODE=ok review first
args="$(tr '\036' '\n' < "$FAKE_LOG/args")"
python3 - "$FAKE_LOG/args" <<'EOF' && ok || bad "claude is asked for the stream: --output-format stream-json, --verbose and --include-partial-messages, each exactly once"
import sys
a = open(sys.argv[1], encoding="utf-8").read().split("\x1e")
i = [n for n, x in enumerate(a) if x == "--output-format"]
ok = len(i) == 1 and a[i[0] + 1] == "stream-json" and a.count("--verbose") == 1 and a.count("--include-partial-messages") == 1
if not ok:
    print("  arguments: " + " ".join(x for x in a if x.startswith("--")))
sys.exit(0 if ok else 1)
EOF
b="$(body_of first)"
check "the review read from the stream's result is stored" "No issues found." "$b"
check "and counts as a review" "status=ok" "$b"
check "the first review with these lessons went first" "start_order=first" "$b"
check "having waited for nothing" "start_wait=0" "$b"
check "what the review cost is recorded as claude reported it" "cost_usd=0.0421" "$b"
check "and the lessons it read back from the cache" "cache_read_input_tokens=57000" "$b"
check "and what it wrote to it" "cache_creation_input_tokens=0" "$b"
[ -e "$AI_REVIEW_WARM_DIR/$KEY.warm" ] && ok || bad "its reviewer beginning to answer marked these lessons warm"
lock_free && ok || bad "and the turn was let go"

# 4b. The next review within the cache's life starts at once.
FAKE_MODE=ok review second
check "a review started while the lessons are warm starts at once" "start_order=warm" "$(body_of second)"

# 4c. The turn is marked when the reviewer BEGINS answering, not when it ends: the fake holds its
#     answer after the first event, and the turn must be let go while it is still held.
rm -f "$AI_REVIEW_WARM_DIR/$KEY.warm" "$FAKE_LOG/answering"
FAKE_MODE=ok FAKE_HOLD="$WORKDIR/release-c" review third &
held_pid=$!
hang_wait '[ -e "$AI_REVIEW_WARM_DIR/$KEY.warm" ]' 0.05
if [ -e "$AI_REVIEW_WARM_DIR/$KEY.warm" ] && [ ! -e "$E2E/state/third.txt" ]; then ok
else bad "the lessons are marked warm while the reviewer is still answering, not once it ends"; fi
lock_free && ok || bad "and the turn is let go then, so the reviews behind it can start"
: > "$WORKDIR/release-c"
wait "$held_pid"
check "and the held review still finishes" "status=ok" "$(body_of third)"

# 4d. A review whose claude fails before answering marks nothing warm and lets the turn go as it
#     ends, so the review behind it takes over at once instead of waiting out the bound.
rm -f "$AI_REVIEW_WARM_DIR/$KEY.warm"
FAKE_MODE=fail review failed
check "the failed review is recorded as failed" "status=error" "$(body_of failed)"
[ ! -e "$AI_REVIEW_WARM_DIR/$KEY.warm" ] && ok || bad "a review that failed before answering marks nothing warm"
lock_free && ok || bad "and lets the turn go when it ends"

# 4e. A review behind one that never begins answering gives up at its bound and says so in its
#     metadata. The suite holds the turn itself; the suite sets the bound to one second, so the review waits that long
#     whatever the load, and the check is that it waited AT LEAST the bound.
rm -f "$AI_REVIEW_WARM_DIR/$KEY.warm"
exec 9>>"$AI_REVIEW_WARM_DIR/$KEY.lock"
python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' && ok || bad "the suite could take the turn to hold it"
AI_REVIEW_START_WAIT_SECONDS=1 FAKE_MODE=ok review patient
b="$(body_of patient)"
check "a review behind one that never answers gives up waiting" "start_order=gave-up" "$b"
check "after its bound" "start_wait=1" "$b"
check "and still runs" "status=ok" "$b"
exec 9>&-

# 4f. Every way the stream can come back without a review is its own outcome, in its own words.
rm -f "$AI_REVIEW_WARM_DIR/$KEY.warm"
FAKE_MODE=nothing review nothing
b="$(body_of nothing)"; check "no output at all is empty" "status=empty" "$b"; check "saying claude printed nothing" "printed nothing" "$b"
FAKE_MODE=no-result review noresult
b="$(body_of noresult)"; check "events with no result is empty" "status=empty" "$b"; check "saying the stream ended without a result" "ended without a result" "$b"
FAKE_MODE=text FAKE_TEXT="I could not review this." review text
b="$(body_of text)"; check "plain text instead of the stream is not a review" "status=unparsed" "$b"
check "saying no result came back" "no result" "$b"; check "and keeping what it printed" "I could not review this." "$b"
FAKE_MODE=error-result review errored
b="$(body_of errored)"; check "a result claude marks as an error is an error" "status=error" "$b"; check "naming the kind claude gave" "error_max_turns" "$b"
FAKE_MODE=ok FAKE_TEXT="" review blank
b="$(body_of blank)"; check "a result with no text is empty" "status=empty" "$b"; check "saying the answer was empty" "answer was empty" "$b"
check_not "and not that nothing was printed, which is another cause" "printed nothing" "$b"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
