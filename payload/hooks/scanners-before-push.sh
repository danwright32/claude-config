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
# sync suite. Run one after another the gate took 27 seconds; run at once, which is how it runs,
# 13. Running that sync suite whole instead would be 268 seconds, which is why a suite with
# sections is run section wise.
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

# A gate that runs suites cannot run the suite that drives the gate, or it re-enters itself for
# ever: a script that finds its subjects by a marker matches itself, because it has to name the
# marker (L245). Measured 2026-09-21: this fanned out to dozens of processes and took the machine
# to a load average of 135 before it was killed.
#
# Bounded by an exported marker rather than by excluding a filename, because the next suite to
# name the marker will not be that file. Anything started underneath this gate finds it set and
# refuses, whatever it is.
if [ -n "${SCANNERS_GATE_RUNNING:-}" ]; then
  echo "scanners-before-push: already running inside this gate, so this nested push is not gated again." >&2
  exit 0
fi
export SCANNERS_GATE_RUNNING=1

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# Not this repository, so there is nothing here this hook knows how to run.
[ -f payload/hooks/run-all-tests.sh ] || exit 0

# Every suite that reads the repository's own files, committed or NOT (claude-config#522). Picked
# from what git tracks, a scanner just written was not run until the push after the one that added
# it, and it is the one most likely to be wrong (L456). Read into a variable rather than piped into
# a consumer that leaves early, which under pipefail reports a failure that never happened (L183).
#
# A scanner is recognised by how it lists the repository: through lib/repo-files.sh, the one way
# the scanners here do it, or by asking git directly, which a scanner elsewhere may still do.
REPO_FILES="$HOOK_DIR/lib/repo-files.sh"
SCANS='ls-files|repo-files[.]sh'
suites="$(bash "$REPO_FILES" . '*test-*.sh' 2>/dev/null)"
uncommitted_n="$(bash "$REPO_FILES" --uncommitted . 2>/dev/null | grep -c . || true)"
scanners=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "$s" ] || continue
  grep -qE "$SCANS" "$s" 2>/dev/null || continue
  # A suite that DRIVES this gate is not a subject of it. It matches the marker because its
  # fixtures have to contain one, and running it re-enters this gate once per fixture. Recognised
  # by the fact that it names this file, so a second suite written to test this gate later is
  # excluded on the same ground rather than needing to be remembered (L96). The exported marker
  # above still bounds anything that re-enters by another route.
  #
  # Only a line of CODE naming it counts. A comment that merely mentions this gate used to drop
  # its suite from the gate's selection, silently, which is how the pipefail ratchet fell out of it
  # the day a comment about this file was added there (claude-config#522).
  _code="$(grep -v '^[[:space:]]*#' "$s" 2>/dev/null)"
  case "$_code" in *"$(basename "${BASH_SOURCE[0]}")"*) continue ;; esac
  scanners="$scanners$s"$'\n'
done <<EOF
$suites
EOF

scanners="${scanners%$'\n'}"
if [ -z "$scanners" ]; then
  echo "scanners-before-push: found no scanner in this repository, which has the marker, so nothing was scanned before this push. That is not a clean run, it is an unmeasured one." >&2
  exit 0
fi

# The sections of a suite that scan: those holding a listing asked for by GLOBBED pathspec. The
# heading a scan sits under is read from the file, so a section added later is covered the day it
# lands. Written once, for the run and for the list of what would run.
scanning_sections(){   # $1 = a suite that supports SECTION_ONLY -> its scanning section titles
  awk -v pat="(ls-files|repo-files[.]sh[^']*) '[*]" '/^section "/ { sec = $0 } $0 ~ pat { if (sec != "") print sec }' "$1" 2>/dev/null \
    | sed 's|^section "||; s|"$||' | sort -u
}

