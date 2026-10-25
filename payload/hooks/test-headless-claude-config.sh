#!/usr/bin/env bash
# Tests for the guard that every headless `claude -p` launch decides what config it loads
# (claude-config#538).
#
# A headless run started by a hook inherits the whole global CLAUDE.md and all twelve lessons index
# files unless something says otherwise, and nothing in the call shows it. Measured 2026-09-23: the
# findings harvester took 64,868 input tokens with them and 29,663 without, on every harvest, and
# answered a question about lesson L1001 by quoting it. So each launch either switches the config
# off (CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 on the launch itself) or says why it keeps it or already
# excludes it, with a `# claude-mds-ok: <reason>` comment directly above the statement.
#
# And each launch chooses its prompt cache lifetime (claude-config#1601): on a subscription the
# default writes the prompt to the one hour cache at twice the input price, and in the week to
# 2026-10-23 headless runs wrote 113.4M tokens there and almost never read them back (#1573). So a
# launch carries DISABLE_PROMPT_CACHING=1 or CLAUDE_CODE_PROMPT_CACHE_TTL=<lifetime>, or a
# `# prompt-cache-ok: <reason>` comment saying why the default is right.
#
# Driven against fixtures FIRST, so every outcome is produced rather than merely reachable (L151),
# then against the real tree, because a scan proven only over files this suite wrote says nothing
# about the one anybody runs (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/headless-claude-config.py"
# The installed copy of these hooks has no repository above it, and this suite is about the
# repository (see test-scan-subshell-globals.sh for what walking $HOME instead cost).
# The checkout is found by the one shared test, lib/checkout-root.sh (claude-config#1567, #1663),
# which prints nothing for an installed copy or a copy inside some other repository.
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  echo "test-headless-claude-config: $DIR/.. is not the payload of a claude-config checkout, so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $DIR/.. is not the payload of one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': $2" ;; esac; }
silent_on() { case "$2" in *"$3"*) check "$1" "named '$3': $2" ;; *) check "$1" ok ;; esac; }

