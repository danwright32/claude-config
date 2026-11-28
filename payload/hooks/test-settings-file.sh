#!/usr/bin/env bash
# Tests for lib/settings-file.sh, the one lookup of the file that holds the hooks block
# (claude-config#1237), and the scan that keeps it the only one.
#
# Fifteen suites wrote the lookup out for themselves, and three named only the repository's
# spelling, so they failed (or declared themselves not run) from the installed copy the post sync
# suite runs (measured 2026-10-16). A shared helper ends the copies only with
# a scan that fails on the next one (L613), so the scan is here beside the helper's own cases.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/settings-file.sh" || {
  echo "FAIL: lib/settings-file.sh is missing beside $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)" | sed '2,$s/^/  /'; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# The two spellings, held in variables so no line here names either as a path, which is what the
# scan below looks for.
SHIPPED="settings.hooks.json"
INSTALLED="settings.json"

# ---- the lookup --------------------------------------------------------------------------------
mkdir -p "$T/checkout" "$T/deployed" "$T/both" "$T/neither"
: > "$T/checkout/$SHIPPED"
: > "$T/deployed/$INSTALLED"
: > "$T/both/$SHIPPED"; : > "$T/both/$INSTALLED"
got="$(hook_settings_file "$T/checkout")"
[ "$got" = "$T/checkout/$SHIPPED" ] && check "the checkout answers with the shipped settings" ok \
  || check "the checkout answers with the shipped settings" "got [$got]"
got="$(hook_settings_file "$T/deployed")"
[ "$got" = "$T/deployed/$INSTALLED" ] && check "an installed copy answers with the installed settings" ok \
  || check "an installed copy answers with the installed settings" "got [$got]"
got="$(hook_settings_file "$T/both/")"
[ "$got" = "$T/both/$SHIPPED" ] && check "where both exist the shipped settings win" ok \
  || check "where both exist the shipped settings win" "got [$got]"
got="$(hook_settings_file "$T/neither")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$got" ] && check "neither is an answer of its own, not an empty path" ok \
  || check "neither is an answer of its own, not an empty path" "rc $rc, printed [$got]"

# ---- the scan ----------------------------------------------------------------------------------
# A suite that writes either spelling out as a path beside a directory, on a line that is not a
# comment, is a copy of the lookup. Read once per file (L297): grep picks the files that name one at
# all, then one awk pass over each prints file:line for every line that is code.
# Bracketed rather than backslashed, because awk -v turns "\." into a bare "." that matches anything.
COPY_RE='/settings[.]hooks[.]json|[.][.]/settings[.]json'
# Only what the sync carries (claude-config#2750): installed, the root is ~/.claude, which also holds
# copies a Mac keeps for itself, and lib/synced-trees.sh is the one list of what a scan may read.
. "$DIR/lib/synced-trees.sh" && declare -F synced_files >/dev/null || {
  echo "FAIL: lib/synced-trees.sh is missing or holds no synced_files beside $DIR"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$((fail + 1))"
  exit 1
}
scanned_suites() {   # $1 = a config root -> every test-*.sh the sync carries under hooks, skills and mods
  local listed
  listed="$(synced_files "$1" hooks skills mods)" || return 1
  printf '%s\n' "$listed" | grep '/test-[^/]*\.sh$'
}
inline_copies() {   # $1 = a config root to scan
  local f listed
  listed="$(scanned_suites "$1")" || return 1
  [ -n "$listed" ] || return 0
  printf '%s\n' "$listed" | tr '\n' '\0' | xargs -0 grep -lE "$COPY_RE" 2>/dev/null | while IFS= read -r f; do
    awk -v re="$COPY_RE" -v f="$f" '$0 !~ /^[ \t]*#/ && $0 ~ re { print f ":" FNR ": " $0 }' "$f"
  done
}

# Seen to fail first (L1): a suite with its own copy is reported, one that asks the helper is not,
# and a comment or a message naming the spelling is not a copy.
mkdir -p "$T/scan/hooks"
printf 'SETTINGS="$DIR/../%s"\n[ -f "$SETTINGS" ] || SETTINGS="$DIR/../%s"\n' "$SHIPPED" "$INSTALLED" > "$T/scan/hooks/test-copy.sh"
cat > "$T/scan/hooks/test-helper.sh" <<'SH'
# In the repository the hooks block is payload/settings.hooks.json.
SETTINGS="$(hook_settings_file "$DIR/..")" || echo "neither settings.hooks.json nor settings.json beside $DIR"
SH
found="$(inline_copies "$T/scan")"
case "$found" in
  *test-copy.sh:1:*test-copy.sh:2:*) check "the scan reports both lines of an inline copy" ok ;;
  *) check "the scan reports both lines of an inline copy" "it found [$found]" ;;
esac
case "$found" in
  *test-helper.sh*) check "a suite asking the helper is not reported" "it was: [$found]" ;;
  *) check "a suite asking the helper is not reported" ok ;;
