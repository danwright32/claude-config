#!/usr/bin/env bash
# The expanded copy of a mirrored tree is built ONCE per apply, and rebuilt whenever its source
# changes (claude-config#2661).
#
# apply_source_dir hands the apply the payload tree as it should land on this Mac: the payload
# itself when no file in it carries the home path placeholder, otherwise a scratch copy with this
# Mac's home path put back. It used to work that answer out afresh on every call, and an apply calls
# it once per step for each tree (the deletion dry run, the locally ahead dry run, the apply itself)
# plus once per mod folder on this Mac. Measured on 2026-11-10 with this repository's own payload,
# one apply rebuilt the hooks and skills copies three times each (about 0.35 s a build) and read the
# whole mods tree 26 times looking for the placeholder (about 0.08 s a read).
#
# So the answer is now remembered for the rest of the apply, and a remembered answer is believed
# only while nothing under the source has a newer change time than the moment it was started: a
# write, a deletion, a rename or a mode change all move a change time, and unlike a modification
# time nothing (rsync -a, git, touch) can set one back.
#
# This suite holds:
#   1. Reuse: a second call in the same apply builds nothing and returns the same copy.
#   2. Every way the source can change makes the next call rebuild: an edit that keeps the old
#      modification time (as rsync -a writes), a deletion, a new file, the placeholder going away
#      and arriving, and a change made WHILE the copy was being built.
#   3. A new apply starts afresh (the answer is cached for that apply only).
#   4. Wired, not just built (L3): a real pull and a real sync, under an rsync that writes down what
#      it was handed, build each tree's expanded copy at most once per run, and what they install
#      carries this Mac's own home path.
# The function under test is read out of claude-sync itself, never copied.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

SCRIPT="${SCRIPT:-$ROOT/claude-sync}"
pass=0; fail=0
ok(){ pass=$((pass + 1)); echo "ok: $1"; }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,25p' | sed 's/^/    /'; return 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-apply-source-cache.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- the shipped function, read out of claude-sync ----
LIB="$WORK/lib.sh"
{
  grep -E '^TOKEN=' "$SCRIPT"
  awk '/^LOCAL_FILE_GLOBS=/,/^unset _lg$/' "$SCRIPT"
  awk '/^home_literal_swap\(\)/,/^}$/' "$SCRIPT"
  grep -E '^detok\(\)' "$SCRIPT"
  grep -E '^expanded_root_name\(\)' "$SCRIPT"
  awk '/^apply_source_dir\(\)/,/^}$/' "$SCRIPT"
} > "$LIB"
if grep -q '^apply_source_dir()' "$LIB" && grep -q '^COMMON_EXCLUDES=' "$LIB" && grep -q '^TOKEN=' "$LIB"; then
  ok "claude-sync defines apply_source_dir, TOKEN and COMMON_EXCLUDES where this suite reads them"
else
  bad "claude-sync defines apply_source_dir, TOKEN and COMMON_EXCLUDES where this suite reads them" "$(head -5 "$LIB")"
  echo "SUITE-RESULT passed=$pass failed=$fail"; exit 1
fi
# The scratch helpers claude-sync defines far from here, as the two lines that matter.
scratch_home_ready(){ mkdir -p "$WORK/scratch"; printf '%s' "$WORK/scratch"; }
scratch_file(){ mktemp "$WORK/scratch/claude-sync-work.XXXXXXXX"; }
# shellcheck source=/dev/null
. "$LIB"

# An rsync that writes down every expanded copy it is asked to build, then runs the real one. A
# file named in $WORK/during is appended to once the copy is made, the way an edit landing mid
# build would.
REAL_RSYNC="$(command -v rsync)"; mkdir -p "$WORK/bin"
cat > "$WORK/bin/rsync" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
case "\$last" in *claude-sync-expand*) echo "\$last" >> "$WORK/builds" ;; esac
"$REAL_RSYNC" "\$@"; rc=\$?
if [ -s "$WORK/during" ]; then echo "edited mid build" >> "\$(cat "$WORK/during")"; : > "$WORK/during"; fi
exit \$rc
EOF
chmod +x "$WORK/bin/rsync"
PATH="$WORK/bin:$PATH"
builds(){ local n; n="$(grep -c . "$WORK/builds" 2>/dev/null)"; printf '%s' "${n:-0}"; }

