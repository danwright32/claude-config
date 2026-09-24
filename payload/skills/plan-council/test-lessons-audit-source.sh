#!/usr/bin/env bash
# Tests that the planning auditors read the lessons INDEX files, which fit in a context, rather
# than the full LESSONS.md, which does not (claude-config#561). Of 39 subagents told to read the
# 865,500 char LESSONS.md in the 30 days to 2026-09-24, 34 grepped it and 3 hit a size error.
#
# Also covers healthcheck.sh's lessons section, run against a throwaway HOME so it never reads
# this Mac's real config.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$(cd "$DIR/.." && pwd)"
WF="$DIR/panel.workflow.js"
LITE="$SKILLS/plan-lite/SKILL.md"
COUNCIL="$DIR/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok_if() { # ok_if <description> <command...>: passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; fi
}
not_if() { # not_if <description> <command...>: passes when the command fails
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL: $d"; else pass=$((pass + 1)); fi
}
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: $3"; fi
}

# 1. Nothing tells an agent to read the full LESSONS.md.
not_if "the workflow no longer points any agent at ~/.claude/LESSONS.md" grep -q "'~/.claude/LESSONS.md'" "$WF"
not_if "plan-lite's auditor is not told to read LESSONS.md in full" grep -q 'read `~/.claude/LESSONS.md` in full' "$LITE"
not_if "plan-council does not describe an audit reading LESSONS.md" grep -q 'reads `~/.claude/LESSONS.md`' "$COUNCIL"

# 2. Both point at the index files, plus the one entry lookup, and demand the files read.
ok_if "the workflow names the index files" grep -q "LESSONS_INDEX_GLOB = '~/.claude/LESSONS-INDEX-\*.md'" "$WF"
ok_if "the workflow names the entry lookup" grep -q "claude-sync lesson" "$WF"
ok_if "plan-lite's auditor reads the index files" grep -q 'LESSONS-INDEX-\*.md' "$LITE"
ok_if "plan-lite's auditor looks up any entry a finding relies on" grep -q 'claude-sync lesson' "$LITE"
ok_if "plan-lite's auditor must list every index file it read" grep -q 'every index file' "$LITE"
ok_if "plan-council passes the index file list it found to the workflow" grep -q 'lessonIndexFiles' "$COUNCIL"

# 3. The workflow's audit check refuses an audit that skipped an index file. The function is
#    evaluated for real in node, so this tests what the workflow computes, not its spelling.
af="$(grep -E '^const auditFailed = ' "$WF")"
if [[ -z "$af" ]] || ! command -v node >/dev/null 2>&1; then
  fail=$((fail + 1)); echo "FAIL: could not find auditFailed in the workflow, or node is missing"
else
  cat >"$TMP/af.js" <<JS
const a = { lessonIndexFiles: ['LESSONS-INDEX-a.md', 'LESSONS-INDEX-b.md'] }
$af
const full = { verdict: 'clean', indexFilesRead: ['LESSONS-INDEX-a.md', 'LESSONS-INDEX-b.md'], lessonsSeen: 700 }
const partial = { verdict: 'clean', indexFilesRead: ['LESSONS-INDEX-a.md'], lessonsSeen: 400 }
const none = { verdict: 'clean', indexFilesRead: [], lessonsSeen: 0 }
const couldNot = { verdict: 'could-not-audit', indexFilesRead: ['LESSONS-INDEX-a.md', 'LESSONS-INDEX-b.md'], lessonsSeen: 700 }
const missingField = { verdict: 'clean', lessonsSeen: 700 }
console.log([full, partial, none, couldNot, missingField].map(x => auditFailed(x)).join(','))
JS
  check "an audit is failed unless it read every index file the skill found" "false,true,true,true,true" "$(node "$TMP/af.js" 2>&1)"
fi

# 4. healthcheck.sh against a throwaway HOME: index files present, then absent.
H="$TMP/home"
mkdir -p "$H/.claude/skills/plan-council" "$H/.claude/skills/plan-lite" "$H/.claude/agents"
cp "$WF" "$COUNCIL" "$DIR/healthcheck.sh" "$H/.claude/skills/plan-council/"
cp "$LITE" "$H/.claude/skills/plan-lite/"
printf '# rules\n' >"$H/.claude/CLAUDE.md"
printf -- '- L1. A test is only real once it has been seen to fail.\n- L2. Tests never touch live data.\n' >"$H/.claude/LESSONS-INDEX-one.md"
printf -- '- L3. Built is not wired.\n' >"$H/.claude/LESSONS-INDEX-two.md"
out="$(HOME="$H" bash "$H/.claude/skills/plan-council/healthcheck.sh" 2>&1 | sed -n '/lessons audit/,$p')"
check "the healthcheck counts the index files and their lessons" "ok    lessons index present (2 files, 3 lessons)" "$out"
check "the workflow's index path is expanded before it is tested" "ok    workflow LESSONS_INDEX_GLOB" "$out"
check "the workflow's rules path is expanded before it is tested" "ok    workflow RULES_PATH" "$out"
rm -f "$H/.claude/LESSONS-INDEX-"*.md
out="$(HOME="$H" bash "$H/.claude/skills/plan-council/healthcheck.sh" 2>&1 | sed -n '/lessons audit/,$p')"
check "no index files is a failure, never a pass" "FAIL  no LESSONS-INDEX-*.md" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
