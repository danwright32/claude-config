#!/usr/bin/env bash
# Tests for pr-review-gate.sh's refusal of a shell command that can write the lessons review's read
# records (claude-config#1700, #1719), judged by lib/review-record-writes.py since claude-config#2050:
# a command that only NAMES them is let through, every command that can WRITE them is still refused.
#
# The two let through are the real commands refused on 2026-11-01, copied byte for byte from the
# transcripts (L48): the #2040 builder's python edit of test-pr-review.sh, whose text names the key
# issuing function in the loop it rewrites, and the main session's `gh pr diff | grep` for the read
# keys. Every shape refused is written without a ~/.claude path, so it is the rule it names that
# refuses it, never the records' home folder (which test-pr-review.sh and test-merge-when-ready.sh
# cover, with the shapes #1700 and #1719 were written for).
#
# PR_REVIEW_GATE_UNDER_TEST points this at another copy of the gate, to see these cases fail against
# the gate before #2050 or against a judge with one rule taken out (L1).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${PR_REVIEW_GATE_UNDER_TEST:-$DIR/pr-review-gate.sh}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
# Nothing here may reach Dan's reviews: the gate only judges, but a merge it took for one would read
# the state folder (L2).
export AI_REVIEW_STATE_DIR="$WORKDIR/state" MWR_PHASE_DIR="$WORKDIR/phases"
mkdir -p "$AI_REVIEW_STATE_DIR" "$MWR_PHASE_DIR"

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

if [ ! -f "$GATE" ]; then
  echo "FAIL: $GATE is missing, so every case below would read as let through"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

fire(){ # fire <command>: the gate's output, with its exit code as the last line
  local out rc
  out="$(python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$WORKDIR" "$1" \
    | bash "$GATE" 2>&1)"; rc=$?
  printf '%s\n%s' "$out" "$rc"
}
REFUSAL="only the lessons review's own gates write"
allowed(){ # allowed <label> <command>
  local got rc out
  got="$(fire "$2")"; rc="${got##*$'\n'}"; out="${got%$'\n'*}"
  if [ "$rc" = 0 ] && [[ "$out" != *"Refused"* ]]; then ok; else bad "$1 is let through (exit $rc): ${out:0:600}"; fi
}
refused(){ # refused <label> <command>
  local got rc out
  got="$(fire "$2")"; rc="${got##*$'\n'}"; out="${got%$'\n'*}"
  if [ "$rc" = 2 ] && [[ "$out" == *"$REFUSAL"* ]]; then ok; else bad "$1 is refused (exit $rc): ${out:0:600}"; fi
}

# The judge loads lib/shell-words.py by its path, which leaves a bytecode cache beside it unless told
# not to, and lib/ is installed and synced (#1017). Judged on the gate under test's own lib/, first,
# before any other case has run the judge and left one to compare against.
GATE_LIB="$(dirname "$GATE")/lib"
pyc_before="$(ls -A "$GATE_LIB/__pycache__" 2>/dev/null)"
fire "grep -n ar_readkeys_issue payload/hooks/test-pr-review.sh" >/dev/null
pyc_after="$(ls -A "$GATE_LIB/__pycache__" 2>/dev/null)"
[ "$pyc_after" = "$pyc_before" ] && ok || bad "#2050 judging a command leaves no bytecode cache in the hooks' lib/ (before '$pyc_before', after '$pyc_after')"

