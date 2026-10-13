#!/usr/bin/env bash
# Tests for time-push-gates.sh, which times every gate a `git push` waits on (claude-config#523).
#
# Four hooks declare timeouts of 30, 120, 180 and 300 seconds, which the settings SET and are not
# measurements of anything, and only one gate had ever been timed, so the real cost of pushing was
# a sum of guesses. A gate's own guards are an untimed
# pipeline (L300), and a declared timeout is evidence of what somebody feared, not of what it costs.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$DIR/time-push-gates.sh"
pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-time-gates.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-time-push-gates: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A fixture config: two quick gates, one that overruns its declared timeout, and one that is not
# run for Bash at all. Every hook is a stub, so this suite pays no real gate's cost (L143).
HOME_DIR="$TMPROOT/home"
mkdir -p "$HOME_DIR/hooks"
mk(){ printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$2" > "$HOME_DIR/hooks/$1"; chmod +x "$HOME_DIR/hooks/$1"; }
mk quick.sh 'exit 0'
mk speaks.sh 'echo "a line"; exit 0'
mk slow.sh 'sleep 30; exit 0'
mk untimed.sh 'exit 0'   # no declared timeout: bash read drops a leading empty field on a tab
mk writes.sh 'exit 0'
cat > "$HOME_DIR/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/quick.sh", "timeout": 30 },
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/speaks.sh", "timeout": 60 },
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/slow.sh", "timeout": 1 },
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/untimed.sh" }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [ { "type": "command", "command": "__CLAUDE_HOME__/hooks/writes.sh" } ]
      }
    ]
  }
}
JSON

out="$(GATE_TIMING_HOME="$HOME_DIR" bash "$T" --repo "$TMPROOT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "it runs and reports" ok || check "it runs and reports" "rc=$rc out=$out"
# untimed.sh is in this list deliberately: a gate declaring no timeout was dropped from the table
# entirely, because a tab is IFS whitespace and bash's read collapses the leading empty field, so
# the real rtk-rewrite.sh was never timed and nothing said so (L98).
for want in quick.sh speaks.sh slow.sh untimed.sh; do
  case "$out" in *"$want"*) check "it times $want" ok ;; *) check "it times $want" "out=$out" ;; esac
done
case "$out" in
  *writes.sh*) check "a hook that is not run for Bash is left out" "out=$out" ;;
  *) check "a hook that is not run for Bash is left out" ok ;;
esac
# The overrunning gate is KILLED at its declared timeout and said to have been, never reported as a
# duration somebody could mistake for a measurement (L11).
case "$out" in
  *"slow.sh"*"timed out"*|*"slow.sh"*"KILLED"*) check "a gate past its declared timeout is killed and named as such" ok ;;
  *) check "a gate past its declared timeout is killed and named as such" "out=$out" ;;
esac
# Claude Code runs every matching hook in PARALLEL ("All matching hooks run in parallel", the hooks
# reference), so a push waits for the slowest gate, not for their sum, and the table summed them
# while running them one after another (claude-config#1122). The closing line is the wall clock.
case "$out" in
  *"WALL CLOCK"*) check "it reports the wall clock a push waits, not a sum" ok ;;
  *) check "it reports the wall clock a push waits, not a sum" "out=$out" ;;
esac
_wall_s="$(printf '%s\n' "$out" | awk '/WALL CLOCK/ { print $1 + 0 }')"
_max_s="$(printf '%s\n' "$out" | awk '/[.]sh/ && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }')"
awk -v w="${_wall_s:-0}" -v m="${_max_s:-0}" 'BEGIN { exit !(w >= m && w > 0) }' \
  && check "the wall clock is no shorter than the slowest gate" ok \
  || check "the wall clock is no shorter than the slowest gate" "wall=$_wall_s slowest=$_max_s out=$out"

# And it RUNS them in parallel, as Claude Code does, or the times it reports are of a push nobody
# makes: gates compete for the machine when they run together. Two fixture gates each wait for the
# other to have started, a rendezvous, so run one after another the first can only be killed at its
# declared bound, and run together both pass at once. Waited on as a condition, never a sleep (L290).
PAR_HOME="$TMPROOT/par-home"; mkdir -p "$PAR_HOME/hooks" "$TMPROOT/rv"
mkpar(){ printf '#!/usr/bin/env bash\ncat >/dev/null\ntouch "%s/%s"\ni=0\nwhile [ ! -e "%s/%s" ]; do i=$((i + 1)); [ "$i" -gt 400 ] && exit 1; sleep 0.05; done\nexit 0\n' \
  "$TMPROOT/rv" "$2" "$TMPROOT/rv" "$3" > "$PAR_HOME/hooks/$1"; chmod +x "$PAR_HOME/hooks/$1"; }
