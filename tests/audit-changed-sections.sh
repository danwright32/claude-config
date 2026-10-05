#!/usr/bin/env bash
#
# audit-changed-sections.sh: run, on its own, every suite section a push touched
# (claude-config#105).
#
# The suite's sections are independent: 73 of 73 run alone, and the one real dependency left is
# declared with a `# needs:` comment. That is a property somebody has to keep true, and the moment
# it stops being true is the moment somebody writes a NEW section that quietly reads a fixture an
# earlier one built. The full suite cannot notice, because it runs everything in order and the
# fixture is always there.
#
# So this runs each changed section by itself, which is the only run in which a missing prerequisite
# shows up. It is scoped to the diff deliberately: a push that does not touch the suite costs
# nothing, and a push that adds or edits a section pays for exactly that section.
#
# Usage: audit-changed-sections.sh <base-ref>
#
# Exit 0 = every changed section ran alone and passed, or there was nothing to do (which is said in
# those words rather than reported as a clean audit). Exit 1 = a changed section cannot run alone.
# Exit 4 = no changed section failed a check of its own but the prelude every section runs first failed,
# which is worded as that rather than blamed on the section (claude-config#625).
# Exit 2 = the suite changed but no section could be derived from the diff, which is a failure
# rather than a pass: an empty answer here is indistinguishable from having checked everything
# (LESSONS.md L98), and it is worded differently from a legitimate nothing-to-do (L11).
set -uo pipefail

SUITE="${AUDIT_SUITE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-claude-sync.sh}"
BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: audit-changed-sections.sh <base-ref>" >&2; exit 2; }
[ -f "$SUITE" ] || { echo "audit-changed-sections: no suite to read at $SUITE" >&2; exit 2; }

_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _root=""
[ -n "$_root" ] || { echo "audit-changed-sections: not inside a git repository, so there is no diff to scope to." >&2; exit 2; }
ROOT="$(cd "$_root" && pwd -P)"
SUITE_ABS="$(cd "$(dirname "$SUITE")" && pwd -P)/$(basename "$SUITE")"
REL="${SUITE_ABS#$ROOT/}"

if git diff --quiet "$BASE" -- "$REL" 2>/dev/null; then
  echo "audit-changed-sections: $REL is unchanged against $BASE, so no section needed running on its own. The full suite still runs."
  exit 0
fi

# The changed lines, on the NEW side. A hunk that only REMOVES lines has a count of zero there, and
# that is exactly how a derivation quietly comes back empty, so a deletion is attributed to the
# position it happened at rather than dropped. split()'s return value is used rather than
# length(array), which is not portable across awk implementations.
changed="$(git diff --unified=0 "$BASE" -- "$REL" | awk '
  /^@@/ {
    k = split($3, p, ",")
    s = substr(p[1], 2) + 0
    n = (k > 1) ? p[2] + 0 : 1
    if (n == 0) { print s; next }
    for (i = 0; i < n; i++) print s + i
  }')"

# The section spans come from the SUITE, by asking it, rather than from a second derivation here.
# Two implementations of "where do the sections start and what are they called" drift, and this is
# the worse half to have drift: it is what decides whether a changed section can stand on its own,
# so a wrong answer scopes the audit to the wrong sections while still reporting a clean run
# (claude-config#114).
#
# They also have to come from the file's own headings rather than from line numbers recorded
# anywhere, because a diff moves every line below an insertion.
headings="$(SECTION_LIST=1 bash "$SUITE" 2>/dev/null || true)"
if [ -z "${headings%%[[:space:]]}" ] || ! grep -q '[0-9]' <<< "$headings"; then
  echo "audit-changed-sections: $REL listed no sections, so no changed line can be attributed to one. Refusing rather than treating the whole diff as preamble, which would report a clean audit of nothing." >&2
  exit 2
fi

preamble=0
titles=""
while IFS= read -r _ln; do
  case "$_ln" in ''|*[!0-9]*) continue ;; esac
  _t="$(printf '%s\n' "$headings" | awk -F'\t' -v L="$_ln" '{ if ($1 + 0 <= L + 0) last=$2 } END { print last }')"
  if [ -z "$_t" ]; then preamble=1; continue; fi
  titles="$titles$_t
