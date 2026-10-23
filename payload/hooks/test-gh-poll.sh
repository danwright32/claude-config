#!/usr/bin/env bash
# Tests for lib/gh-poll.sh, the one polling policy every loop here that asks GitHub follows
# (claude-config#1482). On 2026-10-22 GitHub's secondary (burst) limit refused every session on the
# shared account for about 40 minutes while several agents polled at once. The policy is: a wait
# between looks that grows while nothing changes and starts again at the base on any change, a pause
# on a rate limit answer that honours Retry-After or the reset time, and a cap on looks a minute per
# session that every loop in the session shares through one small state file.
#
# Every clock here is passed in, so nothing waits on a real one (L524, L290). Two loops in one
# session are two separate bash processes, as two helpers run by two agents are.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/gh-poll.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

export GH_POLL_STATE_DIR="$WORKDIR/state"
export GH_POLL_LOCK_SLEEP=true
unset GH_POLL_PER_MINUTE GH_POLL_RATE_FIRST_SECONDS GH_POLL_RATE_MAX_SECONDS 2>/dev/null || true

# One loop's call into the library, in a process of its own: $1 = session, then the shell to run.
loop(){ local s="$1"; shift; CLAUDE_CODE_SESSION_ID="$s" bash -c ". '$LIB' || exit 99; $*" 2>&1; }

if [ ! -f "$LIB" ]; then
  bad "#1482 lib/gh-poll.sh exists"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

# =================================================================================================
# 1. The interval grows on each unchanged look, up to its ceiling, and starts again at the base on
#    any change, so a merge is never kept waiting by a long quiet spell before it.
# =================================================================================================
out="$(loop s1 'i=60; for k in 1 2 3 4; do i=$(ghp_next_interval "$i" 60 180 0); printf "%s " "$i"; done')"
check_eq "#1482 an unchanged look doubles the wait, up to the ceiling" "120 180 180 180 " "$out"
check_eq "#1482 a change starts it again at the base" "60" "$(loop s1 'ghp_next_interval 180 60 180 1')"
check_eq "#1482 a ceiling under the base is the base: no growth" "30" "$(loop s1 'ghp_next_interval 30 30 10 0')"
check_eq "#1482 a wait under the base is raised to it" "60" "$(loop s1 'ghp_next_interval 5 60 180 1')"

# =================================================================================================
# 2. What counts as a rate limit answer: read from gh's own error text, in this one place (L35).
# =================================================================================================
for t in "gh: API rate limit exceeded for user ID 241846707. (HTTP 403)" \
         "GraphQL: API rate limit already exceeded for user ID 241846707." \
         "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)" \
         "gh: You have triggered an abuse detection mechanism. (HTTP 403)" \
         "HTTP 429: Too Many Requests"; do
  check_eq "#1482 a rate limit answer: $t" "yes" "$(loop s1 "ghp_rate_limited '$t' && echo yes || echo no")"
done
for t in "gh: Resource not accessible by integration (HTTP 403)" "gh: Not Found (HTTP 404)" \
         "Get \"https://api.github.com/\": net/http: TLS handshake timeout" "" "the rate limit page says nothing here"; do
  check_eq "#1482 not a rate limit answer: '$t'" "no" "$(loop s1 "ghp_rate_limited '$t' && echo yes || echo no")"
done

# =================================================================================================
# 3. Two loops in one session share the cap on looks a minute; another session has its own.
# =================================================================================================
rm -rf "$GH_POLL_STATE_DIR"
export GH_POLL_PER_MINUTE=4
check_eq "#1482 loop A takes a look" "took" "$(loop s1 'ghp_take 1000 && echo took')"
check_eq "#1482 loop B, the same session, takes one" "took" "$(loop s1 'ghp_take 1010 && echo took')"
check_eq "#1482 loop A again" "took" "$(loop s1 'ghp_take 1020 && echo took')"
check_eq "#1482 loop B again: four in the minute" "took" "$(loop s1 'ghp_take 1030 && echo took')"
out="$(loop s1 'ghp_take 1040 && echo took || echo "wait $GHP_WHY $GHP_WAIT $GHP_CAP"')"
check_eq "#1482 a fifth look in the same minute waits for the oldest to age out, from either loop" "wait cap 20 4" "$out"
check_eq "#1482 a loop in another session is not held by this one's looks" "took" "$(loop s2 'ghp_take 1040 && echo took')"
check_eq "#1482 once the first look is a minute old the session looks again" "took" "$(loop s1 'ghp_take 1060 && echo took')"
check_eq "#1482 the cap counts only the last minute" "4" "$(wc -l < "$GH_POLL_STATE_DIR/s1/polls" | tr -d ' ')"

# No session (a helper run by hand): its own key, never a crash, never another session's budget.
out="$(env -u CLAUDE_CODE_SESSION_ID bash -c ". '$LIB'; ghp_session_key")"
check_eq "#1482 with no session the key is no-session" "no-session" "$out"
check_eq "#1482 a session id is kept to a file name's characters" "a_b_c" "$(loop 'a/b c' 'ghp_session_key')"

