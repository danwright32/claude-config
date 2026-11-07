#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans CLAUDE.md skills/ agents/ commands/ mods/job-watcher/hooks/jobs.ts
# Text read by a dispatched agent never tells it to merge its own pull request (claude-config#2344).
#
# On 2026-11-05 a builder brief that asked the agent to merge its own green pull request, as the
# global rules then said ("finish the merge yourself"), was refused WHOLE by the auto mode classifier
# with "[Merge Without Review]", and the green work waited overnight. The decision recorded on #2344:
# builders never merge. A dispatched agent hands back an open green PR, or a pushed branch and a PR
# body, and the main session merges it with merge-when-ready.sh. Letting auto mode allow agent merges
# was not built, because it loosens a security control.
#
# So this holds every text a brief is built from, or that an agent reads directly, to that decision:
#   A. in the global rules, every skill, agent and command, and the job watcher's refusal to a
#      subagent: no "finish the merge" and no un-negated "merge its/your/their own pull request";
#   B. in the files an agent reads as its own instructions (agents/*.md, the orchestrate agent
#      rules): no merge-when-ready, no gh pr merge, and no "merge the PR / merge it", on any line
#      that does not say never or not.
# "Merge the green PR yourself" in the global rules stays: it is addressed to the main session, and
# rule A is calibrated (2026-11-06) to pass it while failing the old builder wording.
# Each rule is first seen to fail on fixtures carrying the old wording (L1), then run on the payload.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="${BUILDER_BRIEFS_PAYLOAD:-$(cd "$DIR/.." && pwd)}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# Rule A, over any file: prints file:line for each line telling the reader to merge its own PR.
rule_a() {
  perl -ne '
    my $l = lc $_;
    if ($l =~ /\bfinish(?:es|ing)? (?:the|its|your) merge\b/
        || $l =~ /(?<!never )(?<!not )(?<!n.t )\bmerges? (?:its|your|their) own (?:pull requests?|prs?)\b/) {
      print "$ARGV:$.\n";
    }
    close ARGV if eof;
  ' "$@"
}

# Rule B, over files an agent reads as its own instructions: any merge step on an un-negated line.
rule_b() {
  perl -ne '
    my $l = lc $_;
    if ($l !~ /\b(?:never|not|don.t|no)\b/
        && ($l =~ /merge-when-ready/ || $l =~ /\bgh pr merge\b/
            || $l =~ /\bmerge (?:it|your (?:own )?(?:pr|pull request)|the (?:green )?(?:pr|pull request))\b/)) {
      print "$ARGV:$.\n";
    }
    close ARGV if eof;
  ' "$@"
}

FIX="$(mktemp -d "${TMPDIR:-/tmp}/builder-briefs.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# ---- the rules fail on the old wording (L1) ----
# The global rules' sentence before #2344, verbatim.
printf '%s\n' '- **A dispatched agent hands back.** Tell every agent you dispatch: wait for a check watcher, Monitor, merge helper or test run in the foreground, or stop it with TaskStop, and then either finish the merge yourself or hand back your report for the main session to merge.' > "$FIX/old-rules.md"
# The job watcher's refusal to a subagent before #2344, verbatim.
printf '%s\n' "  'Either wait for it in the foreground, finish what it was for, or stop it with TaskStop; then hand back your report, or finish the merge yourself.'" > "$FIX/old-jobs.ts"
printf '%s\n' 'Once CI is green, merge your own pull request.' > "$FIX/own.md"
printf '%s\n' '- Merge with `bash ~/.claude/hooks/lib/merge-when-ready.sh <n> --delete-branch` once checks pass.' > "$FIX/helper.md"
printf '%s\n' '- When checks are green run `gh pr merge 12 --squash`.' > "$FIX/ghmerge.md"
printf '%s\n' '- Open the PR and merge it once CI is green.' > "$FIX/mergeit.md"