CLAUDE_HOME="$WORK/home"
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD/hooks/lib" "$PAYLOAD/agents"
printf 'run %s/hooks/lib/x.sh\n' "$TOKEN" > "$PAYLOAD/hooks/uses-home.sh"
echo 'plain' > "$PAYLOAD/hooks/lib/x.sh"
echo 'agent' > "$PAYLOAD/agents/a.md"
APPLY_SOURCE_GEN=apply-1
: > "$WORK/builds"

# ---- 1. reuse ----
first="$(apply_source_dir hooks)"
second="$(apply_source_dir hooks)"
third="$(apply_source_dir hooks)"
n="$(builds)"
if [ "$first" != "$PAYLOAD/hooks" ] && [ "$(cat "$first/uses-home.sh" 2>/dev/null)" = "run $CLAUDE_HOME/hooks/lib/x.sh" ]; then
  ok "a tree carrying the placeholder is handed over as a copy with this Mac's home path in it"
else
  bad "a tree carrying the placeholder is handed over as a copy with this Mac's home path in it" "dir=$first: $(cat "$first/uses-home.sh" 2>&1)"
fi
if [ "$n" = 1 ] && [ "$first" = "$second" ] && [ "$second" = "$third" ]; then
  ok "three calls in one apply build the expanded copy once"
else
  bad "three calls in one apply build the expanded copy once" "builds=$n: $(cat "$WORK/builds")"
fi
p1="$(apply_source_dir agents)"; p2="$(apply_source_dir agents)"
if [ "$p1" = "$PAYLOAD/agents" ] && [ "$p2" = "$PAYLOAD/agents" ] && [ "$(builds)" = "$n" ]; then
  ok "a tree with no placeholder is handed over as the payload itself, with no copy made"
else
  bad "a tree with no placeholder is handed over as the payload itself, with no copy made" "$p1 / $p2, builds=$(builds)"
fi

# ---- 2. every way the source changes makes the next call rebuild ----
expect_rebuild(){ # expect_rebuild <what> <file under the copy> <expected content, or ABSENT>
  local before got out
  before="$(builds)"
  out="$(apply_source_dir hooks)"
  if [ "$3" = ABSENT ]; then
    if [ -e "$out/$2" ]; then got=present; else got=ABSENT; fi
  else
    got="$(cat "$out/$2" 2>/dev/null)"
  fi
  if [ "$(builds)" -gt "$before" ] && [ "$got" = "$3" ]; then
    ok "$1 makes the next call rebuild the copy"
  else
    bad "$1 makes the next call rebuild the copy" "builds before=$before after=$(builds), $2 reads '$got', wanted '$3'"
  fi
}
# rsync -a writes the new bytes and then sets the OLD modification time back, on the file and, when
# it copies a whole tree as the send does, on its folder too, which is the case a check on
# modification times would miss.
printf 'run %s/hooks/lib/y.sh\n' "$TOKEN" > "$WORK/staged.sh"
touch -t 202001010000 "$WORK/staged.sh"
"$REAL_RSYNC" -a "$WORK/staged.sh" "$PAYLOAD/hooks/uses-home.sh"
touch -t 202001010000 "$PAYLOAD/hooks"
expect_rebuild "an edit that keeps the old modification time" uses-home.sh "run $CLAUDE_HOME/hooks/lib/y.sh"
echo 'new' > "$PAYLOAD/hooks/lib/new.sh"
expect_rebuild "a new file" lib/new.sh "new"
rm -f "$PAYLOAD/hooks/lib/new.sh"
expect_rebuild "a deletion" lib/new.sh ABSENT
# The rsync stand in edits the source just after copying it, so the copy this call hands back is
# already behind the source; the next call must see that and rebuild.
echo 'touch' >> "$PAYLOAD/hooks/lib/x.sh"
echo "$PAYLOAD/hooks/lib/x.sh" > "$WORK/during"
apply_source_dir hooks >/dev/null
expect_rebuild "an edit landing while the copy was being built" lib/x.sh "$(cat "$PAYLOAD/hooks/lib/x.sh")"
echo 'run nothing' > "$PAYLOAD/hooks/uses-home.sh"
out="$(apply_source_dir hooks)"
if [ "$out" = "$PAYLOAD/hooks" ]; then
  ok "a tree whose last placeholder went away is handed over as the payload itself"