"
done <<CHANGED
$changed
CHANGED

# `case` rather than stripping every space out. That substitution is superlinear in the number of
# matches under the bash macOS ships, and this list grows with the size of the diff being audited
# (claude-config#117).
titles_found=0
case "$titles" in *[![:space:]]*) titles_found=1 ;; esac
if [ "$titles_found" -eq 0 ]; then
  if [ "$preamble" -eq 1 ]; then
    echo "audit-changed-sections: the change is in the preamble, which every section runs anyway, so running one section at a time proves nothing extra here. The full suite covers it."
    exit 0
  fi
  echo "audit-changed-sections: $REL changed against $BASE, but no section could be derived from that diff. Refusing to report a clean audit, because an empty answer here reads exactly like having checked everything." >&2
  exit 2
fi

# WHERE a changed section is run (claude-config#339). By default this machine, which is what this
# has always done. With AUDIT_ON_LINUX=1 it goes through the container runner beside it instead, so
# a push can be judged by the operating system CI actually uses rather than the one it is being
# made from. Two defects shipped on 2026-09-07 that were green on every Mac and red only there.
#
# The runner answers 3 for "this could not be run at all", which is NOT a failure of the section:
# a machine with no docker has to let the push through rather than block on a question it cannot
# ask, and it has to say so, because a gate that silently does nothing is worse than no gate
# (L98, L11).
LINUX_RUNNER="$(dirname "$SUITE_ABS")/run-on-linux.sh"
if [ -n "${AUDIT_ON_LINUX:-}" ] && [ ! -x "$LINUX_RUNNER" ]; then
  echo "audit-changed-sections: asked to audit on Linux, but there is no runner at $LINUX_RUNNER. Refusing rather than falling back to this machine and reporting the result as Linux's (L320)." >&2
  exit 2
fi
run_one(){   # $1 = section title -> that section's exit status
  if [ -n "${AUDIT_ON_LINUX:-}" ]; then
    SECTION_ONLY="$1" bash "$LINUX_RUNNER" "$REL"
  else
    SECTION_ONLY="$1" bash "$SUITE"
  fi
}

# WHICH PART of a failed run failed (claude-config#625). A section run on its own runs the PRELUDE
# first, the checks every section depends on, and the suite reports the two apart on its
# SUITE-SECTIONS line. On 2026-10-03 a push was blocked as "a test section this change touches FAILS
# on Linux" while that same line read prelude_fail=4 target_fail=0: the changed section passed, and
# the four failures were in the prelude, broken on unchanged main by a tool the container lacked.
# A message naming the wrong culprit pushes toward an override (L11), so the counts are read and
# each case is worded for what it measured. A run that printed no such line, or whose counts are
# both zero, is still a failure of the section, because nothing says otherwise.
_sec_count(){   # $1 = SUITE-SECTIONS line  $2 = field -> its number, or nothing
  printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { print $2; exit }'
}
_run_out="$(mktemp "${TMPDIR:-/tmp}/audit-changed-sections.XXXXXXXX")" || _run_out=""
[ -n "$_run_out" ] && trap 'rm -f "$_run_out"' EXIT

n=0; bad=""; unmeasured=""; prelude_bad=""
while IFS= read -r _t; do
  [ -n "$_t" ] || continue
  n=$((n + 1))
  echo ""
  echo "audit-changed-sections: running only $_t"
  _rc=0
  if [ -n "$_run_out" ]; then
    run_one "$_t" 2>&1 | tee "$_run_out"; _rc=${PIPESTATUS[0]}
  else
    run_one "$_t" || _rc=$?
  fi
  if [ "$_rc" -ne 0 ]; then
    if [ -n "${AUDIT_ON_LINUX:-}" ] && [ "$_rc" -eq 3 ]; then
      unmeasured="$unmeasured$_t