for f in old-rules.md old-jobs.ts own.md; do
  check "rule A fires on $f" "$([ -n "$(rule_a "$FIX/$f")" ] && echo ok || echo "rule A passed text telling an agent to merge")"
done
for f in helper.md ghmerge.md mergeit.md; do
  check "rule B fires on $f" "$([ -n "$(rule_b "$FIX/$f")" ] && echo ok || echo "rule B passed a brief naming a merge step")"
done

# ---- and pass the wording that agrees with the classifier ----
printf '%s\n' '- **Keep the issue loop moving:** Merge the green PR yourself (verify with `gh`).' > "$FIX/main.md"
printf '%s\n' 'This session merges. It never works an item itself, and agents never merge their own pull requests.' > "$FIX/never.md"
printf '%s\n' '- A dispatched agent never merges its own pull request; it hands back for the main session to merge.' > "$FIX/never2.md"
printf '%s\n' '- Push your branch. Do not open or merge a pull request.' > "$FIX/donot.md"
printf '%s\n' '- Never run `merge-when-ready.sh` or `gh pr merge` yourself; the main session merges.' > "$FIX/nevertool.md"
for f in main.md never.md never2.md donot.md nevertool.md; do
  check "rule A passes $f" "$([ -z "$(rule_a "$FIX/$f")" ] && echo ok || echo "rule A fired on wording that agrees")"
done
for f in never.md donot.md nevertool.md; do
  check "rule B passes $f" "$([ -z "$(rule_b "$FIX/$f")" ] && echo ok || echo "rule B fired on wording that agrees")"
done

# ---- the payload ----
if [ ! -f "$PAYLOAD/CLAUDE.md" ] || [ ! -d "$PAYLOAD/skills" ]; then
  printf 'SUITE-NOT-RUN %s\n' "no payload with CLAUDE.md and skills/ at $PAYLOAD"
  exit 2
fi
# Each listing read into a variable first, then fed from a here document (a process substitution is
# a child the shell never waits for, #2040), skipping the one empty line an empty listing gives.
a_list="$(find "$PAYLOAD/skills" "$PAYLOAD/agents" "$PAYLOAD/commands" -type f -name '*.md' 2>/dev/null | sort)"
b_list="$(find "$PAYLOAD/agents" -type f -name '*.md' 2>/dev/null | sort)"
a_files=("$PAYLOAD/CLAUDE.md")
while IFS= read -r f; do [ -n "$f" ] && a_files+=("$f"); done <<< "$a_list"
[ -f "$PAYLOAD/mods/job-watcher/hooks/jobs.ts" ] && a_files+=("$PAYLOAD/mods/job-watcher/hooks/jobs.ts")
b_files=()
while IFS= read -r f; do [ -n "$f" ] && b_files+=("$f"); done <<< "$b_list"
[ -f "$PAYLOAD/skills/orchestrate/agent-rules.md" ] && b_files+=("$PAYLOAD/skills/orchestrate/agent-rules.md")

# A scan that read nothing would pass (L98), so it must have read the files it exists for.
check "rule A reads the global rules, the skills and the job watcher refusal" \
  "$([ "${#a_files[@]}" -gt 50 ] && [ -f "$PAYLOAD/mods/job-watcher/hooks/jobs.ts" ] && echo ok || echo "only ${#a_files[@]} files found under $PAYLOAD")"
check "rule B reads the orchestrate agent rules" \
  "$([ -f "$PAYLOAD/skills/orchestrate/agent-rules.md" ] && [ "${#b_files[@]}" -gt 1 ] && echo ok || echo "only ${#b_files[@]} agent instruction files found")"

hits="$(rule_a "${a_files[@]}")"
check "no text tells a dispatched agent to merge its own pull request" "$([ -z "$hits" ] && echo ok || echo "$hits")"
hits="$(rule_b "${b_files[@]}")"
check "no agent instruction file names a merge step" "$([ -z "$hits" ] && echo ok || echo "$hits")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