else
  bad "a tree whose last placeholder went away is handed over as the payload itself" "got $out"
fi
printf 'see %s\n' "$TOKEN" > "$PAYLOAD/agents/now-home.md"
out="$(apply_source_dir agents)"
if [ "$out" != "$PAYLOAD/agents" ] && [ "$(cat "$out/now-home.md" 2>/dev/null)" = "see $CLAUDE_HOME" ]; then
  ok "a tree that gains a placeholder is handed over as an expanded copy"
else
  bad "a tree that gains a placeholder is handed over as an expanded copy" "got $out"
fi

# ---- 3. a new apply starts afresh ----
apply_source_dir agents >/dev/null
before="$(builds)"
APPLY_SOURCE_GEN=apply-2
apply_source_dir agents >/dev/null
apply_source_dir agents >/dev/null
if [ "$(builds)" -eq $((before + 1)) ]; then
  ok "the next apply builds its own copy once, rather than reusing the last apply's"
else
  bad "the next apply builds its own copy once, rather than reusing the last apply's" "builds before=$before after=$(builds)"
fi

# ---- 4. wired: a real pull and a real sync build each tree's copy at most once ----
export SYNC_CLONE_REGISTRY="$WORK/no-such-directory/clone-registry" SYNC_ZSHRC="$WORK/zshrc-guard" \
  SYNC_SCRATCH_ROOT="$WORK/scratch-root" SYNC_NO_SEND_TESTS=1 SYNC_NO_HOOK_TESTS=1 \
  SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here" SYNC_WATCH_PID_FILE="$WORK/watch-pid-guard" \
  SYNC_HOLD_FILE="$WORK/hold-guard" SYNC_RETIRED_FILE="$WORK/retired-guard" SYNC_LOG_FILE="$WORK/sync-log-guard" \
  SYNC_GH="$WORK/no-such-gh-here" SYNC_CLAUDE_BIN="$WORK/no-such-claude-here" SYNC_LAUNCHAGENTS="$WORK/launchagents-guard" \
  SYNC_MANAGED_SETTINGS="$WORK/managed-settings-guard.json" SYNC_PS_FIXTURE="$WORK/ps-guard" SYNC_NO_NOTIFY=1