"
      continue
    fi
    _secline=""
    [ -n "$_run_out" ] && _secline="$(grep -m1 '^SUITE-SECTIONS ' "$_run_out" 2>/dev/null || true)"
    _pf="$(_sec_count "$_secline" prelude_fail)"; _tf="$(_sec_count "$_secline" target_fail)"
    case "$_pf" in ''|*[!0-9]*) _pf=0 ;; esac
    case "$_tf" in ''|*[!0-9]*) _tf=0 ;; esac
    _tp="$(_sec_count "$_secline" target_pass)"
    case "$_tp" in ''|*[!0-9]*) _tp=0 ;; esac
    if [ "$_tf" -eq 0 ] && [ "$_pf" -gt 0 ]; then
      # Only a section that RAN checks of its own can be said to have passed them. One the prelude
      # cut short ran none, and saying it passed would claim a measurement nobody took (L440).
      if [ "$_tp" -gt 0 ]; then
        _what="the section's own $_tp check(s) passed"
      else
        _what="the section ran none of its own checks, so nothing here says whether it passes"
      fi
      prelude_bad="$prelude_bad$_t (the prelude failed $_pf check(s); $_what)
"
    else
      bad="$bad$_t
"
    fi
  fi
done <<TITLES
$(printf '%s' "$titles" | sort -u)
TITLES

case "$bad" in *[![:space:]]*)
  echo "" >&2
  if [ -n "${AUDIT_ON_LINUX:-}" ]; then
    echo "audit-changed-sections: these changed sections FAIL their own checks when run on Linux:" >&2
    printf '%s' "$bad" | sed 's/^/  /' >&2
    echo "Either the section fails on Linux outright, or it cannot run alone; the output above says which. Running it alone, on the operating system CI uses, is the only run where either shows up before CI." >&2
  else
    echo "audit-changed-sections: these changed sections do not run on their own:" >&2
    printf '%s' "$bad" | sed 's/^/  /' >&2
    echo "Give the section its own fixture, or add a '# needs:' line naming the section it depends on. Running it alone is the only run where a missing prerequisite shows up at all." >&2
  fi
  exit 1 ;;
esac

# THE PRELUDE FAILED and no changed section failed a check of its own (claude-config#625). That is not
# evidence against the sections, and it is not said as if it were. What it IS evidence of is
# narrower than "the base is broken": the prelude also exercises code outside the suite file, so
# a change to that code can break it too, and only running the base tells the two apart. Its own
# exit status, so the push gate can word its refusal for what was measured.
case "$prelude_bad" in *[![:space:]]*)
  echo "" >&2
  echo "audit-changed-sections: the PRELUDE failed${AUDIT_ON_LINUX:+ on Linux}, not the changed sections:" >&2
  printf '%s' "$prelude_bad" | sed 's/^/  /' >&2
  if [ "$preamble" -eq 1 ]; then
    echo "This change also edits the prelude itself, so the failure may well be the change's own. Read the prelude's failures in the output above." >&2
  else
    echo "This change does not edit the prelude, so the failure is in the base this was cut from, or in code outside the suite that the prelude exercises (the tool, a hook, or the environment the run happens in). To tell which, run the same section on the unchanged base: if it fails there too, the base is broken and this change is not the cause." >&2
  fi
  exit 4 ;;
esac

# UNMEASURED is said, and it is not a pass. Nothing here can be concluded about those sections, and
# the difference between "Linux is happy with them" and "Linux was never asked" is the whole value
# of running them there at all (L98, L11).
case "$unmeasured" in *[![:space:]]*)
  echo "" >&2
  echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
  printf '%s' "$unmeasured" | sed 's/^/  /' >&2
  echo "That is UNMEASURED, not a pass. The push is not blocked on a question this machine cannot ask; CI will still ask it." >&2 ;;
esac

# The closing line is derived from what actually ran, never from the count of sections looked at
# (claude-config#523). It used to say every changed section "ran on its own and passed" even when
# the notice directly above said the Linux runner could not run and named them as UNMEASURED, and
# the last line is the one a reader keeps (L11, L440).
_un_n="$(printf '%s' "$unmeasured" | grep -c . || true)"
echo ""
if [ "${_un_n:-0}" -gt 0 ]; then
  echo "audit-changed-sections: of $n section(s) changed against $BASE${AUDIT_ON_LINUX:+, on Linux}, $(( n - _un_n )) ran on their own and passed and ${_un_n} were not judged at all (listed above). That is UNMEASURED, not a pass."
else
  echo "audit-changed-sections: audited $n section(s) changed against $BASE${AUDIT_ON_LINUX:+, on Linux}, and each one ran on its own and passed."
fi
exit 0
