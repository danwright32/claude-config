#!/usr/bin/env bash
# Tests for the check that a payload hook's claude-sync command actually exists on this Mac
# (claude-config#379).
#
# The payload and the tool travel separately: the payload reaches a Mac through an apply, while
# each clone of the tool updates when that clone next pulls. So a config change can ship a hook
# calling a command the deployed copy does not have. Measured 2026-09-11:
# payload/hooks/lesson-entry-check.sh calls `claude-sync lesson-faults`, and ~/claude-config-sync
# answered `unknown command 'lesson-faults'` for hours because it had not pulled since the command
# was added. The hook read that refusal as a verdict about the lesson and blocked the edit saying
# the file could not publish, which is a claim it never measured (L11, L640).
#
# The required list is DERIVED from the hooks rather than written beside them, because a registry
# maintained by hand checks only what it lists and anything missing from it is exempt from the
# check meant to catch it (L41, L96).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/sync-commands.sh"
REPO="$(cd "$DIR/../.." && pwd)"
SYNC="$REPO/claude-sync"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3'" ;; esac; }

[ -f "$LIB" ] || { echo "FAIL: no lib at $LIB"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
# shellcheck source=lib/sync-commands.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sync-commands.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

echo "sync commands: what a tool offers, read from the tool"

# Derived from the dispatch itself, never from the usage text beside it, or a command that exists
# and is undocumented reads as missing and a documented one that was removed reads as present.
offered="$(sc_commands_offered "$SYNC")"
for c in pull push sync status lesson-faults check-lessons lesson-short-forms; do
  case "
$offered" in *"
$c"*) check "the real tool offers '$c'" ok ;;
    *) check "the real tool offers '$c'" "it does not, out of: $(printf '%s' "$offered" | tr '\n' ' ')" ;;
  esac
done
case "
$offered" in *"
no-such-command"*) check "and does not claim a command it has never had" "it did" ;;
  *) check "and does not claim a command it has never had" ok ;;
esac
# A tool it cannot read answers NOTHING, and nothing must not read as "offers everything": that
# would make this whole check pass on every broken clone (L98).
want="$(sc_commands_offered "$FIX/no-such-tool")"
[ -z "$want" ] && check "a tool it cannot read offers nothing, rather than everything" ok \
               || check "a tool it cannot read offers nothing, rather than everything" "got: $want"

echo "sync commands: what the hooks need, read from the hooks"

mkdir -p "$FIX/hooks"
cat > "$FIX/hooks/a.sh" <<'EOF'
sync="$clone/claude-sync"
out="$("$sync" lesson-faults 2>&1)"
other="$("$sync" check-lessons)"
EOF
cat > "$FIX/hooks/b.sh" <<'EOF'
# This comment mentions claude-sync lesson-faults and must not count as a call.
echo "run claude-sync status to see where things stand"
EOF
needed="$(sc_commands_needed "$FIX/hooks" "$SYNC")"
case "
$needed" in *"
lesson-faults"*) check "a command a hook calls is found" ok ;;
  *) check "a command a hook calls is found" "got: $(printf '%s' "$needed" | tr '\n' ' ')" ;;
esac
case "
$needed" in *"
check-lessons"*) check "and so is a second one in the same hook" ok ;;
  *) check "and so is a second one in the same hook" "got: $(printf '%s' "$needed" | tr '\n' ' ')" ;;
esac
# A comment is prose about a command, not a call. A file explaining what to run has to write the
# command down, and reading that as a dependency is the shape where a script matches itself (L245).
case "
$needed" in *"
status"*) check "a command named only in a comment or a message is not a dependency" "status was counted" ;;
  *) check "a command named only in a comment or a message is not a dependency" ok ;;
esac

echo "sync commands: the verdict, and the message"

# The state the issue is about: a clone that is simply older than the payload it has just received.
mkdir -p "$FIX/oldclone"
cat > "$FIX/oldclone/claude-sync" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-help}"
case "$cmd" in
  pull) ;;
  push) ;;
  status) ;;
  check-lessons) ;;
  *) echo "unknown command" >&2; exit 1 ;;
esac
EOF
chmod +x "$FIX/oldclone/claude-sync"
out="$(sc_report_missing "$FIX/hooks" "$SYNC" "$FIX/oldclone/claude-sync")"
says "a clone missing a command the hooks call is reported" "$out" "lesson-faults"
says "and the clone is named, so the right one gets updated" "$out" "$FIX/oldclone"
says "and the remedy is the command to run there" "$out" "git -C"
case "$out" in *check-lessons*) check "and a command it DOES have is not reported" "check-lessons was named" ;;
  *) check "and a command it DOES have is not reported" ok ;; esac

# The control. A clone that has everything says nothing, or the line is on every apply and stops
# being read (L36).
out="$(sc_report_missing "$FIX/hooks" "$SYNC" "$SYNC")"
[ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
  && check "a clone that has everything is not reported" ok \
  || check "a clone that has everything is not reported" "it said: $out"

# A clone this cannot read at all is its own answer: "could not be asked" and "has everything" are
# the same silence otherwise (L98, L11).
out="$(sc_report_missing "$FIX/hooks" "$SYNC" "$FIX/gone/claude-sync")"
says "a clone that cannot be read says so rather than passing" "$out" "could not"

echo "sync commands: and the real payload against the real tool"

# The whole point, run where it ships: every claude-sync command this repo's own hooks call must
# exist in this repo's own claude-sync, or the config is shipping a call nothing can answer.
out="$(sc_report_missing "$REPO/payload/hooks" "$SYNC" "$SYNC")"
[ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
  && check "every command this payload's hooks call exists in this tool" ok \
  || check "every command this payload's hooks call exists in this tool" "$out"
# A derivation that found NOTHING would satisfy that at once and read exactly like a payload whose
# hooks call nothing (L98).
n="$(sc_commands_needed "$REPO/payload/hooks" "$SYNC" | grep -c . || true)"
[ "${n:-0}" -ge 1 ] \
  && check "and the payload really does call at least one ($n)" ok \
  || check "and the payload really does call at least one ($n)" "it found none"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
