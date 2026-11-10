#!/usr/bin/env bash
# The mirrored trees go through ONE rsync per step, and that one call does exactly what one call per
# tree did (claude-config#2614).
#
# Every step of a sync that compares or copies the mirrored trees (hooks, agents, commands, audits,
# mods) used to start one rsync per tree. Measured 2026-11-10 on the personal MacBook, a local rsync
# cost about 35 ms however little it moved, almost all of it the tool starting and waiting on its own
# second process, so on a small tree that fixed cost was the whole price: 16 rsync runs were a third
# of a sync. mirror_rsync_go names every
# tree in one call instead, each without its trailing slash so it lands under its own name, with the
# tree's own anchored excludes rewritten under that name.
#
# That is only a speedup if nothing else changes, so this suite holds the equivalence directly:
#   1. For every flag set the tool uses, against every rsync on this machine, one combined call leaves
#      the destination exactly as one call per tree does (names, modes, sizes, bytes, and times where
#      the flags keep them), and itemizes the same lines once each is read back per tree.
#   2. A tree that is a symbolic link, at either end, is still run on its own with its trailing slash,
#      because without one rsync copies the link itself and would replace a linked folder.
#   3. An unanchored exclude handed for one tree is refused, since in a combined call it would reach
#      every tree.
#   4. A failing rsync's status reaches the caller.
#   5. Wired, not just built (L3): a real sync, run under an rsync that counts itself, starts one rsync
#      per step for the mirrored trees, never one per tree.
# The helpers are read out of claude-sync itself, never copied, so this tests the shipped code.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-mirror-rsync.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- the shipped helpers and the shipped excludes, read out of claude-sync ----
LIB="$WORK/lib.sh"
{
  awk '/^LOCAL_FILE_GLOBS=/,/^unset _mv$/' "$SCRIPT"
  awk '/^MR_[A-Z_]*=/' "$SCRIPT"
  awk '/^mirror_rsync_[a-z_]*\(\)/,/^}$/' "$SCRIPT"
} > "$LIB"
if grep -q '^mirror_rsync_go()' "$LIB" && grep -q '^COMMON_EXCLUDES=' "$LIB"; then
  ok "claude-sync defines mirror_rsync_go and COMMON_EXCLUDES where this suite reads them"
else
  bad "claude-sync defines mirror_rsync_go and COMMON_EXCLUDES where this suite reads them" "$(head -5 "$LIB")"
  echo "SUITE-RESULT passed=$pass failed=$fail"; exit 1
fi
# shellcheck source=/dev/null
. "$LIB"
set -u

