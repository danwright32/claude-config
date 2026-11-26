#!/usr/bin/env bash
# Refuse a session's ordinary command to put the changelog/announce label on a pull request until
# Dan has approved the wording that pull request would carry (claude-config#3666; his words for the
# feature: "it should ask me before applying the label"). And refuse a write to the record of what
# he approved, which only his own answer in the picker adds to.
#
# The rule, the commands it reads and its messages live in announce_label_gate.py. This is only the
# wrapper: leave at once on a call naming neither the label nor the record, run the gate, and refuse
# when the gate itself fails, since a gate that did not run is not one that found nothing (L98).
#
# This is the EARLY refusal, for the ordinary routes. A label put on by a route it cannot read (a
# name built at run time, a script, GitHub's own page) is not seen here and still cannot merge: the
# merge gate, require-changelog-tag.sh, is what holds that an announcement merges only on wording
# Dan approved.
#
# Every refusal is a deny, never a question: a permission prompt shows the command and not the
# wording, and sleep mode can answer one with Dan asleep (db-write-ask.sh). No override: the remedy
# is always open, ask him with the picker the refusal describes.
#
# Seams, for the tests: ANNOUNCE_APPROVALS_DIR (read by lib/announce-approval.py) names another
# record, and ANNOUNCE_LABEL_GITHUB_SECONDS shortens the wait on GitHub (it can only shorten it).

set -uo pipefail

payload="$(cat)"

# Every Bash call and every file edit reaches this hook, so the commonest call leaves here, before
# anything is loaded: only one naming the label, or the record's folder, is judged. Matched in the C
# locale, so a byte that is not UTF-8 cannot hide the words after it, and in any letter case, since
# GitHub matches a label's name in either. A slash JSON wrote as an escape is matched too.
# The match in any letter case is this test's alone: it is switched off again before returning, so
# the libraries loaded below find the shell matching as it always does.
judged_call() {
  local LC_ALL=C found=1
  shopt -s nocasematch
  case "$1" in
    *changelog/announce*|*'changelog\/announce'*|*announce-approvals*) found=0 ;;
  esac
  shopt -u nocasematch
  return "$found"
}
judged_call "$payload" || exit 0

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "${HERE:-/}" && pwd)"

JUDGES="one that puts the changelog/announce label on a pull request, or writes the record of the announcement wording Dan approved"

# The shared reader cleans the payload before python3 parses it (claude-config#1944). Past the test
# above this may be a call it judges, so a library that will not load is refused, naming the file
# (#1900).
# shellcheck source=lib/push-scope.sh
. "$HERE/lib/push-scope.sh" 2>/dev/null || {
  echo "ANNOUNCE LABEL: announce-label-ask.sh could not load $HERE/lib/push-scope.sh, which cleans this hook's input before it is read, so whether this call is $JUDGES could not be checked. Reinstall the hooks with claude-sync pull." >&2
  exit 2
}
payload="$(ps_clean_payload "$payload")"
# A payload nothing can read as a call is judged by its words (#1922, #2057): refused when it names
# the label or the record, naming the payload, and passed otherwise. The label is matched in any
# letter case, as GitHub reads a label's name and as judged_call above does.
ps_parse_payload "$payload" raw >/dev/null \
  || ps_unparsed_refuse "$payload" announce-label-ask.sh - "$JUDGES" '*[Cc][Hh][Aa][Nn][Gg][Ee][Ll][Oo][Gg]/[Aa][Nn][Nn][Oo][Uu][Nn][Cc][Ee]*' '*announce-approvals*'

if ! command -v python3 >/dev/null 2>&1; then
  echo "ANNOUNCE LABEL: python3 is not on PATH, so announce-label-ask.sh could not tell whether this call is $JUDGES. A gate that did not run is not one that found nothing. Install python3 and run the command again." >&2
  exit 2
fi

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 -B "$HERE/announce_label_gate.py" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "ANNOUNCE LABEL: announce-label-ask.sh failed (rc=$rc), so whether this call is $JUDGES could not be checked. A gate that did not run is not one that found nothing. $(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-600)" >&2
  exit 2
fi

printf '%s' "$out"
exit 0
