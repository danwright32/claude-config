#!/usr/bin/env bash
# `claude-sync status` says when the installed Claude Code no longer accepts the option the lessons
# review hands the lessons in (claude-config#2982).
#
# Since #2975 the review runner (payload/hooks/lib/ai-review-run.py) passes the lessons with
# --append-system-prompt-file, an option Claude Code 2.1.325 accepts but does not list in --help. It
# was confirmed only by its errors: a missing file gives "Append system prompt file not found", a
# misspelt option "unknown option". If an update drops it, every review stops starting. So status
# asks the installed claude once a day, with a file that does not exist and /model as the prompt:
# the missing file error is the answer that the option is still known, and no model is called
# either way (/model is answered locally even if the file check ever moved).
#
# The stub below speaks each answer 2.1.325 gives (L2: no real Claude Code), logs every call, and
# records whether the file it was handed existed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-sync"
. "$HERE/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ grep -qF -- "$2" <<< "$1"; }
lacks(){ ! grep -qF -- "$2" <<< "$1"; }
probes(){ grep -c -- '--append-system-prompt-file' "$LOG" 2>/dev/null || true; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-option-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# Everything else status reads from the machine, pointed inside WORK (as test-status-fixture-home.sh).
export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_GH="$WORK/no-such-gh"
export SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1
export SYNC_LAUNCHAGENTS="$WORK/launchagents"; mkdir -p "$SYNC_LAUNCHAGENTS"
export SYNC_CLONE_REGISTRY="$WORK/clone-register"; : > "$SYNC_CLONE_REGISTRY"
export LOG="$WORK/calls"; : > "$LOG"
REPO="$WORK/repo"; mkdir -p "$REPO/payload"

FAKE="$WORK/bin/claude"; mkdir -p "$WORK/bin"
write_fake(){
  cat > "$FAKE" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$LOG"
[ "${1:-}" = --version ] && { echo "${FAKE_V:-2.1.325} (Claude Code)"; exit 0; }
prev=""; f=""
for a in "$@"; do [ "$prev" = --append-system-prompt-file ] && f="$a"; prev="$a"; done
[ -n "$f" ] && { if [ -e "$f" ]; then echo "handed an existing file" >> "$LOG"; else echo "handed a missing file" >> "$LOG"; fi; }
case "${FAKE_MODE:-accept}" in
  accept) [ -n "$f" ] && [ ! -e "$f" ] && { echo "Error: Append system prompt file not found: $f" >&2; exit 1; } ;;
  refuse) [ -n "$f" ] && { echo "error: unknown option '--append-system-prompt-file'" >&2; exit 1; } ;;
  hang) sleep 30 ;;
esac
exit 0
STUB
  chmod +x "$FAKE"
}
write_fake

status_in(){   # $1 = CLAUDE_HOME, further arguments are extra environment -> status output
  local home="$1"; shift
  mkdir -p "$home"
  env "$@" CLAUDE_HOME="$home" SYNC_REPO="$REPO" bash "$SCRIPT" status 2>&1
}

# ---- 1. control: a Claude Code that still knows the option, so nothing is said ----
H1="$WORK/home-accept"
out1="$(status_in "$H1" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=accept)"; rc1=$?
check "status finishes cleanly" [ "$rc1" -eq 0 ]
check "the installed claude was asked about the option" [ "$(probes)" -ge 1 ]
check "in print mode with /model as the prompt, so no model is called" grep -q -- '-p .*--append-system-prompt-file .*/model' "$LOG"
check "with a file that does not exist, so the missing file error is the answer" grep -qx 'handed a missing file' "$LOG"
check "and never with a file that exists" bash -c "! grep -qx 'handed an existing file' '$LOG'"
check "a Claude Code that still accepts the option is not reported" lacks "$out1" "append-system-prompt-file"

# ---- 2. a Claude Code that no longer knows it is named, with its version ----
: > "$LOG"
H2="$WORK/home-refuse"
out2="$(status_in "$H2" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=refuse FAKE_V=2.1.400)"; rc2=$?
check "status finishes cleanly with the option refused" [ "$rc2" -eq 0 ]
check "the refusal names the option" has "$out2" "no longer accepts --append-system-prompt-file"
check "and the Claude Code version" has "$out2" "Claude Code 2.1.400"
check "and that no lessons review can start" has "$out2" "no lessons review can start"
n_refuse="$(probes)"

# ---- 3. once a day: the next status reads the recorded answer, and still says it ----
out3="$(status_in "$H2" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=refuse FAKE_V=2.1.400)"
check "a second status the same day does not ask again" [ "$(probes)" -eq "$n_refuse" ]
check "and still names the refusal from the recorded answer" has "$out3" "no longer accepts --append-system-prompt-file"
check "saying when it was checked" has "$out3" "checked"

# ---- 4. a day later it asks again, and the answer it gets is the one said ----
python3 - "$H2/state/review-option-probe.json" <<'EOF'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["checked"] = int(time.time()) - 90000
json.dump(d, open(p, "w"))
EOF
out4="$(status_in "$H2" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=accept)"
check "a recorded answer older than a day is asked again" [ "$(probes)" -gt "$n_refuse" ]
check "and the fresh answer replaces it" lacks "$out4" "append-system-prompt-file"

# ---- 5. an updated claude is asked at once, not a day later ----
n5="$(probes)"
touch -t 202001010000 "$FAKE"
out5="$(status_in "$H2" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=refuse FAKE_V=2.1.500)"
check "a claude command that changed since the last answer is asked again the same day" [ "$(probes)" -gt "$n5" ]
check "and its refusal is said with its own version" has "$out5" "Claude Code 2.1.500"

# ---- 6. an answer that is neither is said as not checked, never as fine (L98, L11) ----
H6="$WORK/home-silent"
out6="$(status_in "$H6" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=silent)"
check "a claude that neither refuses nor misses the file is said as not checked" has "$out6" "Could not check whether Claude Code 2.1.325 accepts --append-system-prompt-file"
check "saying what it did instead" has "$out6" "exited 0"
H7="$WORK/home-hang"
out7="$(status_in "$H7" SYNC_CLAUDE_BIN="$FAKE" FAKE_MODE=hang SYNC_CLAUDE_CHECK_TIMEOUT=1)"; rc7=$?
check "a claude that does not answer is said as not checked, with the bound" has "$out7" "did not answer within 1s"
check "and status still finishes cleanly" [ "$rc7" -eq 0 ]

# ---- 7. no claude command: the reviews cannot run either, and other sections say so ----
H8="$WORK/home-none"
out8="$(status_in "$H8" SYNC_CLAUDE_BIN="$WORK/no-such-claude")"; rc8=$?
check "with no claude command status finishes cleanly" [ "$rc8" -eq 0 ]
check "and says nothing about the option" lacks "$out8" "append-system-prompt-file"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