# A lock left by a loop that died is broken, never waited on for ever.
rm -rf "$GH_POLL_STATE_DIR"; mkdir -p "$GH_POLL_STATE_DIR/s3/.lock"
( exit 0 ) & dead=$!; wait "$dead"
printf '%s' "$dead" > "$GH_POLL_STATE_DIR/s3/.lock/pid"
check_eq "#1482 a dead loop's lock is broken" "took" "$(loop s3 'ghp_take 1000 && echo took')"

# =================================================================================================
# 4. A rate limit answer pauses every loop in the session, for as long as GitHub says.
# =================================================================================================
LIMITED="gh: API rate limit exceeded for user ID 241846707. (HTTP 403)"
SECONDARY="gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)"
probe_file="$WORKDIR/probe"
cat > "$WORKDIR/probe.sh" <<EOS
#!/usr/bin/env bash
cat "$probe_file"
EOS
chmod +x "$WORKDIR/probe.sh"
probe_ok(){   # $1 = graphql remaining, $2 = graphql reset, $3 = core remaining, $4 = core reset
  printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"resources":{"core":{"limit":5000,"remaining":%s,"reset":%s},"graphql":{"limit":5000,"remaining":%s,"reset":%s}}}\n' "$3" "$4" "$1" "$2" > "$probe_file"
}

# The reset time: the GraphQL allowance is spent until 1300.
rm -rf "$GH_POLL_STATE_DIR"; probe_ok 0 1300 4989 4000
out="$(loop s1 "ghp_rate_pause '$LIMITED' 1000 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT|\$GHP_SAID\"")"
check "#1482 a spent allowance pauses until GitHub's reset time" "300|" "$out"
check "#1482 and says it is the reset time, naming the allowance" "graphql" "$out"
out="$(loop s1 'ghp_take 1100 && echo took || echo "wait $GHP_WHY $GHP_WAIT"')"
check_eq "#1482 another loop in the session is paused too, until the same reset" "wait pause 200" "$out"
out="$(loop s1 'ghp_take 1100 || echo "$GHP_SAID"')"
check "#1482 and it can say why" "graphql" "$out"
check_eq "#1482 at the reset the session looks again" "took" "$(loop s1 'ghp_take 1300 && echo took')"

# Retry-After: GitHub's own answer to the probe names the wait.
rm -rf "$GH_POLL_STATE_DIR"
printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 90\r\nContent-Type: application/json\r\n\r\n{"message":"You have exceeded a secondary rate limit."}\n' > "$probe_file"
out="$(loop s1 "ghp_rate_pause '$SECONDARY' 1000 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT|\$GHP_SAID\"")"
check "#1482 Retry-After is honoured" "90|" "$out"
check "#1482 and said" "Retry-After" "$out"
# Retry-After carried in the answer itself is honoured without a probe.
rm -rf "$GH_POLL_STATE_DIR"; : > "$probe_file"
out="$(loop s1 "ghp_rate_pause 'HTTP 429 Too Many Requests
Retry-After: 45' 1000 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT\"")"
check_eq "#1482 Retry-After in GitHub's own answer is honoured" "45" "$out"

# A secondary limit that names no time: a minute, then twice as long each time it refuses again,
# up to the ceiling, and back to a minute once a look is answered.
rm -rf "$GH_POLL_STATE_DIR"; probe_ok 4900 4000 4989 4000
export GH_POLL_RATE_MAX_SECONDS=200
out="$(loop s1 "ghp_rate_pause '$SECONDARY' 1000 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT|\$GHP_SAID\"")"
check "#1482 a burst limit naming no time waits a minute first" "60|" "$out"
check "#1482 and says it named no time" "named no time" "$out"
check_eq "#1482 refused again: twice as long" "120" "$(loop s1 "ghp_rate_pause '$SECONDARY' 1060 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT\"")"
check_eq "#1482 and again, up to the ceiling" "200" "$(loop s1 "ghp_rate_pause '$SECONDARY' 1180 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT\"")"
loop s1 'ghp_answered' >/dev/null
check_eq "#1482 an answered look starts the next pause at a minute again" "60" "$(loop s1 "ghp_rate_pause '$SECONDARY' 1400 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT\"")"
unset GH_POLL_RATE_MAX_SECONDS

# A probe that cannot be read is no reason to look sooner: the burst wait applies.
rm -rf "$GH_POLL_STATE_DIR"; printf 'gh: connection reset by peer\n' > "$probe_file"
check_eq "#1482 an unreadable probe falls back to the burst wait" "60" "$(loop s1 "ghp_rate_pause '$LIMITED' 1000 '$WORKDIR/probe.sh'; echo \"\$GHP_WAIT\"")"

# A pause is never shortened by a later, shorter one.
rm -rf "$GH_POLL_STATE_DIR"; probe_ok 0 1300 4989 4000
loop s1 "ghp_rate_pause '$LIMITED' 1000 '$WORKDIR/probe.sh'" >/dev/null
printf 'HTTP/2.0 403 Forbidden\r\nRetry-After: 10\r\n\r\n{}\n' > "$probe_file"
loop s1 "ghp_rate_pause '$SECONDARY' 1010 '$WORKDIR/probe.sh'" >/dev/null
check_eq "#1482 a later shorter pause keeps the longer one" "wait 290" "$(loop s1 'ghp_take 1010 || echo "wait $GHP_WAIT"')"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
