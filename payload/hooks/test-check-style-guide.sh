#!/usr/bin/env bash
# Tests for the em-dash/en-dash/emoji detector inside check-style-guide.sh.
# Extracts the real python3 detection block out of the hook and feeds it
# synthetic diff text, so we exercise the actual code, not a re-implementation.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-style-guide.sh"

# Pull the python3 -c '...' detector body out of the hook into its own file
# (the lines strictly between the opening `findings=...python3 -c '` line and
# the closing `' 2>/dev/null)"` line).
awk '
  /^findings="\$\(printf/ { flag=1; next }
  flag && /2>\/dev\/null\)"$/ { flag=0; next }
  flag { print }
' "$HOOK" > "$DIR/.style-detector.tmp.py"
[ -s "$DIR/.style-detector.tmp.py" ] || { echo "FAIL: could not extract detector block"; exit 1; }

detect() {
  printf '%s' "$1" | python3 "$DIR/.style-detector.tmp.py"
}

pass=0
fail=0
want_flag() {
  local desc="$1" diff="$2"
  local out
  out="$(detect "$diff")"
  if [ -n "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected a finding: $desc"; fi
}
want_clean() {
  local desc="$1" diff="$2"
  local out
  out="$(detect "$diff")"
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected no finding: $desc -> got: $out"; fi
}

# --- em dash / en dash on a newly added line ---
want_flag "em dash in new copy" "+++ b/app/copy.ts
+const label = \"Loading — please wait\";"

want_flag "en dash in new copy" "+++ b/app/copy.ts
+const range = \"9–5\";"

# --- emoji on a newly added line ---
want_flag "emoji in new copy" "+++ b/app/alert.ts
+const msg = \"Deploy succeeded 🎉\";"

# --- removed lines with a dash must NOT flag (only additions matter) ---
want_clean "dash only on a removed line" "+++ b/app/copy.ts
-const label = \"Loading — please wait\";
+const label = \"Loading, please wait\";"

# --- ordinary hyphenated words must NOT flag (ASCII hyphen, not em/en dash) ---
want_clean "ascii hyphen in compound word" "+++ b/app/copy.ts
+const label = \"self-aware, well-known\";"

# --- untracked new-file block format must also be scanned ---
want_flag "em dash in a brand-new untracked file" "--- NEW FILE: app/new.ts ---
+export const x = \"a — b\";"

want_clean "plain new file with no violations" "--- NEW FILE: app/new.ts ---
+export const x = 1;"

rm -f "$DIR/.style-detector.tmp.py"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