# ---- 1. equivalence, per flag set and per rsync ----
TREES=(hooks agents commands audits mods)
mkfix(){ # mkfix <root>: a source and a destination differing in every way an apply or a send meets
  local r="$1"
  mkdir -p "$r/src/hooks/lib" "$r/src/agents/.claude-plugin/types" "$r/src/mods/m1" "$r/src/audits" \
           "$r/dst/hooks/lib" "$r/dst/agents" "$r/dst/commands" "$r/dst/mods/m2" "$r/dst/audits"
  echo a > "$r/src/hooks/a.sh"; chmod 755 "$r/src/hooks/a.sh"
  echo a > "$r/dst/hooks/a.sh"; chmod 644 "$r/dst/hooks/a.sh"       # a mode change
  echo new > "$r/src/hooks/lib/new.py"                               # an addition
  echo gone > "$r/dst/hooks/lib/gone.py"                             # a deletion
  echo held-src > "$r/src/hooks/held.sh"; echo held-dst > "$r/dst/hooks/held.sh"   # held back
  echo moved > "$r/src/hooks/main-to-dev-repos.txt"; echo keep > "$r/dst/hooks/main-to-dev-repos.txt"
  echo moved > "$r/dst/mods/sleep-repos.json"                        # an anchored common exclude
  echo deep > "$r/src/mods/m1/main-to-dev-repos.txt"                 # the same name, not at the top
  echo pyc > "$r/dst/hooks/x.pyc"; echo pyc > "$r/src/agents/y.pyc"
  echo secret > "$r/dst/agents/c.local.json"
  echo ag > "$r/src/agents/r.md"; echo ag-old > "$r/dst/agents/r.md" # same time, other bytes
  echo t > "$r/src/agents/.claude-plugin/types/t.d.ts"
  echo m > "$r/src/mods/m1/p.json"; echo m2 > "$r/dst/mods/m2/p.json"
  echo kept > "$r/dst/mods/m2/kept.json"                             # a held back folder's file
  echo au > "$r/src/audits/a.md"                                     # a tree empty at the other end
  echo cmd > "$r/dst/commands/only-here.md"                          # a tree with no source: untouched
  echo ROOT > "$r/dst/settings.json"; chmod 600 "$r/dst/settings.json"   # beside the trees: untouched
  find "$r" -exec touch -h -t 202101010000 {} +
  touch -t 202001010000 "$r/dst" "$r/dst/hooks" "$r/src/hooks/lib" "$r/src/hooks/a.sh"
}
# The excludes each tree carries of its own, as the callers build them.
tree_ex(){ case "$1" in hooks) echo --exclude=/held.sh ;; mods) echo --exclude=/m2/ ;; esac; }
state(){ # state <dir> [-]: every entry's name, mode, size and time (none with "-"), then every file's bytes
  local gnu="%n %a %Y %s" bsd="%N %p %m %z"
  [ "${2:-}" = - ] && { gnu="%n %a %s"; bsd="%N %p %z"; }
  if stat -c '%d:%i' / >/dev/null 2>&1; then
    (cd "$1" && find . -print0 | sort -z | xargs -0 stat -c "$gnu" && find . -type f -print0 | sort -z | xargs -0 cat)
  else
    (cd "$1" && find . -print0 | sort -z | xargs -0 stat -f "$bsd" && find . -type f -print0 | sort -z | xargs -0 cat)
  fi
}
RSYNCS=()
for r in $(type -a -P rsync 2>/dev/null) /usr/bin/rsync /opt/homebrew/bin/rsync; do
  [ -x "$r" ] || continue
  seen=""; for s in ${RSYNCS[@]+"${RSYNCS[@]}"}; do [ "$s" = "$r" ] && seen=1; done
  [ -n "$seen" ] || RSYNCS+=("$r")
done
[ "${#RSYNCS[@]}" -gt 0 ] || bad "an rsync is on this machine to test against"
for R in ${RSYNCS[@]+"${RSYNCS[@]}"}; do
  rdir="$WORK/rbin-$(printf '%s' "$R" | tr '/' '_')"; mkdir -p "$rdir"; ln -sf "$R" "$rdir/rsync"
  for flags in "-ainc" "-ain --delete" "-ainc --delete" "-ac --delete" "-rlpgoDic --delete"; do
    rm -rf "$WORK/one" "$WORK/many"; mkfix "$WORK/one"; mkfix "$WORK/many"
    # One call per tree, the way every caller ran it before.
    per=""
    for d in "${TREES[@]}"; do
      [ -d "$WORK/one/src/$d" ] || continue
      # shellcheck disable=SC2046,SC2086
      o="$(PATH="$rdir:$PATH" rsync $flags "${COMMON_EXCLUDES[@]}" $(tree_ex "$d") "$WORK/one/src/$d/" "$WORK/one/dst/$d/" 2>/dev/null)"
      per="$per$(printf '%s\n' "$o" | grep -v '^$' | sed "s|^|$d	|")
"
    done
    # One call for every tree.
    mirror_rsync_reset
    for d in "${TREES[@]}"; do
      [ -d "$WORK/many/src/$d" ] || continue
      # shellcheck disable=SC2046
      mirror_rsync_add "$d" "$WORK/many/src/$d" $(tree_ex "$d")
    done
    # shellcheck disable=SC2086
    o="$(PATH="$rdir:$PATH" mirror_rsync_go "$WORK/many/dst" $flags 2>/dev/null)"; rc=$?
    one=""
    for d in "${TREES[@]}"; do
      [ -d "$WORK/many/src/$d" ] || continue
      one="$one$(mirror_rsync_lines "$d" "$o" | sed "s|^|$d	|")