export CLAUDE_SUITE_RUN_ID="${CLAUDE_SUITE_RUN_ID:-test-apply-source-cache}"
unset APPLY_SOURCE_GEN SYNC_NO_GIT
mkdir -p "$SYNC_SCRATCH_ROOT"; printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"; : > "$SYNC_PS_FIXTURE"
git init -q --bare "$WORK/bare.git"
git clone -q "$WORK/bare.git" "$WORK/repoA" 2>/dev/null
git clone -q "$WORK/bare.git" "$WORK/repoB" 2>/dev/null
HA="$WORK/homeA"; HB="$WORK/homeB"
mkdir -p "$HA/hooks/lib" "$HA/skills/s1" "$HA/agents" "$HA/commands" "$HA/mods/m1" "$HA/mods/m2" "$HA/mods/m3" "$HB"
printf 'run %s/hooks/lib/x.sh\n' "$HA" > "$HA/hooks/uses-home.sh"; chmod +x "$HA/hooks/uses-home.sh"
echo 'echo x' > "$HA/hooks/lib/x.sh"; echo 'gone' > "$HA/hooks/retired.sh"
printf -- '---\nname: s1\ndescription: x\n---\nsee %s/skills\n' "$HA" > "$HA/skills/s1/SKILL.md"
echo A > "$HA/agents/a.md"; echo C > "$HA/commands/c.md"
for m in m1 m2 m3; do printf '{"name":"%s"}\n' "$m" > "$HA/mods/$m/plugin.json"; done
echo '# rules' > "$HA/CLAUDE.md"; echo '{"hooks":{}}' > "$HA/settings.json"; echo '{"hooks":{}}' > "$HB/settings.json"
run(){ CLAUDE_HOME="$1" SYNC_REPO="$2" bash "$SCRIPT" "$3" > "$WORK/$4.out" 2>&1; }
run "$HA" "$WORK/repoA" sync a1; run "$HB" "$WORK/repoB" pull b1
# A deletion in the history, so the apply runs every step that reads the expanded copy.
rm -f "$HA/hooks/retired.sh"; run "$HA" "$WORK/repoA" sync a2; run "$HB" "$WORK/repoB" pull b2
echo 'echo y' > "$HA/hooks/lib/x.sh"; echo '# rules v2' > "$HA/CLAUDE.md"
run "$HA" "$WORK/repoA" sync a3
# Each build is named by its run (claude-sync-expand.<pid>/<tree>/), so per run and tree is the count.
per_run(){ sed -n 's|.*claude-sync-expand\.\([0-9]*\)/\([a-z]*\)/*$|\1 \2|p' "$WORK/builds" | sort | uniq -c | sort -rn; }
: > "$WORK/builds"
run "$HB" "$WORK/repoB" pull b3; rc_b=$?
pull_counts="$(per_run)"
: > "$WORK/builds"
echo '# rules v3' > "$HA/CLAUDE.md"
run "$HA" "$WORK/repoA" sync a4; rc_a=$?
sync_counts="$(per_run)"
installed="$(cat "$HB/hooks/uses-home.sh" 2>/dev/null)"; skill="$(tail -1 "$HB/skills/s1/SKILL.md" 2>/dev/null)"
if [ "$rc_b" -ne 0 ] || [ "$(cat "$HB/hooks/lib/x.sh" 2>/dev/null)" != 'echo y' ] || [ ! -d "$HB/mods/m3" ]; then
  bad "fixture: the counted pull ran and received the edit" "exit $rc_b: $(tail -5 "$WORK/b3.out")"
elif [ "$installed" = "run $HB/hooks/lib/x.sh" ] && [ "$skill" = "see $HB/skills" ]; then
  ok "a pull installs hooks and skills with this Mac's own home path"
else
  bad "a pull installs hooks and skills with this Mac's own home path" "hooks: $installed / skills: $skill"
fi
if [ -z "$pull_counts" ]; then
  bad "fixture: the counted pull built an expanded copy at all (else the count proves nothing)" "$(tail -5 "$WORK/b3.out")"
elif [ "$(printf '%s\n' "$pull_counts" | awk 'NR==1 {print $1}')" = 1 ]; then
  ok "a pull builds each tree's expanded copy once ($(printf '%s' "$pull_counts" | tr -s ' \n' ' '))"
else
  bad "a pull builds each tree's expanded copy once, not once per step that reads it" "$pull_counts"
fi
if [ "$rc_a" -ne 0 ] || [ -z "$sync_counts" ]; then
  bad "fixture: the counted sync ran and built an expanded copy" "exit $rc_a: $(tail -5 "$WORK/a4.out")"
elif [ "$(printf '%s\n' "$sync_counts" | awk 'NR==1 {print $1}')" = 1 ]; then
  ok "a sync builds each tree's expanded copy once per run ($(printf '%s' "$sync_counts" | tr -s ' \n' ' '))"
else
  bad "a sync builds each tree's expanded copy once per run, not once per step that reads it" "$sync_counts"
fi

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