# ---- let through: the real commands refused on 2026-11-01 ----
# Held in text files beside this suite, not in a heredoc here, so the pipe into head in the second
# is never read as this suite's own pipeline (test-pipefail-shortcircuit.sh scans every .sh).
FIXTURES="$DIR/pr-review-gate-fixtures"
for f in 2040-builder-edit.txt 2049-diff-grep.txt; do
  [ -s "$FIXTURES/$f" ] || { echo "FAIL: $FIXTURES/$f is missing or empty"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
done
IFS= read -r -d '' FIX_2040 < "$FIXTURES/2040-builder-edit.txt" || true
allowed "#2050 the #2040 builder's python edit of test-pr-review.sh, naming the key issuing function in the text it writes" "$FIX_2040"
IFS= read -r -d '' FIX_DIFF_GREP < "$FIXTURES/2049-diff-grep.txt" || true
allowed "#2050 the main session's read only gh pr diff | grep for the read keys" "$FIX_DIFF_GREP"
allowed "#2050 a grep of a file for a function's name" "grep -n ar_readkeys_issue payload/hooks/test-pr-review.sh"
allowed "#2050 a grep of a pipe for a function's name" "gh pr diff 2049 | grep -n ar_helper_key_record"
allowed "#2050 a name in a comment only" "ls payload/hooks # ar_helper_key_record lives in lib"

# ---- refused: calling a function, however it is reached ----
refused "#2050 a function run as a command" "ar__helper_key_mac"
refused "#2050 the library sourced by a relative path and a function called" "source payload/hooks/lib/ai-review-common.sh && ar_helper_key_record 5eed5eed"
refused "#2050 the loop's line itself, run through bash -c" "bash -c '. \"\$1\" && ar_readkeys_issue \"\$2\"' _ payload/hooks/lib/ai-review-common.sh x.txt"
refused "#2050 a function called in a command substitution" "x=\"\$(ar_readkeys_issue x.txt)\""
refused "#2050 a function called in a process substitution" "cat <(ar_readkeys_issue x.txt)"
refused "#2050 a function named in a variable then called" "fn=ar_helper_key_record; . payload/hooks/lib/ai-review-common.sh; \"\$fn\" 5eed5eed"
refused "#2050 a function run by eval" "eval 'ar_helper_key_record 5eed5eed'"
refused "#2050 a function run by xargs" "xargs ar_helper_key_record < keys.txt"
refused "#2050 a function handed to a script run by its path" "./scripts/forge.sh ar_helper_key_record"
refused "#2050 a function handed to python -c" "python3 -c 'import os; os.system(\"ar_helper_key_record 5eed5eed\")'"
refused "#2050 a function run as git's pager, on a git log that only searches" "git -c core.pager='. payload/hooks/lib/ai-review-common.sh; ar_helper_key_record 5eed5eed; cat' log -S ar_helper_key_record"
refused "#2050 a function's name searched by rg, whose --pre runs a command" "rg --pre ./run.sh ar_helper_key_record payload"
refused "#2050 a function written into a script by sed" "sed -i '' 's/^true\$/ar_helper_key_record 5eed5eed/' run.sh"
refused "#2050 a function written into a shell startup file" "echo 'ar_helper_key_record 5eed5eed' >> ~/.zshrc"
refused "#2050 the library's pause variable set on a merge" "AR_HELPER_SECRET_PAUSE=1 gh pr merge 7 --squash"
refused "#2050 a command hidden after a 0x1f, which the gate used to cut the command at" "true"$'\x1f'"; ar_helper_key_record 5eed5eed"

# The merge gate's own reading cut at the first 0x1f too, so a merge after one was no merge to it.
# gh here is a stand in that fails, so the gate refuses for want of the pull request and never asks
# GitHub (L2); before the fix it let the command through without asking at all.
mkdir -p "$WORKDIR/bin"; printf '#!/bin/sh\nexit 1\n' > "$WORKDIR/bin/gh"; chmod +x "$WORKDIR/bin/gh"
got="$(PATH="$WORKDIR/bin:$PATH" fire "true"$'\x1f'"; gh pr merge 7 --squash")"; rc="${got##*$'\n'}"
[ "$rc" = 2 ] && [[ "$got" != *"$REFUSAL"* ]] && ok \
  || bad "#2050 a merge written after a 0x1f is still judged as a merge (exit $rc): ${got:0:600}"

# ---- refused: the folder, the secret or a read keys file named to anything but a grep of a pipe ----
refused "#2050 a read keys file written by a relative path" "printf '%s\\n' 0 >> 1-pr-abc.txt.readkeys-1"
refused "#2050 a record touched into the folder" "touch helper-keys/0123abcd"
refused "#2050 a record copied into the folder, in capitals" "cp /tmp/k HELPER-KEYS/0123abcd"
refused "#2050 a record moved into the folder" "mv /tmp/k helper-keys/0123abcd"
refused "#2050 the secret read by a relative path" "cat helper-keys.secret"
refused "#2050 the secret named to a grep of a pipe as a file" "printf x | grep . helper-keys.secret"
refused "#2050 the secret named to a grep through -e" "printf x | grep -e . helper-keys.secret"
refused "#2050 a grep searching a folder for the read keys" "grep -rn readkeys ."

# ---- refused: a heredoc that can run what it holds ----
IFS= read -r -d '' PY_SPAWN <<'CMD' || true
python3 - <<'EOF'
import subprocess
subprocess.run(["bash", "-c", ". payload/hooks/lib/ai-review-common.sh; ar_helper_key_record 5eed5eed"])
EOF
CMD
refused "#2050 python fed a heredoc that starts a process calling a function" "${PY_SPAWN%$'\n'}"
IFS= read -r -d '' PY_OPEN <<'CMD' || true
python3 - <<'EOF'
open("helper-keys/0123abcd", "w").close()
EOF
CMD
refused "#2050 python fed a heredoc that opens a path in the folder" "${PY_OPEN%$'\n'}"
IFS= read -r -d '' TO_BASH <<'CMD' || true
cat <<'EOF' | bash
. payload/hooks/lib/ai-review-common.sh
ar_helper_key_record 5eed5eed
EOF
CMD
refused "#2050 a heredoc piped to bash" "${TO_BASH%$'\n'}"
IFS= read -r -d '' UNQUOTED <<'CMD' || true
cat <<EOF
$(ar_readkeys_issue x.txt)
EOF
CMD
refused "#2050 an unquoted heredoc, whose substitution runs" "${UNQUOTED%$'\n'}"
IFS= read -r -d '' TO_HOOK <<'CMD' || true
cat >> payload/../../.claude/hooks/pr-review-gate.sh <<'EOF'
ar_helper_key_record "$k"
EOF
CMD
refused "#2050 a heredoc appending a call to an installed hook" "${TO_HOOK%$'\n'}"

IFS= read -r -d '' TO_PERL <<'CMD' || true
perl <<'EOF'
system("ar_helper_key_record 5eed5eed");
EOF
CMD
refused "#2050 a quoted heredoc fed to perl, which can run what it holds" "${TO_PERL%$'\n'}"
IFS= read -r -d '' TEE_SUB <<'CMD' || true
tee >(bash) <<'EOF'
ar_helper_key_record 5eed5eed
EOF
CMD
refused "#2050 a quoted heredoc tee hands to a shell in a process substitution" "${TEE_SUB%$'\n'}"

# ---- refused: what this reading cannot see into, and the records' own folder ----
refused "#2050 a function's name handed to a wrapper, whose commands run elsewhere" "find . -name '*.sh' -exec grep -l ar_helper_key_record {} +"
refused "#2050 a function's name handed to bash -c, even for a grep" "bash -c 'grep -n ar_readkeys_issue f'"
refused "#2050 a function's name in arithmetic, which expands what a variable holds" "echo \$((ar_helper_key_record))"
refused "#2050 a name a runner takes as its option value, which no rule reads" "env -u AR_HELPER_SECRET_PAUSE gh pr merge 7"
refused "#2050 a grep of the records' own folder, whose -e . would print the secret" "grep -rn -e ar_readkeys_issue -e . \"\$AI_REVIEW_STATE_DIR\""

# ---- the refusal says which rule refused it, what to do, and to report a way round it ----
says(){ # says <label> <command> <text>
  local got; got="$(fire "$2")"
  [[ "$got" == *"$3"* ]] && ok || bad "$1: expected '$3' in: ${got:0:600}"
}
says "#2050 a function run as a command is named as run" "ar__helper_key_mac" "runs ar__helper_key_mac, one of the functions"
says "#2050 a variable set to a function's name says so" "x=ar_helper_key_record" "sets a variable named for those records"
says "#2050 a quote that never closes says so" "echo \"ar_helper_key_record" "never closes"
got="$(fire "touch helper-keys/0123abcd")"
[[ "$got" == *"says so in its hand back"* ]] && ok \
  || bad "#2050 the refusal tells a builder that goes on another way to say so in its hand back: ${got:0:600}"
[[ "$got" == *"as an argument to touch"* ]] && ok \
  || bad "#2050 the refusal says which rule refused it: ${got:0:600}"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