esac
# Installed, the tree is ~/.claude, which also holds what a Mac keeps for itself: copies of suites an
# agent kept in its session notes, Claude Code's skills/.trash, the Claude app's skills/synced. None
# is the payload's to fix, so the scan reads only what lib/synced-trees.sh lists (claude-config#2750).
for d in state/session-notes/p/s/2721/base/hooks skills/.trash/1-a/s skills/synced/acct/s plugins/cache/x; do
  mkdir -p "$T/scan/$d"
  cp "$T/scan/hooks/test-copy.sh" "$T/scan/$d/test-local.sh"
done
mkdir -p "$T/scan/skills/real"
cp "$T/scan/hooks/test-copy.sh" "$T/scan/skills/real/test-real.sh"
found="$(inline_copies "$T/scan")"
case "$found" in
  *test-local.sh*) check "#2750 a copy kept where the sync never carries is not reported" "it was: [$found]" ;;
  *) check "#2750 a copy kept where the sync never carries is not reported" ok ;;
esac
case "$found" in
  *skills/real/test-real.sh:1:*) check "#2750 the same copy in a real skill is reported" ok ;;
  *) check "#2750 the same copy in a real skill is reported" "it found [$found]" ;;
esac

# The real tree: every suite the payload ships, from wherever this copy of it is.
n_suites="$(scanned_suites "$DIR/.." | wc -l | tr -d ' ')"
[ "$n_suites" -gt 50 ] && check "the scan reads the shipped suites ($n_suites of them)" ok \
  || check "the scan reads the shipped suites" "only $n_suites found under $DIR/.., so a clean answer would mean nothing"
found="$(inline_copies "$DIR/..")"
[ -z "$found" ] && check "no suite carries its own copy of the settings lookup" ok \
  || check "no suite carries its own copy of the settings lookup" "ask lib/settings-file.sh (hook_settings_file) instead:
$found"

# ---- the scan read every suite the repository holds under the payload ---------------------------
# The scan walks three trees of the payload, and the count above cannot tell one suite missing
# among hundreds, so a suite kept anywhere else under the payload would carry a copy unread. In a
# checkout the repository is asked for its own list, uncommitted suites included, and each suite on
# it must be one the scan read.
# Asking through lib/repo-files.sh is also what makes scanners-before-push.sh run this suite before
# a push: that gate picks a suite by a line of its code listing the repository's files, so taking
# this section out takes the suite out of the gate (claude-config#3859).
unread_suites() {   # $1 = suites the repository lists, $2 = suites the scan read, both relative to the payload -> those in $1 only
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case $'\n'"$2"$'\n' in *$'\n'"$s"$'\n'*) ;; *) printf '%s\n' "$s" ;; esac
  done <<LISTED
$1
LISTED
}
# Seen to fail first (L1): a suite the repository lists and the scan did not read is named, and
# one the scan read is not.
got="$(unread_suites 'hooks/test-a.sh
agents/test-b.sh
skills/s/test-c.sh' 'hooks/test-a.sh
skills/s/test-c.sh')"
[ "$got" = "agents/test-b.sh" ] && check "#3859 a suite the repository lists that the scan did not read is named" ok \
  || check "#3859 a suite the repository lists that the scan did not read is named" "got [$got]"
got="$(unread_suites 'hooks/test-a.sh' 'hooks/test-a.sh
hooks/test-extra.sh')"
[ -z "$got" ] && check "#3859 a suite the scan read is not named, nor one only the scan found" ok \
  || check "#3859 a suite the scan read is not named, nor one only the scan found" "got [$got]"

# The real tree. Both lists are cut to paths under the payload before they are compared, because the
# repository's root and "$DIR/.." can spell one folder two ways. The pathspec also matches a script
# inside a folder whose name holds test-, so the list is cut to suites by name, as the scan's is.
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$ROOT" ]; then
  PAYLOAD_DIR="$(cd "$DIR/.." && pwd)"
  if repo_list="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 'payload/*test-*.sh' 2>&1)"; then
    repo_suites="$(printf '%s\n' "$repo_list" | grep '/test-[^/]*\.sh$' | sed 's|^payload/||')"
    read_suites="$(scanned_suites "$PAYLOAD_DIR" | awk -v p="$PAYLOAD_DIR/" 'index($0, p) == 1 { print substr($0, length(p) + 1) }')"
    if [ -z "$repo_suites" ]; then
      check "#3859 the repository lists its suites under the payload" "lib/repo-files.sh listed none under $ROOT/payload, so the comparison below would mean nothing"
    else
      missed="$(unread_suites "$repo_suites" "$read_suites")"
      [ -z "$missed" ] && check "#3859 the scan read every suite the repository holds under the payload" ok \
        || check "#3859 the scan read every suite the repository holds under the payload" "these are read by no scan for a copy of the settings lookup; move them under hooks, skills or mods, or widen scanned_suites:
$missed"
    fi
  else
    check "#3859 the repository lists its suites under the payload" "lib/repo-files.sh could not list $ROOT: $repo_list"
  fi
else
  # Installed, there is no repository to ask. Said on the runner's agreed line, never skipped in silence.
  printf 'SUITE-PART-UNMEASURED the check that the settings lookup scan read every suite the repository holds under the payload: %s is not the payload of a claude-config checkout (lib/checkout-root.sh), so there is no repository to ask; it runs where the repository is\n' "$DIR/.."
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
