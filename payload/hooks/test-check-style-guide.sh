#!/usr/bin/env bash
# Tests for the em-dash/en-dash/emoji detector inside check-style-guide.sh.
# Extracts the real python3 detection block out of the hook and feeds it
# synthetic diff text, so we exercise the actual code, not a re-implementation.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-style-guide.sh"

# The extracted detector goes in a directory of this RUN's own, never beside this file
# (claude-config#180). A fixed name in payload/hooks is one path shared by every run on the
# machine: two at once truncate and then delete each other's copy, and the second reads a half
# written file and reports that the detector found nothing. It also put a stray file inside the
# tree the sync mirrors whenever a run was killed between writing it and removing it.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.styleguide.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

# Pull the python3 -c '...' detector body out of the hook into its own file
# (the lines strictly between the opening `findings=...python3 -c '` line and
# the closing `' 2>/dev/null)"` line).
awk '
  /^findings="\$\(printf/ { flag=1; next }
  flag && /2>\/dev\/null\)"$/ { flag=0; next }
  flag { print }
' "$HOOK" > "$WORKDIR/.style-detector.tmp.py"
[ -s "$WORKDIR/.style-detector.tmp.py" ] || { echo "FAIL: could not extract detector block"; exit 1; }

detect() {
  printf '%s' "$1" | python3 "$WORKDIR/.style-detector.tmp.py"
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


# --- end to end: the hook must find the repo even when the session is elsewhere -
# The payload's cwd is the SESSION's directory, not the project's. A session
# rooted somewhere else reaches a project as `cd <repo> && git push`, and reading
# the cwd alone made this check see no work tree and wave the push through with
# no style check at all, silently. The forbidden characters below are written as
# escapes so this file holds no literal one for the hook to catch.
E2E="$(mktemp -d)"
mk_style_repo() {
  # $1 = file content
  local root; root="$(mktemp -d)"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@t.t; git config user.name t
    echo baseline > README.md
    git add -A; git commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin main
    mkdir -p app
    printf '%s\n' "$1" > app/copy.ts
    git add -A; git commit -qm copy
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
run_style_hook() {
  # $1 cwd, $2 command -> sets STYLE_CODE
  local p
  p="$(HK_CMD="$2" HK_CWD="$1" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  printf '%s' "$p" | bash "$HOOK" >/dev/null 2>&1
  STYLE_CODE=$?
}
want_style_code() {
  if [ "$STYLE_CODE" = "$1" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: expected exit $1, got $STYLE_CODE"; fi
}

BAD="$(python3 -c 'print("const label = \"Loading — please wait\";")')"
W="$(mk_style_repo "$BAD")"
run_style_hook "$W" "git push"
want_style_code 2 "canary: a forbidden character blocks a plain push"

W="$(mk_style_repo "$BAD")"
run_style_hook "$E2E" "cd $W && git push"
want_style_code 2 "cd-then-push from a non-repo cwd must still be checked"

W="$(mk_style_repo "$BAD")"
run_style_hook "$E2E" "git -C $W push"
want_style_code 2 "git -C push from a non-repo cwd must still be checked"

W="$(mk_style_repo 'const label = "Loading, please wait";')"
run_style_hook "$E2E" "cd $W && git push"
want_style_code 0 "clean copy pushed the same way is allowed"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
