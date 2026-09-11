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
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. `$DIR/../..` is the repo in the first and the HOME DIRECTORY in the second, so a suite that
# assumes the first walks all of $HOME in the second. Measured 2026-09-11: that is what made
# `claude-sync recheck` exceed its 30 minute ceiling and report the whole config unverified.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass: this suite is about the repo, and the installed copy is not one.
REPO="$(cd "$DIR/../.." && pwd)"
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-sync-commands: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi
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

# A PREFIX of a real command is not that command. `clean` is a prefix of `clean-backups` and `in`
# of `install-autosync`, and a membership test matching a prefix reported both as dependencies of
# this repo's own hooks when nothing calls either (L135, L263). Measured on the real tool, so this
# cannot pass against a fixture that happens to have no such pair.
cat > "$FIX/hooks/c.sh" <<'EOF'
out="$("$tool" clean)"
other="$("$tool" in)"
EOF
needed="$(sc_commands_needed "$FIX/hooks" "$SYNC")"
case "
$needed" in *"
clean
"*|*"
clean") check "a prefix of a real command is not counted as one" "clean was counted" ;;
  *) check "a prefix of a real command is not counted as one" ok ;; esac
case "
$needed" in *"
in
"*|*"
in") check "and neither is a prefix of another" "in was counted" ;;
  *) check "and neither is a prefix of another" ok ;; esac
rm -f "$FIX/hooks/c.sh"

# A variable holding something ELSE is not the tool, however much its name or its value looks like
# it. `git -C "$repo" status` is not a claude-sync command, and a throwaway directory whose mktemp
# template happens to hold the word claude-sync is not the tool either. Both were counted as
# dependencies before this, which is a claim the check never measured (L11), and both happen to
# name commands that exist everywhere, so it would have been wrong and silent.
cat > "$FIX/hooks/d.sh" <<'EOF'
repo="/some/checkout"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.XXXX")"
git -C "$repo" status
"$scratch" lesson-faults
EOF
needed="$(sc_commands_needed "$FIX/hooks" "$SYNC")"
case "
$needed" in *"
status
"*|*"
status") check "a git command through another variable is not a claude-sync one" "status was counted" ;;
  *) check "a git command through another variable is not a claude-sync one" ok ;; esac
# The positive control in the same fixture: a.sh still assigns a path ENDING in claude-sync and its
# command is still found, so the rule above narrowed rather than switched everything off (L159).
case "
$needed" in *"
lesson-faults"*) check "and a variable that really is the tool still counts" ok ;;
  *) check "and a variable that really is the tool still counts" "got: $(printf '%s' "$needed" | tr '\n' ' ')" ;; esac
rm -f "$FIX/hooks/d.sh"

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