mkpar ping.sh ping pong
mkpar pong.sh pong ping
cat > "$PAR_HOME/settings.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "__CLAUDE_HOME__/hooks/ping.sh", "timeout": 3 },
  { "type": "command", "command": "__CLAUDE_HOME__/hooks/pong.sh", "timeout": 3 }
] } ] } }
JSON
par="$(GATE_TIMING_HOME="$PAR_HOME" bash "$T" --repo "$TMPROOT" 2>&1)"
case "$par" in
  *KILLED*) check "the gates run in parallel, as Claude Code runs them" "one was killed waiting for the other: $par" ;;
  *) [ "$(printf '%s\n' "$par" | awk '/(ping|pong)[.]sh/ && $2 == "0"' | grep -c .)" = "2" ] \
       && check "the gates run in parallel, as Claude Code runs them" ok \
       || check "the gates run in parallel, as Claude Code runs them" "out=$par" ;;
esac
# Every duration is a real reading: the fixture's slow gate must be the slowest of the three.
_slow_s="$(printf '%s\n' "$out" | awk '/slow[.]sh/ { print $1 + 0 }')"
_quick_s="$(printf '%s\n' "$out" | awk '/quick[.]sh/ { print $1 + 0 }')"
awk -v a="${_slow_s:-0}" -v b="${_quick_s:-0}" 'BEGIN { exit !(a > b) }' \
  && check "the durations are measured, not printed from the config" ok \
  || check "the durations are measured, not printed from the config" "slow=$_slow_s quick=$_quick_s"

# --list names the gates a push waits on, with what each declares, and runs none of them: the one
# reading of the settings both the timing and the README's count come from (claude-config#1066).
mk marks.sh 'touch "$(dirname "$0")/../ran"'
python3 - "$HOME_DIR/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["hooks"]["PreToolUse"][0]["hooks"].append({"type": "command", "command": "__CLAUDE_HOME__/hooks/marks.sh", "timeout": 5})
json.dump(d, open(p, "w"))
PY
rm -f "$HOME_DIR/ran"
listed="$(GATE_TIMING_HOME="$HOME_DIR" bash "$T" --list 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "--list runs" ok || check "--list runs" "rc=$rc out=$listed"
[ "$(printf '%s\n' "$listed" | awk -F '\t' '{ print $2 }' | tr '\n' ' ')" = "quick.sh speaks.sh slow.sh untimed.sh marks.sh " ] \
  && check "--list names every Bash gate in order, and nothing else" ok \
  || check "--list names every Bash gate in order, and nothing else" "out=$listed"
[ "$(printf '%s\n' "$listed" | awk -F '\t' '{ print $1 }' | tr '\n' ' ')" = "30 60 1 - 5 " ] \
  && check "--list gives each gate's declared timeout" ok || check "--list gives each gate's declared timeout" "out=$listed"
[ ! -e "$HOME_DIR/ran" ] && check "--list runs no gate" ok || check "--list runs no gate" "marks.sh ran"

# The README's count of the hooks a push waits on, derived from the settings the payload installs
# (claude-config#1066). The count was written by hand, "Seventeen" and then "Eighteen", and went on
# being believed while hooks were added beside it (L244), so the next hook added fails this suite
# until the sentence says how many there are now.
REPO_ROOT="$(cd "$DIR/.." && pwd)"
REAL_HOME="$TMPROOT/real-home"; mkdir -p "$REAL_HOME"
cp "$REPO_ROOT/payload/settings.hooks.json" "$REAL_HOME/settings.json"
real="$(GATE_TIMING_HOME="$REAL_HOME" bash "$T" --list --command "git push" 2>&1)"; rc=$?
n="$(printf '%s\n' "$real" | grep -c .)"
[ "$rc" -eq 0 ] && [ "$n" -gt 0 ] && check "the payload's push gates are listed" ok \
  || check "the payload's push gates are listed" "rc=$rc out=$real"
lo="$(printf '%s\n' "$real" | awk -F '\t' '$1 ~ /^[0-9]+$/ && (m == "" || $1 + 0 < m) { m = $1 + 0 } END { print m }')"
hi="$(printf '%s\n' "$real" | awk -F '\t' '$1 ~ /^[0-9]+$/ && $1 + 0 > m { m = $1 + 0 } END { print m }')"
word="$(python3 -c '
import sys
n = int(sys.argv[1])
ones = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
tens = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
w = ones[n] if n < 20 else tens[n // 10] + ("" if n % 10 == 0 else "-" + ones[n % 10])
print(w[0].upper() + w[1:])' "$n")"
want="$word PreToolUse hooks fire on a \`git push\` here, declaring timeouts of $lo to $hi seconds"
if grep -qF "$want" "$REPO_ROOT/README.md"; then check "the README counts the hooks a push waits on" ok
else check "the README counts the hooks a push waits on" "wanted the README to say: $want. It says: $(grep -o '[A-Z][a-z-]* PreToolUse hooks fire on a .git push. here, declaring timeouts of [0-9]* to [0-9]* seconds' "$REPO_ROOT/README.md")"; fi

# A settings file it cannot read is a refusal, never an empty table that reads as no gates (L98).
out2="$(GATE_TIMING_HOME="$TMPROOT/nowhere" bash "$T" --repo "$TMPROOT" 2>&1)"; rc2=$?
[ "$rc2" -ne 0 ] && case "$out2" in *"could not read"*) true ;; *) false ;; esac \
  && check "a settings file it cannot read is refused by name" ok \
  || check "a settings file it cannot read is refused by name" "rc=$rc2 out=$out2"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