[ -f "$SCAN" ] || { echo "FAIL: no scan at $SCAN"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/headless-claude.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

RC=0; OUT=""
run() { OUT="$(python3 "$SCAN" "$FIX" 2>&1)"; RC=$?; }
fresh() { rm -rf "$FIX"/*; }

echo "headless claude config: what it must catch"

# The incident: the harvester's launch, as it stood, with nothing said about config.
fresh
cat > "$FIX/harvest.sh" <<'EOF'
out=$(printf '%s' "$PROMPT" \
  | CLAUDE_DETACHED_RUN=1 with_deadline 60 claude -p --model haiku)
EOF
run
check "an unmarked shell launch fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"
says "and names the file and line" "$OUT" "harvest.sh:2"

# The long option is the same launch.
fresh
printf 'claude --print --model haiku < prompt.txt\n' > "$FIX/long.sh"
run
check "a --print launch is a launch too" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"

# Python builds its argv as a list, where the words sit apart in quotes.
fresh
cat > "$FIX/review.py" <<'EOF'
import subprocess
cmd = ["env", "-u", "CLAUDECODE", "claude", "-p", prompt, "--model", model]
subprocess.run(cmd)
EOF
run
check "an unmarked python argv launch fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"
says "and names it" "$OUT" "review.py:2"

# A marker whose reason is only punctuation is not a reason (L675).
fresh
cat > "$FIX/empty-reason.sh" <<'EOF'
# claude-mds-ok: -
claude -p --model haiku < prompt.txt
EOF
run
check "a marker with no worded reason does not count" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"

# A marker above a DIFFERENT statement does not carry down past code to this one.
fresh
cat > "$FIX/far.sh" <<'EOF'
# claude-mds-ok: this one is measured
first=$(DISABLE_PROMPT_CACHING=1 claude -p --setting-sources local < a.txt)
second=$(DISABLE_PROMPT_CACHING=1 claude -p < b.txt)
EOF
run
check "a marker covers only the statement directly beneath it" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"
says "and the uncovered one is named" "$OUT" "far.sh:3"
silent_on "and the covered one is not" "$OUT" "far.sh:2"

echo "headless claude config: what it must leave alone"

# Switched off on the launch itself.
fresh
cat > "$FIX/off.sh" <<'EOF'
out=$(printf '%s' "$PROMPT" \
  | CLAUDE_DETACHED_RUN=1 CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=1 with_deadline 60 claude -p --model haiku)
EOF
cat > "$FIX/off.py" <<'EOF'
cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_PROMPT_CACHE_TTL=5m", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt]
EOF
run
check "a launch that switches the config off passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# Marked, with the marker above a statement that continues over several lines, and with another
# comment line between the marker and the code.
fresh
cat > "$FIX/marked.sh" <<'EOF'
if true; then
  # claude-mds-ok: --setting-sources local keeps the config out, measured.
  # A second comment line explaining something else.
  # prompt-cache-ok: one request per run, and this caller measured the default as cheapest.
  envelope="$(printf '%s' "$x" | ( cd "$J" && \
    claude -p --model sonnet --output-format json \
      --setting-sources local ) )"
fi
EOF
run
check "a marked multi line launch passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# Talking ABOUT the command is not running it: shell comments, and prose in a python docstring.
fresh
cat > "$FIX/talk.sh" <<'EOF'
# Detached-run guard: a headless `claude -p` launched by an app has nobody to reflect TO.
echo done  # after which claude -p runs elsewhere
EOF
cat > "$FIX/talk.py" <<'EOF'
"""It runs EXACTLY `env -u CLAUDECODE claude -p <prompt> --model <model>` with the diff on stdin."""
EOF
# One real, switched off launch beside them, so a clean exit means they were not counted rather
# than that nothing was found at all.
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=1 claude -p < p.txt\n' > "$FIX/real.sh"
run
check "a comment or docstring naming the command is not a launch" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and only the real launch was counted" "$OUT" "checked 1 headless"

# A test suite's stubs are not launches, and this suite's own fixtures above are exactly that.
fresh
printf 'claude -p --model haiku < prompt.txt\n' > "$FIX/test-something.sh"
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=1 claude -p < p.txt\n' > "$FIX/real.sh"
run
check "a test suite is not scanned" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and its stub was not counted" "$OUT" "checked 1 headless"

# Finding NO launches at all is its own answer, never a pass: a scan that stopped matching would
# otherwise report the tree clean forever (L98).
fresh
printf 'echo hello\n' > "$FIX/nothing.sh"
run
check "a tree with no launches at all is refused, not passed" "$([ "$RC" -eq 3 ] && echo ok || echo "exit $RC")"
says "and says it found none" "$OUT" "no headless"

# A script that cannot be READ could hold a launch, so it is a refusal, never a silent skip (L11).
# Extensionless, because such a file is only recognised by opening it to read its first line.
fresh
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=1 claude -p < p.txt\n' > "$FIX/real.sh"
printf '#!/usr/bin/env bash\nclaude -p < p.txt\n' > "$FIX/sealed"; chmod 000 "$FIX/sealed"
run
chmod 600 "$FIX/sealed"
check "an unreadable script is refused, not skipped" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC: $OUT")"
says "and it is named" "$OUT" "sealed"

echo "headless claude prompt cache lifetime: what it must catch"

CONFIG_MSG="loads the whole global CLAUDE.md"
CACHE_MSG="default prompt cache lifetime"

# The config decided and the cache lifetime not: the shape every launch had before #1573.
fresh
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p --model haiku < p.txt\n' > "$FIX/cache-unset.sh"
run
check "a shell launch that never chooses its cache lifetime fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and names the file and line" "$OUT" "cache-unset.sh:1"
says "and says it is the cache lifetime that is missing" "$OUT" "$CACHE_MSG"
silent_on "and does not blame the config it did decide (L11)" "$OUT" "$CONFIG_MSG"

fresh
cat > "$FIX/cache-unset.py" <<'EOF'
cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt]
EOF
run
check "a python launch that never chooses its cache lifetime fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and names it" "$OUT" "cache-unset.py:1"

# Each marker answers its own question only.
fresh
cat > "$FIX/crossed.sh" <<'EOF'
# claude-mds-ok: --setting-sources local keeps the config out.
DISABLE_PROMPT_CACHING=1 claude -p --setting-sources local < a.txt
# prompt-cache-ok: one request per run, so the lifetime never matters.
CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p < b.txt
# prompt-cache-ok: one request per run, so the lifetime never matters.
claude -p < c.txt
EOF
run
check "a cache marker does not decide the config" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and the launch deciding neither is named for the config" "$OUT" "crossed.sh:6: this headless claude launch loads"
silent_on "but not for the cache it did decide" "$OUT" "crossed.sh:6: this headless claude launch takes"
silent_on "and the two that decide both are not named" "$OUT" "crossed.sh:2"
silent_on "either of them" "$OUT" "crossed.sh:4"

# Values that look like a choice and are not one.
fresh
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=0 claude -p < p.txt\n' > "$FIX/zero.sh"
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_PROMPT_CACHE_TTL= claude -p < p.txt\n' > "$FIX/empty.sh"
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 XDISABLE_PROMPT_CACHING=1 claude -p < p.txt\n' > "$FIX/longer.sh"
cat > "$FIX/dash.sh" <<'EOF'
# prompt-cache-ok: -
CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p < p.txt
EOF
# An item AFTER "claude", "-p" is an argument to claude, not its environment.
cat > "$FIX/after.py" <<'EOF'
cmd = ["env", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p",
       "CLAUDE_CODE_PROMPT_CACHE_TTL=5m"]
EOF
# The same, on the launch line itself, in both languages.
cat > "$FIX/sameline.py" <<'EOF'
cmd = ["env", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", "CLAUDE_CODE_PROMPT_CACHE_TTL=5m"]
EOF
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p DISABLE_PROMPT_CACHING=1 < p.txt\n' > "$FIX/sameline.sh"
run
check "a choice that chooses nothing fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "DISABLE_PROMPT_CACHING=0 leaves caching on" "$OUT" "zero.sh:1"
says "an empty lifetime names none" "$OUT" "empty.sh:1"
says "a longer variable name is a different variable" "$OUT" "longer.sh:1"
says "a marker with no worded reason does not count" "$OUT" "dash.sh:2"
says "a lifetime given as claude's argument is not its environment" "$OUT" "after.py:1"
says "nor when it sits on the launch line in python" "$OUT" "sameline.py:1"
says "nor in shell" "$OUT" "sameline.sh:1"

echo "headless claude prompt cache lifetime: what it must leave alone"

fresh
# Off, on the launch.
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=1 claude -p < p.txt\n' > "$FIX/off.sh"
# A lifetime exported in the subshell on an earlier continued line of the same statement, the shape
# of the push judge (lib/push-changes.sh), and one given by a variable.
cat > "$FIX/subshell.sh" <<'EOF'
# claude-mds-ok: --setting-sources local keeps the global config out.
envelope="$(printf '%s' "$4" | ( export CLAUDE_CODE_PROMPT_CACHE_TTL=5m; cd "$jtmp" && \
  claude -p --model "$1" --output-format json \
    --strict-mcp-config --setting-sources local ) 2>/dev/null )"
CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_PROMPT_CACHE_TTL="$ttl" claude -p < p.txt
EOF
# A python argv whose lifetime sits on the line before the launch words, the shape of the PR
# lessons reviewer (lib/ai-review-run.py), inside a function, under a marker-free comment.
cat > "$FIX/multiline.py" <<'EOF'
def review(prompt):
    # Five minutes: reviews start close together.
    cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_PROMPT_CACHE_TTL=5m",
           "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt,
           "--model", "sonnet"]
    return cmd
EOF
# The default kept on purpose, with its reason.
cat > "$FIX/kept.py" <<'EOF'
# prompt-cache-ok: runs back to back for over an hour, so the one hour lifetime is read back.
cmd = ["env", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt]
EOF
run
check "every way of choosing the lifetime passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and all five launches were counted" "$OUT" "checked 5 headless"

echo "headless claude prompt cache lifetime: planted in the real launches"

# The scan is proven on the real launch sites as they stand, then on the same files with their
# lifetime removed, so it is seen to fail on the shapes it will actually meet (L147, L48). A planting
# that changed nothing would prove nothing (L100), so each is compared with its original first.
plant() {
  local src="$1" name="$2" find="$3"
  cp "$src" "$FIX/$name"
  python3 - "$FIX/$name" "$find" <<'PY'
import sys
path, find = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(find, ""))
PY
}
for spec in \
  "payload/hooks/subagent-issue-harvest.sh|harvest.sh| DISABLE_PROMPT_CACHING=1" \
  "payload/hooks/lib/push-changes.sh|push-changes.sh|export CLAUDE_CODE_PROMPT_CACHE_TTL=5m; " \
  "payload/hooks/lib/ai-review-run.py|ai-review-run.py|\"CLAUDE_CODE_PROMPT_CACHE_TTL=5m\","; do
  IFS='|' read -r rel name find <<<"$spec"
  fresh
  cp "$REPO/$rel" "$FIX/$name"
  run
  check "the real $name passes as it stands" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
  fresh
  plant "$REPO/$rel" "$name" "$find"
  if cmp -s "$REPO/$rel" "$FIX/$name"; then
    check "the lifetime could be removed from the real $name" "'$find' was not in it, so nothing was planted"
    continue
  fi
  run
  check "the real $name with its lifetime removed fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
  says "and it is named" "$OUT" "$name:"
  says "for its cache lifetime" "$OUT" "$CACHE_MSG"
  silent_on "and not its config" "$OUT" "$CONFIG_MSG"
done

echo "headless claude launches found by what runs, not one spelling (claude-config#1681)"

# A launch through a variable program name, its -p in an argument array: claude-sync's /model check.
fresh
cat > "$FIX/model-check.sh" <<'EOF'
find_bin(){ command -v claude 2>/dev/null; }
report(){
  local bin args
  bin="$(find_bin)"
  args=(-p --bare --no-session-persistence)
  out="$(cd / && run_bounded 30 env -u ANTHROPIC_MODEL "$bin" "${args[@]}" 2>/dev/null)" || rc=$?
}
EOF
run
check "a launch through a variable program name with -p in an array fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and names the line that runs it" "$OUT" "model-check.sh:6"
# The program found through a function whose name says what it finds, and -p written out.
fresh
cat > "$FIX/by-function.sh" <<'EOF'
bin="$(sync_claude_bin)"
"$bin" --model haiku -p < prompt.txt
EOF
run
check "a variable set by a function finding claude is a launch" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and it is named" "$OUT" "by-function.sh:2"
# Options before -p, and claude by its path, are the same launch.
fresh
printf 'claude --model haiku -p < prompt.txt\n' > "$FIX/later-p.sh"
printf '"$HOME/.local/bin/claude" -p < prompt.txt\n' > "$FIX/by-path.sh"
cat > "$FIX/continued.sh" <<'EOF'
claude --model haiku \
  --print < prompt.txt
EOF
run
says "an option before -p does not hide the launch" "$OUT" "later-p.sh:1"
says "nor claude run by its path" "$OUT" "by-path.sh:1"
says "nor --print on a continued line" "$OUT" "continued.sh:1"
# The same launches deciding both pass, so the find is not a blanket failure.
fresh
cat > "$FIX/model-check.sh" <<'EOF'
report(){
  local bin args
  bin="$(command -v claude)"
  args=(-p --bare)
  # prompt-cache-ok: nothing is cached, since /model is answered locally and sends no request.
  out="$(env CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 "$bin" "${args[@]}")"
}
EOF
run
check "a variable launch that decides both passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and was counted" "$OUT" "checked 1 headless"
# A program variable never run with -p is not a launch, nor is -p given to another program.
fresh
cat > "$FIX/version.sh" <<'EOF'
bin="$(command -v claude)"
"$bin" --version
mkdir -p "$HOME/.claude/state"
cp -p "$bin" /tmp/x
EOF
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_PROMPT_CACHING=1 claude -p < p.txt\n' > "$FIX/real.sh"
run
check "claude asked its version, and -p to mkdir or cp, are no launch" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and only the real launch was counted" "$OUT" "checked 1 headless"

# Python: an argv is a list the parser builds, so a docstring quoting the two words side by side is
# prose, and a list holding claude then -p anywhere after it is a launch, whatever sits between.
fresh
cat > "$FIX/quoted.py" <<'EOF'
"""Runs ["claude", "-p", prompt] with the config off."""
def run(prompt):
    """The argv is "claude", "-p", then the prompt."""
    note = 'built as "claude", "-p"'
    return ["env", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "DISABLE_PROMPT_CACHING=1", "claude", "-p", prompt]
EOF
run
check "python text quoting the two words is not a launch" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and only the real argv was counted" "$OUT" "checked 1 headless"
fresh
cat > "$FIX/spread.py" <<'EOF'
cmd = ["claude", "--model", model, "-p", prompt]
EOF
cat > "$FIX/variable.py" <<'EOF'
cmd = [claude_bin, "--print", prompt]
EOF
run
says "a python argv with options before -p is a launch" "$OUT" "spread.py:1"
says "and one whose program is a variable naming claude" "$OUT" "variable.py:1"

echo "headless claude config: the real tree"

OUT="$(python3 "$SCAN" "$REPO/payload" "$REPO/tools" "$REPO/claude-sync" 2>&1)"; RC=$?
check "every headless launch in this repository decides its config and its cache lifetime" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
# The seven known launches (the harvester, the judge twice, the PR review, the lesson tagger, and
# claude-sync's /model check twice, found since #1681) must be among what was checked, so a scan that
# silently stopped seeing one of them fails here rather than passing on the others (L63).
count="$(printf '%s' "$OUT" | sed -n 's/.*checked \([0-9][0-9]*\) headless.*/\1/p')"
check "and it saw at least the seven known launches" "$([ "${count:-0}" -ge 7 ] && echo ok || echo "saw ${count:-none}: $OUT")"

# claude-sync's /model check is found as it stands, through "$bin" and its args array, and with its
# cache markers taken out the scan names it (claude-config#1681), so the find is proven on the real
# shape and not only on a fixture written to match it (L48).
fresh
grep -v "# prompt-cache-ok: nothing is cached at any lifetime" "$REPO/claude-sync" > "$FIX/claude-sync"
if cmp -s "$REPO/claude-sync" "$FIX/claude-sync"; then
  check "claude-sync's /model check carries cache markers to remove" "none was removed, so nothing was planted"
else
  OUT="$(python3 "$SCAN" "$FIX/claude-sync" 2>&1)"; RC=$?
  check "claude-sync's /model check without its cache markers fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
  says "and both of its launches are named for the cache" "$OUT" "2 without a decision about the prompt cache lifetime"
  silent_on "and neither for its config, which is switched off on the launch" "$OUT" "$CONFIG_MSG"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