"
    done
    case "$flags" in -a*) mt= ;; *) mt=- ;; esac   # without -t a write takes the time of the write
    s1="$(state "$WORK/one/dst" "$mt")"; s2="$(state "$WORK/many/dst" "$mt")"
    n1="$(printf '%s' "$per" | grep -v '^$' | sort)"; n2="$(printf '%s' "$one" | grep -v '^$' | sort)"
    name="$R $flags"
    if [ "$rc" -ne 0 ]; then bad "$name: the combined call succeeded" "exit $rc"
    elif [ "$s1" != "$s2" ]; then bad "$name: one call leaves the destination as one call per tree does" "$(diff <(echo "$s1") <(echo "$s2"))"
    elif [ "$n1" != "$n2" ]; then bad "$name: one call itemizes the same lines per tree" "$(diff <(echo "$n1") <(echo "$n2"))"
    else ok "$name: one call does what one call per tree did"; fi
    # The fixture really exercises the excludes: a held back file is untouched, and a deletion happened
    # when the flags delete (L1: the comparison above passes trivially on a fixture where nothing moves).
    case "$flags" in
      *n*) ;;
      *) if [ "$(cat "$WORK/many/dst/hooks/held.sh")" = held-dst ] && [ -f "$WORK/many/dst/mods/m2/kept.json" ] \
            && [ -f "$WORK/many/dst/mods/sleep-repos.json" ] && [ ! -e "$WORK/many/dst/hooks/lib/gone.py" ] \
            && [ -f "$WORK/many/dst/mods/m1/main-to-dev-repos.txt" ] && [ -f "$WORK/many/dst/commands/only-here.md" ] \
            && [ "$(cat "$WORK/many/dst/settings.json")" = ROOT ]; then
           ok "$name: the fixture's held back, excluded and deleted files moved as each rule says"
         else bad "$name: the fixture's held back, excluded and deleted files moved as each rule says" "$(state "$WORK/many/dst" -)"; fi ;;
    esac
  done
done

# ---- 1b. a destination tree that does not exist yet ----
# Only past_release_paths dry runs into a tree that may not exist (the payload's, before a first send);
# every other caller makes or checks the destination tree first. There a per tree dry run prints a
# "created directory" line, and the openrsync macOS ships flags each file under it as unchanged
# (">f.......", the quirk the status preview notes) where one combined call flags it new
# (">f+++++++"). past_release_paths reads only the first character and the path, so those are what
# must agree, and they do (L11: the claim is only as wide as what is measured).
for R in ${RSYNCS[@]+"${RSYNCS[@]}"}; do
  rdir="$WORK/rbin-$(printf '%s' "$R" | tr '/' '_')"
  rm -rf "$WORK/miss"; mkdir -p "$WORK/miss/src/hooks/lib" "$WORK/miss/src/agents" "$WORK/miss/dst"
  echo h > "$WORK/miss/src/hooks/lib/h.sh"; echo a > "$WORK/miss/src/agents/a.md"
  per=""
  for d in hooks agents; do
    o="$(PATH="$rdir:$PATH" rsync -ainc "${COMMON_EXCLUDES[@]}" "$WORK/miss/src/$d/" "$WORK/miss/dst/$d/" 2>/dev/null)"
    per="$per$(printf '%s\n' "$o" | grep -v '^created directory ' | grep -v '^$' | sed "s|^|$d	|")
"
  done
  mirror_rsync_reset; mirror_rsync_add hooks "$WORK/miss/src/hooks"; mirror_rsync_add agents "$WORK/miss/src/agents"
  o="$(PATH="$rdir:$PATH" mirror_rsync_go "$WORK/miss/dst" -ainc 2>/dev/null)"
  one=""
  for d in hooks agents; do one="$one$(mirror_rsync_lines "$d" "$o" | sed "s|^|$d	|")
