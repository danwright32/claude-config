#!/usr/bin/env bash
# Tests for the one-time spool migration.
#
# It moves records that were keyed on the AGENT's directory to the key their own
# SESSION reads. The cases that matter are the ones where a mistake is silent: a
# record moved somewhere nobody looks is indistinguishable from one that was
# never moved, and a record dropped in transit leaves no trace at all.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE="$DIR/migrate-issue-spool.py"
SPOOL_LIB="$DIR/lib/issue-spool.sh"

pass=0
fail=0
check() {
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool"
export CLAUDE_PROJECTS_DIR="$TMPROOT/projects"
export CLAUDE_ISSUE_SPOOL_LIB="$SPOOL_LIB"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR" "$CLAUDE_PROJECTS_DIR/-a-project"

# The session this record belongs to, discoverable exactly as it is in the real
# layout: a transcript sitting directly in its project directory.
touch "$CLAUDE_PROJECTS_DIR/-a-project/session-aaa.jsonl"
DEST="$(bash "$SPOOL_LIB" key "$TMPROOT" "$CLAUDE_PROJECTS_DIR/-a-project/any-session.jsonl")"
WRONG="wrongkey00001"

# One record per LINE. Without the newline all three fuse into a single
# unreadable line, and every assertion below then passes or fails for a reason
# that has nothing to do with the migration.
rec() { printf '{"ts":"2026-08-29T10:00:00Z","status":"found","session":"%s","findings":["%s"]}\n' "$1" "$2"; }

seed() {
  rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
  { rec session-aaa "a finding whose session is known"
    rec session-zzz "a finding whose session is nowhere"
    printf 'not a record at all\n'
  } > "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
}

# A dry run must change nothing at all. It is the only thing standing between a
# person and an irreversible move of their whole spool.
seed
before="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl")"
out_dry="$(python3 "$MIGRATE" 2>&1)"
[ "$before" = "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl")" ] \
  && check "a dry run changes nothing" ok \
  || check "a dry run changes nothing" "the file was rewritten"
contains "DRY RUN" "$out_dry" \
  && check "a dry run says so" ok \
  || check "a dry run says so" "out=${out_dry:0:200}"
[ ! -f "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" ] \
  && check "a dry run creates no destination" ok \
  || check "a dry run creates no destination" "it wrote $DEST"

# The move itself.
seed
out_apply="$(python3 "$MIGRATE" --apply 2>&1)"
contains "a finding whose session is known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" 2>/dev/null)" \
  && check "a record moves to the key its session reads" ok \
  || check "a record moves to the key its session reads" "not in $DEST"

# The positive control: it must have LEFT the old key, not been copied. A copy
# is shown twice and filed once, which strands the other half.
contains "a finding whose session is known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "the moved record really left the old key" "it was copied, not moved" \
  || check "the moved record really left the old key" ok

# A session that cannot be located must stay put. Guessing would move it
# somewhere nobody looks, which is the fault being repaired.
contains "a finding whose session is nowhere" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "a record whose session is unknown stays put" ok \
  || check "a record whose session is unknown stays put" "it was moved anyway"

# An unreadable line is not a record anyone has classified, so it is not moved
# and not dropped.
contains "not a record at all" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "an unreadable line is kept where it was" ok \
  || check "an unreadable line is kept where it was" "it vanished"

# Nothing may be lost in transit, and the tool must SAY the count rather than
# leave it to be discovered.
contains "3 record(s) before, 3 after" "$out_apply" \
  && check "the move reports its own record count" ok \
  || check "the move reports its own record count" "out=${out_apply: -200}"

# Running it twice must be safe: the second run finds nothing left to move.
out_twice="$(python3 "$MIGRATE" --apply 2>&1)"
contains "moving: 0" "$out_twice" \
  && check "running it again moves nothing" ok \
  || check "running it again moves nothing" "out=${out_twice: -200}"
after_twice="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" 2>/dev/null | grep -c "session is known" || true)"
[ "$after_twice" = "1" ] \
  && check "running it again does not duplicate a record" ok \
  || check "running it again does not duplicate a record" "$after_twice copies"

# The key must come from the library, never from a second implementation here.
# Point the tool at a library that answers differently and the destination must
# follow it: if it does not, this file is computing its own key.
seed
FAKELIB="$TMPROOT/fake-lib.sh"
printf '#!/usr/bin/env bash\necho fakekey99999\n' > "$FAKELIB"
chmod +x "$FAKELIB"
CLAUDE_ISSUE_SPOOL_LIB="$FAKELIB" python3 "$MIGRATE" --apply >/dev/null 2>&1
[ -f "$CLAUDE_ISSUE_SPOOL_DIR/fakekey99999.jsonl" ] \
  && check "the destination key comes from the spool library" ok \
  || check "the destination key comes from the spool library" "it computed its own"

# A library that answers with NOTHING must stop the run, not send every record
# to an empty-named file.
seed
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKELIB"
CLAUDE_ISSUE_SPOOL_LIB="$FAKELIB" python3 "$MIGRATE" --apply >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && check "a library that gives no key stops the run" ok \
  || check "a library that gives no key stops the run" "it exited 0"
[ -f "$CLAUDE_ISSUE_SPOOL_DIR/.jsonl" ] \
  && check "no record is sent to an empty key" "it created .jsonl" \
  || check "no record is sent to an empty key" ok

echo
echo "passed: $pass  failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