# What it WOULD run, without running any of it. This used to be answered after every scanner had
# already run, so asking what the gate covers cost what the gate costs (L102).
if [ "${SCANNERS_LIST:-}" = "1" ]; then
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -q 'SECTION_ONLY' "$s" 2>/dev/null; then
      scanning_sections "$s" | sed "s|^|SECTION $s |"
    else
      printf 'SUITE %s\n' "$s"
    fi
  done <<LIST
$scanners
LIST
  exit 0
fi

# Run one suite, or one suite's scanning sections where it supports being run that way. Each run
# writes its own output and its own exit code to its own file, because they all run AT ONCE: five
# suites that share nothing are five lots of wall clock a push waits through for no reason (L302).
#
# Prints nothing on success: a gate that is happy should be quiet, and what it covered is printed
# once at the end instead.
_sc_work="$(mktemp -d "${TMPDIR:-/tmp}/scanners-before-push.XXXXXXXX")" || exit 0
trap 'rm -rf "$_sc_work"' EXIT
_sc_n=0

start_one(){         # $1 = the suite path   $2 = a section, or empty
  _sc_n=$(( _sc_n + 1 ))
  local out="$_sc_work/$_sc_n"
  printf '%s\n%s\n' "$1" "${2:-}" > "$out.what"
  if [ -n "${2:-}" ]; then
    ( SECTION_ONLY="$2" bash "$1" > "$out.out" 2>&1; printf '%s' "$?" > "$out.rc" ) &
  else
    ( bash "$1" > "$out.out" 2>&1; printf '%s' "$?" > "$out.rc" ) &
  fi
  return 0
}

while IFS= read -r s; do
  [ -n "$s" ] || continue
  if grep -q 'SECTION_ONLY' "$s" 2>/dev/null; then
    sections="$(scanning_sections "$s")"
    [ -n "$sections" ] || continue
    while IFS= read -r sec; do
      [ -n "$sec" ] || continue
      start_one "$s" "$sec"
    done <<SECTIONS
$sections
SECTIONS
  else
    start_one "$s" ""
  fi
done <<EOF
$scanners
EOF

wait

# Read every result back. A run whose exit code was never written did not finish saying anything,
# and that is not a pass: it is a scanner whose verdict is missing, which must not read as a clean
# one (L98).
failed=""
ran=0
_sc_i=1
while [ "$_sc_i" -le "$_sc_n" ]; do
  _sc_what="$(head -2 "$_sc_work/$_sc_i.what" 2>/dev/null | tr '\n' ' ')"
  ran=$(( ran + 1 ))
  if [ ! -f "$_sc_work/$_sc_i.rc" ]; then
    failed="$failed=== $_sc_what ===
this scanner never reported an exit code, so its verdict is missing rather than clean
"
  elif [ "$(cat "$_sc_work/$_sc_i.rc" 2>/dev/null)" != "0" ]; then
    failed="$failed=== $_sc_what ===
$(awk '/^FAIL|^not ok/ { if (n++ < 10) print }' "$_sc_work/$_sc_i.out" 2>/dev/null)
"
  fi
  _sc_i=$(( _sc_i + 1 ))
done

if [ -z "$failed" ]; then
  # What it covered, once, so the coverage of this gate is visible rather than assumed (L400).
  printf 'scanners-before-push: %s whole tree scan(s) passed before this push, run at once, reading %s uncommitted file(s) as well as the committed ones.\n' "$ran" "${uncommitted_n:-0}" >&2
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
  # Uncommitted files are read too (claude-config#522), and a failure in one is a draft rather than
  # anything this push carries, so the count is said where the verdict is.
  echo "These scans read ${uncommitted_n:-0} uncommitted file(s) as well as the committed ones. A failure"
  echo "in one of those is about a file this push does not carry: commit it fixed, or move it aside."
  echo ""
  echo "Reproduce any of them directly:"
  echo "    bash <the suite named above>"
  echo ""
  echo "OVERRIDE: if this is genuinely a false positive, re-run with:"
  echo "    SKIP_SCANNERS_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, why skipping is legitimate here. Never override silently."
} >&2
exit 2