"; done
  # tree, first character of the change, path
  k1="$(printf '%s' "$per" | grep -v '^$' | awk -F'\t' '{ c = substr($2, 1, 1); p = $2; sub(/^[^ ]+ +/, "", p); print $1, c, p }' | sort)"
  k2="$(printf '%s' "$one" | grep -v '^$' | awk -F'\t' '{ c = substr($2, 1, 1); p = $2; sub(/^[^ ]+ +/, "", p); print $1, c, p }' | sort)"
  case "
$k2
" in *"
hooks > lib/h.sh
"*) has_new=1 ;; *) has_new="" ;; esac
  if [ -n "$k1" ] && [ "$k1" = "$k2" ] && [ -n "$has_new" ]; then
    ok "$R: into a tree that does not exist yet, one call reads the same as one call per tree for what past_release_paths reads"
  else
    bad "$R: into a tree that does not exist yet, one call reads the same as one call per tree for what past_release_paths reads" "$(diff <(echo "$k1") <(echo "$k2"))"
  fi
done

# ---- 2. a linked tree runs on its own, with its trailing slash ----
rm -rf "$WORK/ln"; mkdir -p "$WORK/ln/src/hooks" "$WORK/ln/real-agents" "$WORK/ln/dst/hooks" "$WORK/ln/real-dst-commands" "$WORK/ln/src/commands"
echo h > "$WORK/ln/src/hooks/h.sh"; echo a > "$WORK/ln/real-agents/a.md"; echo c > "$WORK/ln/src/commands/c.md"
ln -s "$WORK/ln/real-agents" "$WORK/ln/src/agents"              # a linked source
ln -s "$WORK/ln/real-dst-commands" "$WORK/ln/dst/commands"      # a linked destination
mirror_rsync_reset
for d in hooks agents commands; do mirror_rsync_add "$d" "$WORK/ln/src/$d"; done
o="$(mirror_rsync_go "$WORK/ln/dst" -ac --delete 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$WORK/ln/dst/agents/a.md" ] && [ ! -L "$WORK/ln/dst/agents" ] \
   && [ -L "$WORK/ln/dst/commands" ] && [ -f "$WORK/ln/real-dst-commands/c.md" ] && [ -f "$WORK/ln/dst/hooks/h.sh" ]; then
  ok "a linked tree at either end is copied through, as one call per tree did, and the link is kept"
else
  bad "a linked tree at either end is copied through, as one call per tree did, and the link is kept" "exit $rc: $o
$(ls -la "$WORK/ln/dst")"
fi

# ---- 3. an unanchored exclude for one tree is refused ----
mirror_rsync_reset
if o="$(mirror_rsync_add hooks "$WORK/ln/src/hooks" --exclude=wrangler 2>&1)"; then
  bad "an unanchored exclude for one tree is refused" "accepted: $o"
elif case "$o" in *anchored*) true ;; *) false ;; esac; then
  ok "an unanchored exclude for one tree is refused, saying why"
else
  bad "an unanchored exclude for one tree is refused, saying why" "$o"
fi

# ---- 4. a failing rsync's status reaches the caller ----
mkdir -p "$WORK/fail/bin"
printf '#!/bin/sh\nexit 23\n' > "$WORK/fail/bin/rsync"; chmod +x "$WORK/fail/bin/rsync"
mirror_rsync_reset
mirror_rsync_add hooks "$WORK/ln/src/hooks"; mirror_rsync_add agents "$WORK/ln/src/agents"
PATH="$WORK/fail/bin:$PATH" mirror_rsync_go "$WORK/ln/dst" -ac --delete >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 23 ]; then ok "a failing rsync's exit status reaches the caller"; else bad "a failing rsync's exit status reaches the caller" "got $rc"; fi

