#!/usr/bin/env bash
# The payload this repository ships passes claude-sync's own secret scan.
#
# A send runs scan_secrets over everything it is about to publish and refuses outright on a hit,
# so one token SHAPED placeholder blocks every sync from every Mac until somebody notices. That
# happened when claude-config#675 shipped `"token": "REPLACE_BY_RUNNING_tracker.sh_new-token"` in
# skills/tracker/config.example.json: a key named token, then 24 or more identifier characters,
# which is exactly what the scan's assignment pattern looks for. Nothing ran the scan before
# merge; it first ran on the next send.
#
# So this runs the REAL function, cut out of claude-sync by name, never a copy of its patterns,
# which would drift from the scan it stands for (L41). It reads the repository's real
# .secret-allowlist, as the send does, over every file git would carry under payload/ (tracked,
# plus untracked files that are not ignored, so the file just written is judged too, L456).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$ROOT/claude-sync"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-secretscan-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-payload-secret-scan: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The function and the helper it calls, cut from claude-sync by name. die is replaced so a refusal
# is reported here instead of ending this suite (and without the notification the real one posts).
SCAN_SRC="$(sed -n '/^scan_secrets(){/,/^}/p' "$SCRIPT")"
BLANK_SRC="$(sed -n '/^is_blank(){/p' "$SCRIPT")"
case "$SCAN_SRC" in
  *'apat='*'grep -rIoE'*'die '*) check "scan_secrets was cut from claude-sync whole" ok ;;
  *) check "scan_secrets was cut from claude-sync whole" "the extraction found no scan_secrets body, so nothing below would mean anything" ;;
esac
[ -n "$BLANK_SRC" ] && check "is_blank was cut from claude-sync" ok \
  || check "is_blank was cut from claude-sync" "not found"

# run_scan <payload dir> <repo dir holding .secret-allowlist>; prints what the scan said, and
# "SCAN-RC=<n>" last. Run in a subshell with the override switched off explicitly: a
# SYNC_SKIP_SECRET_SCAN inherited from whoever started this suite would pass everything (L439).
run_scan(){
  # Locals, which scan_secrets sees through bash's dynamic scope and which go when this returns.
  local PAYLOAD="$1" SYNC_REPO="$2"
  (
    unset SYNC_SKIP_SECRET_SCAN
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    eval "$BLANK_SRC"
    eval "$SCAN_SRC"
    scan_secrets
  ) 2>&1
  printf 'SCAN-RC=%s\n' "$?"
}

# --- the shipped payload ---------------------------------------------------------
# A copy holding exactly the files git would carry, so an ignored local file (a skill's
# config.local.json, which the sync also leaves out) neither fails nor passes this.
SHIPPED="$TMPROOT/shipped/payload"
mkdir -p "$SHIPPED"
listed="$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" payload)" || listed=""
n=0
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
  mkdir -p "$TMPROOT/shipped/$(dirname "$f")"
  cp "$ROOT/$f" "$TMPROOT/shipped/$f"
  n=$((n+1))
done <<< "$listed"
[ "$n" -ge 100 ] && check "the scan reads the shipped payload ($n files)" ok \
  || check "the scan reads the shipped payload ($n files)" "too few to be the real payload"
[ -f "$SHIPPED/skills/tracker/config.example.json" ] && check "and the tracker's example config is among them" ok \
  || check "and the tracker's example config is among them" "missing, so the case that blocked sync is not being judged"

out="$(run_scan "$SHIPPED" "$ROOT")"
case "$out" in
  *'SCAN-RC=0') check "the shipped payload passes claude-sync's secret scan" ok ;;
  *) check "the shipped payload passes claude-sync's secret scan" "a send would refuse: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# --- the controls (L1) -----------------------------------------------------------
# The same run refuses a planted credential, so its silence above is a verdict.
mkdir -p "$TMPROOT/planted/payload/skills/x" "$TMPROOT/planted/repo"
# Assembled from halves so this file never holds a token shaped run of its own.
printf '{ "token": "%s%s" }\n' "Ab3dEf6hIj9kLm2n" "Op5qRs8tUv1wXy4zAb7cDe0f" > "$TMPROOT/planted/payload/skills/x/c.json"
out="$(run_scan "$TMPROOT/planted/payload" "$TMPROOT/planted/repo")"
case "$out" in
  *'possible secret found in: skills/x/c.json'*'SCAN-RC=1') check "control: the same scan refuses a planted token and names its file" ok ;;
  *) check "control: the same scan refuses a planted token and names its file" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# And it refuses the placeholder that blocked sync, so this suite would have caught it.
mkdir -p "$TMPROOT/old/payload/skills/tracker" "$TMPROOT/old/repo"
printf '{\n  "url": "x",\n  "token": "REPLACE_BY_RUNNING_tracker.sh_new-token"\n}\n' > "$TMPROOT/old/payload/skills/tracker/config.example.json"
out="$(run_scan "$TMPROOT/old/payload" "$TMPROOT/old/repo")"
case "$out" in
  *'possible secret found in: skills/tracker/config.example.json'*'SCAN-RC=1') check "control: the scan refuses the token shaped placeholder that blocked sync after #675" ok ;;
  *) check "control: the scan refuses the token shaped placeholder that blocked sync after #675" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# Every path that ends a scan WITHOUT refusing clears the record of the last refusal
# (claude-config#947), or a later pull blames a refusal that no longer applies. The early returns
# are the paths a test of the whole tool cannot easily reach, so they are driven here.
run_scan_recorded(){   # $1 = payload dir  $2 = repo dir  $3 = SYNC_SKIP_SECRET_SCAN value
  local PAYLOAD="$1" SYNC_REPO="$2" SEND_REFUSED_FILE="$2/.send-refused" SYNC_SKIP_SECRET_SCAN="$3"
  printf '1\tskills/x/c.json\n' > "$SEND_REFUSED_FILE"
  (
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    eval "$BLANK_SRC"
    eval "$SCAN_SRC"
    scan_secrets
  ) >/dev/null 2>&1
  [ -e "$SEND_REFUSED_FILE" ] && printf 'still there' || printf 'cleared'
}
mkdir -p "$TMPROOT/rec/repo" "$TMPROOT/rec/clean/payload"
printf 'nothing secret\n' > "$TMPROOT/rec/clean/payload/f.txt"
r="$(run_scan_recorded "$TMPROOT/rec/clean/payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = cleared ] && check "#947 a scan that passes clears the record of the last refusal" ok \
  || check "#947 a scan that passes clears the record of the last refusal" "$r"
r="$(run_scan_recorded "$TMPROOT/rec/no-such-payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = cleared ] && check "#947 so does a scan with no payload to read" ok \
  || check "#947 so does a scan with no payload to read" "$r"
r="$(run_scan_recorded "$TMPROOT/planted/payload" "$TMPROOT/rec/repo" 1)"
[ "$r" = cleared ] && check "#947 so does a send let past the scan with SYNC_SKIP_SECRET_SCAN=1" ok \
  || check "#947 so does a send let past the scan with SYNC_SKIP_SECRET_SCAN=1" "$r"
r="$(run_scan_recorded "$TMPROOT/planted/payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = 'still there' ] && check "#947 control: a scan that refuses keeps it" ok \
  || check "#947 control: a scan that refuses keeps it" "$r"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
