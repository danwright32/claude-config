#!/usr/bin/env bash
#
# scanners-before-push.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: before a `git push`, run this repository's WHOLE TREE scanners, and block the push if one
# of them fails (claude-config#518).
#
# The pre push test gate asks a model one question, whether each change in the push carries a
# test, and runs no suite at all. Everything else waits for CI. That is fine for a guard that
# reads the code under change, and useless for the family of guards here that read every tracked
# file in the repository, because those fail over what a change ADDS ANYWHERE: a comment quoting a
# measured number with no date, a pipeline ending in a consumer that leaves early, a hook with no
# coverage. On 2026-09-20 two such defects went to main in one evening and the build went red
# twice, both caught in seconds by a scanner nobody had run.
#
# WHICH suites it runs is derived, never listed. A scanner is a suite that enumerates the
# repository's own tracked files, and it identifies itself by doing so: it asks git what is
# tracked. A hand written list of scanners would exempt the next one somebody writes, which is the
# failure this repo keeps removing (L96, L41).
#
# The rule is deliberately different at the two levels, and the reason is the cost of being wrong.
# A whole suite that mentions git ls-files anywhere is run, because a false positive there costs a
# few seconds. Inside a suite that supports SECTION_ONLY, only the sections that enumerate by
# GLOBBED PATHSPEC are run, because a bare listing inside such a suite is nearly always a fixture
# repository it built itself, and each false positive there costs a section run plus the prelude.
# `--list` prints the selection without running any of it, so what this gate covers can be read
# without paying for it (L102).
#
# It is repo-agnostic by construction: a repository with no payload/hooks/run-all-tests.sh is not
# this one, and the hook does nothing at all there rather than running suites it knows nothing
# about the cost of.
#
# Fails OPEN in every direction it cannot see: not a repository, no scanners found, a suite that
# could not be executed. It blocks on ONE thing, a scanner that ran and failed. Finding NO
# scanners is reported rather than passed silently, because reading nothing and reading everything
# green look identical otherwise (L98).
#
# MEASURED on this Mac 2026-09-21: the selection is five standalone suites plus one section of the
# sync suite, and the whole gate takes 27 seconds. Running that sync suite whole instead would be
# 268 seconds, which is why a suite with sections is run section wise.
#
# Override: SKIP_SCANNERS_CHECK=1 git push ...   Explain why to the user first, never silently.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_SCANNERS_CHECK && exit 0

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# Not this repository, so there is nothing here this hook knows how to run.
[ -f payload/hooks/run-all-tests.sh ] || exit 0

# Every tracked suite that reads the repository's own tracked files. Read into a variable rather
# than piped into a consumer that leaves early, which under pipefail reports a failure that never
# happened (L183).
suites="$(git ls-files '*test-*.sh' 2>/dev/null)"
scanners=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "$s" ] || continue
  # The pathspec glob is what distinguishes a suite scanning the TREE from one running git against
  # a fixture repository it built itself.
  grep -q "ls-files" "$s" 2>/dev/null || continue
  scanners="$scanners$s"$'\n'
done <<EOF
$suites
EOF

scanners="${scanners%$'\n'}"
if [ -z "$scanners" ]; then
  echo "scanners-before-push: found no scanner in this repository, which has the marker, so nothing was scanned before this push. That is not a clean run, it is an unmeasured one." >&2
  exit 0
fi

# Run one suite, or one suite's scanning sections where it supports being run that way. Prints
# nothing on success: a gate that is happy should be quiet, and what it covered is printed once at
# the end instead.
failed=""
ran=""
run_one(){           # $1 = the suite path
  local s="$1" out rc sec
  if grep -q 'SECTION_ONLY' "$s" 2>/dev/null; then
    # Only the sections that scan. The heading a scan sits under is read from the file, so a
    # section added later is covered the day it lands.
    local sections
    sections="$(awk "/^section \"/{sec=\$0} /ls-files '\*/{ if (sec != \"\") print sec }" "$s" 2>/dev/null \
                | sed 's/^section "//; s/"$//' | sort -u)"
    [ -n "$sections" ] || return 0
    while IFS= read -r sec; do
      [ -n "$sec" ] || continue
      out="$(SECTION_ONLY="$sec" bash "$s" 2>&1)"; rc=$?
      ran="$ran$s ($sec)"$'\n'
      [ "$rc" -eq 0 ] || failed="$failed=== $s, section $sec ===
$(printf '%s\n' "$out" | awk '/^FAIL|^not ok/ { if (n++ < 10) print }')
"
    done <<SECTIONS
$sections
SECTIONS
    return 0
  fi
  out="$(bash "$s" 2>&1)"; rc=$?
  ran="$ran$s"$'\n'
  [ "$rc" -eq 0 ] || failed="$failed=== $s ===
$(printf '%s\n' "$out" | awk '/^FAIL|^not ok/ { if (n++ < 10) print }')
"
  return 0
}

# What it WOULD run, without running any of it.
if [ "${SCANNERS_LIST:-}" = "1" ]; then
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -q 'SECTION_ONLY' "$s" 2>/dev/null; then
      awk "/^section \"/{sec=\$0} /ls-files '\*/{ if (sec != \"\") print sec }" "$s" 2>/dev/null \
        | sed "s|^section \"|SECTION $s |; s|\"$||" | sort -u
    else
      printf 'SUITE %s\n' "$s"
    fi
  done <<LIST
$scanners
LIST
  exit 0
fi

while IFS= read -r s; do
  [ -n "$s" ] || continue
  run_one "$s"
done <<EOF
$scanners
EOF

if [ -z "$failed" ]; then
  # What it covered, once, so the coverage of this gate is visible rather than assumed (L400).
  printf 'scanners-before-push: %s whole tree scan(s) passed before this push.\n' "$(printf '%s' "$ran" | grep -c .)" >&2
  exit 0
fi

{
  echo "PUSH BLOCKED: a scanner that reads the WHOLE repository fails."
  echo ""
  echo "These guards fail over what a change adds anywhere, so the gate that reads"
  echo "the diff cannot see them and CI is otherwise the first place they speak. On"
  echo "2026-09-20 that put two defects on main in one evening and turned the build"
  echo "red twice, both of them caught in seconds by a scanner nobody had run."
  echo ""
  printf '%s' "$failed"
  echo "Reproduce any of them directly:"
  echo "    bash <the suite named above>"
  echo ""
  echo "OVERRIDE: if this is genuinely a false positive, re-run with:"
  echo "    SKIP_SCANNERS_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, why skipping is legitimate here. Never override silently."
} >&2
exit 2