# ---- 5. wired: a real sync starts one rsync per step for the mirrored trees ----
export SYNC_CLONE_REGISTRY="$WORK/no-such-directory/clone-registry" SYNC_ZSHRC="$WORK/zshrc-guard" \
  SYNC_SCRATCH_ROOT="$WORK/scratch-root" SYNC_NO_SEND_TESTS=1 SYNC_NO_HOOK_TESTS=1 \
  SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here" SYNC_WATCH_PID_FILE="$WORK/watch-pid-guard" \
  SYNC_HOLD_FILE="$WORK/hold-guard" SYNC_RETIRED_FILE="$WORK/retired-guard" SYNC_LOG_FILE="$WORK/sync-log-guard" \
  SYNC_GH="$WORK/no-such-gh-here" SYNC_CLAUDE_BIN="$WORK/no-such-claude-here" SYNC_LAUNCHAGENTS="$WORK/launchagents-guard" \
  SYNC_MANAGED_SETTINGS="$WORK/managed-settings-guard.json" SYNC_PS_FIXTURE="$WORK/ps-guard" SYNC_NO_NOTIFY=1
export CLAUDE_SUITE_RUN_ID="${CLAUDE_SUITE_RUN_ID:-test-mirror-rsync}"
mkdir -p "$SYNC_SCRATCH_ROOT"; printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"; : > "$SYNC_PS_FIXTURE"
unset SYNC_NO_GIT
git init -q --bare "$WORK/bare.git"
git clone -q "$WORK/bare.git" "$WORK/repoA" 2>/dev/null
H="$WORK/homeA"; mkdir -p "$H/hooks" "$H/agents" "$H/commands"
echo 'echo hi' > "$H/hooks/h.sh"; chmod +x "$H/hooks/h.sh"; echo A > "$H/agents/a.md"; echo C > "$H/commands/c.md"
echo '# rules' > "$H/CLAUDE.md"; echo '{"hooks":{}}' > "$H/settings.json"
# An rsync that writes down the trees it was handed, then runs the real one.
REAL_RSYNC="$(command -v rsync)"; mkdir -p "$WORK/count/bin"
cat > "$WORK/count/bin/rsync" <<COUNT
#!/bin/sh
n=""; for a in "\$@"; do case "\$a" in */hooks|*/hooks/) n="\$n hooks" ;; */agents|*/agents/) n="\$n agents" ;; */commands|*/commands/) n="\$n commands" ;; esac; done
[ -n "\$n" ] && echo "\$n" >> "$WORK/count/log"
exec "$REAL_RSYNC" "\$@"
COUNT
chmod +x "$WORK/count/bin/rsync"
CLAUDE_HOME="$H" SYNC_REPO="$WORK/repoA" bash "$SCRIPT" sync > "$WORK/sync1.out" 2>&1 || true
echo '# rules v2' > "$H/CLAUDE.md"; echo 'echo hi2' > "$H/hooks/h.sh"
: > "$WORK/count/log"
PATH="$WORK/count/bin:$PATH" CLAUDE_HOME="$H" SYNC_REPO="$WORK/repoA" bash "$SCRIPT" sync > "$WORK/sync2.out" 2>&1; rc=$?
calls="$(grep -c . "$WORK/count/log" 2>/dev/null)"; calls="${calls:-0}"
alone="$(grep -cvE '^ *hooks agents commands$|^ *agents commands hooks$' "$WORK/count/log" 2>/dev/null)"; alone="${alone:-0}"
sent="$(git -C "$WORK/bare.git" show HEAD:payload/hooks/h.sh 2>/dev/null)"
case "$sent" in *hi2*) sent=1 ;; *) sent="" ;; esac
if [ "$rc" -ne 0 ] || [ -z "$sent" ]; then
  bad "fixture: the counted sync ran and sent the edit" "exit $rc: $(cat "$WORK/sync2.out")"
elif [ "$calls" -ge 2 ] && [ "$alone" -eq 0 ]; then
  ok "a sync names hooks, agents and commands in one rsync per step ($calls steps)"
else
  bad "a sync names hooks, agents and commands in one rsync per step, never one per tree" "$(cat "$WORK/count/log")"
fi

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
