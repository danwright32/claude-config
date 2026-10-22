#!/usr/bin/env bash
# pinned-compiler.sh: give a checkout the TypeScript compiler pinned in tools/typescript, with no
# manual step (#1496). The mods' strict type check (tools/check-mods.sh) and the noun wait check
# (tools/check-mod-noun-waits.sh) both need it, and a new git worktree has no node_modules, so until
# somebody ran `npm ci --prefix tools/typescript` there, every run said all 20 mods' types were
# UNMEASURED. Every builder on 2026-10-21 and 22 had to run it by hand, and the full suite runs
# that forgot reported the mods unmeasured.
#
# ONE install per clone and pin, shared by every worktree of the clone. It is kept in the clone's
# common git folder (<.git>/pinned-typescript/<key>), keyed on the lockfile's git hash and the
# platform, since TypeScript 7 is a native binary. A checkout's tools/typescript/node_modules is a
# real folder of links into it, so the existing ignore rule for that folder still covers it, a new
# worktree is linked in milliseconds with no npm at all, and the 30 MB install is held once rather
# than once per worktree. Only the first checkout of a clone after the pin moves runs npm: `npm ci
# --prefer-offline`, which reads the npm cache and goes to the registry only for what the cache
# lacks, bounded by PINNED_TS_INSTALL_DEADLINE seconds (default 60), its whole process group
# stopped at the deadline. Measured 2026-10-22 on this Mac: 0.9 s from the cache.
#
# Assume it runs twice (L33): two suites starting at once each install into a folder of their own
# and publish it by one rename, which fails for the second, which then uses the first's. Nothing is
# locked, so nothing is left holding a lock when a run is killed (L409); a half made copy a killed
# run leaves is named for its pid and cleared by the next install once that pid is gone. Linking is
# the same: each link is made beside its name and renamed into place, so two runs linking one
# checkout make the same links.
#
# What it never does: touch a node_modules it did not make (an install by hand, a copy from another
# machine), delete an install another checkout may be linked to, or run during a pull: the sync's
# apply does not call it, so npm and the network stay off every pull (#833). Installing a new pin
# prunes the installs nothing links to any more (#1507, see "pruning" below).
#
# Sourced: pinned_compiler_ensure <tools/typescript folder> returns 0 when the compiler is there,
# setting PINNED_TS_DID to what it did when it did anything, or returns 1 with PINNED_TS_WHY saying
# why it could not, for the caller's UNMEASURED line (L411, L11). Run as a script, it does the same
# and prints it. `--prune <folder>` prunes by hand; `--plan <folder>` prints what a prune would do
# and removes nothing (claude-sync status reads it).
#
# PINNED_TS_NPM names the npm to run (tests); PINNED_TS_INSTALL_DEADLINE bounds it, in seconds;
# PINNED_TS_OFFLINE=1 reads the npm cache only, never the registry, which tests/test-mods.sh sets
# so that no suite run reaches the network. PINNED_TS_TEST_BEFORE_LINK and
# PINNED_TS_TEST_BEFORE_REMOVE name a command run at the two moments a prune and a link can cross,
# for the tests of them; nothing else sets them.

PINNED_TS_MARK=".pinned-typescript-store"

# Rename $1 to $2 by rename(2): atomic, never follows a link at $2 (mv into a linked folder would
# put $1 inside it), and fails when $2 is a folder that is not empty.
_pc_rename(){ perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; }

# Is pid $1 running? kill -0 alone fails for a live process that belongs to another user (it cannot
# be signalled), which would read an install in progress as abandoned, so ps has the last word.
_pc_alive(){ kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

# Where the shared install for the checkout folder $1 (resolved, holding package-lock.json) lives:
# sets _PC_ROOT (<common git folder>/pinned-typescript), _PC_KEY and _PC_STORE, or returns 1 with
# PINNED_TS_WHY set.
_pc_where(){
  local dir="$1" common key
  [ -f "$dir/package-lock.json" ] || { PINNED_TS_WHY="there is no package-lock.json in $dir to install it from"; return 1; }
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -z "$common" ] || [ ! -d "$common" ]; then
    PINNED_TS_WHY="$dir is not in a git checkout, so there is no shared install to keep it in. Install it with: npm ci --prefix $dir"
    return 1
  fi
  key="$(git hash-object "$dir/package-lock.json" 2>/dev/null)" || key=""
  [ -n "$key" ] || { PINNED_TS_WHY="git could not hash $dir/package-lock.json"; return 1; }
  _PC_KEY="$key-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
  _PC_ROOT="$common/pinned-typescript"
  _PC_STORE="$_PC_ROOT/$_PC_KEY"
  return 0
}

# Run the command after the first argument in a process group of its own, the whole group stopped
# once the deadline the first argument names has passed, and then exit 124 as timeout(1) does,
# which macOS does not ship.
_pc_bounded(){
  perl -MPOSIX -e '
    my $secs = shift;
    my $pid = fork();
    defined $pid or do { print STDERR "could not start $ARGV[0]: $!\n"; exit 126 };
    if ($pid == 0) { POSIX::setpgid(0, 0); exec { $ARGV[0] } @ARGV; print STDERR "could not run $ARGV[0]: $!\n"; POSIX::_exit(127) }
    POSIX::setpgid($pid, $pid);
    local $SIG{ALRM} = sub { kill "TERM", -$pid; select(undef, undef, undef, 0.5); kill "KILL", -$pid; waitpid($pid, 0); exit 124 };
    alarm $secs;
    waitpid($pid, 0);
    my $st = $?;
    alarm 0;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
  ' "$@"
}

# Install the pin from $1 (the tools/typescript folder) into $3, the shared install for key $4 under
# $2. Returns 1 with PINNED_TS_WHY set when it cannot.
_pc_install(){
  local dir="$1" root="$2" store="$3" key="$4" npm deadline t pid tmp rc said mode offline_note
  npm="${PINNED_TS_NPM:-$(command -v npm 2>/dev/null)}"
  if [ -z "$npm" ] || [ ! -x "$npm" ]; then
    PINNED_TS_WHY="npm is not installed (looked for ${PINNED_TS_NPM:-npm on PATH}), so the pinned compiler could not be installed"
    return 1
  fi
  deadline="${PINNED_TS_INSTALL_DEADLINE:-60}"
  case "$deadline" in ''|0*|*[!0-9]*)
    PINNED_TS_WHY="PINNED_TS_INSTALL_DEADLINE='$deadline' is not a whole number of seconds npm may take, so nothing was installed rather than guessing a bound"
    return 1 ;;
  esac
  mkdir -p "$root" 2>/dev/null || { PINNED_TS_WHY="could not make $root to install into"; return 1; }
  # Half made copies from installs that were killed: each is named for its run's pid.
  for t in "$root"/.*.tmp.*; do
    [ -d "$t" ] && [ ! -L "$t" ] || continue
    pid="${t##*.tmp.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    _pc_alive "$pid" || rm -rf "$t"
  done
  tmp="$root/.$key.tmp.$$"
  rm -rf "$tmp"
  if ! { mkdir -p "$tmp" && cp "$dir/package.json" "$dir/package-lock.json" "$tmp/"; } 2>/dev/null; then
    rm -rf "$tmp"
    PINNED_TS_WHY="could not copy $dir/package.json and package-lock.json into $tmp to install from"
    return 1
  fi
  # A test suite sets PINNED_TS_OFFLINE=1 so no suite run ever asks the registry: the npm cache or
  # nothing. Everything else prefers the cache and asks the registry only for what it lacks.
  mode=--prefer-offline offline_note=""
  if [ "${PINNED_TS_OFFLINE:-}" = 1 ]; then
    mode=--offline
    offline_note=" (PINNED_TS_OFFLINE is set, so only the npm cache was read and the registry was not asked)"
  fi
  # The log stays with the install, so what npm did is there to read later (L338).
  _pc_bounded "$deadline" "$npm" ci --prefix "$tmp" "$mode" --no-audit --no-fund > "$tmp/npm-ci.log" 2>&1; rc=$?
  if [ "$rc" -eq 124 ]; then
    PINNED_TS_WHY="npm ci did not finish within $deadline s (offline with the package not in the npm cache, or the registry did not answer), so it was stopped"
  elif [ "$rc" -ne 0 ]; then
    said="$(awk 'tolower($0) ~ /error/ && n < 3 { sub(/^ */, ""); print; n++ }' "$tmp/npm-ci.log" | paste -sd';' -)"
    [ -n "$said" ] || said="$(sed '/^ *$/d' "$tmp/npm-ci.log" | tail -n 1)"
    PINNED_TS_WHY="npm ci exited $rc: ${said:-it printed nothing}$offline_note"
  elif [ ! -x "$tmp/node_modules/.bin/tsc" ]; then
    PINNED_TS_WHY="npm ci finished but left no node_modules/.bin/tsc"
  fi
  if [ -n "$PINNED_TS_WHY" ]; then rm -rf "$tmp"; return 1; fi
  : > "$tmp/.complete"
  _pc_rename "$tmp" "$store" && return 0
  # Another run published first: use its install.
  if [ -f "$store/.complete" ] && [ -x "$store/node_modules/.bin/tsc" ]; then rm -rf "$tmp"; return 0; fi
  # What sits there is not a whole install (it was edited by hand): replace it.
  rm -rf "$store"
  _pc_rename "$tmp" "$store" && return 0
  rm -rf "$tmp"
  PINNED_TS_WHY="could not move the new install into $store"
  return 1
}

# Link $1 (a checkout's node_modules) to the install in $2. Each link is made beside its name and
# renamed into place; .bin, which holds tsc, comes last, so a reader that finds tsc finds the rest.
_pc_link(){
  local nm="$1" src="$2/node_modules" s name tmp e t entries
  mkdir -p "$nm" 2>/dev/null || { PINNED_TS_WHY="could not make $nm"; return 1; }
  printf '%s\n' "$2" > "$nm/$PINNED_TS_MARK.$$" && _pc_rename "$nm/$PINNED_TS_MARK.$$" "$nm/$PINNED_TS_MARK" \
    || { rm -f "$nm/$PINNED_TS_MARK.$$"; PINNED_TS_WHY="could not write $nm/$PINNED_TS_MARK"; return 1; }
  entries=""
  for s in "$src"/* "$src"/.[!.]*; do
    [ -e "$s" ] || [ -L "$s" ] || continue
    name="${s##*/}"
    [ "$name" = .bin ] && continue
    entries="$entries$name"$'\n'
  done
  entries="$entries.bin"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(readlink "$nm/$name" 2>/dev/null)" = "$src/$name" ] && continue
    if [ -e "$nm/$name" ] && [ ! -L "$nm/$name" ]; then
      PINNED_TS_WHY="$nm/$name is not a link this install made, so it was left as it is"
      return 1
    fi
    tmp="$nm/.$name.link.$$"
    rm -f "$tmp"
    ln -s "$src/$name" "$tmp" && _pc_rename "$tmp" "$nm/$name" || { rm -f "$tmp"; PINNED_TS_WHY="could not link $nm/$name"; return 1; }
  done <<EOF
$entries
EOF
  # Links into an earlier pin's install for a package this one no longer has.
  for e in "$nm"/* "$nm"/.[!.]*; do
    [ -L "$e" ] || continue
    t="$(readlink "$e")"
    case "$t" in "$src"/*) ;; *) rm -f "$e" ;; esac
  done
  [ -x "$nm/.bin/tsc" ] || { PINNED_TS_WHY="$nm was linked to $2, but its .bin/tsc does not run"; return 1; }
  # Where this install is linked from, so the prune finds a node_modules outside tools/typescript
  # too (CHECK_MODS_TS_DIR can name one) rather than only where it expects to look. A line per
  # folder, appended, which is one write per line however many run at once.
  grep -qxF "$nm" "$2/.links" 2>/dev/null || printf '%s\n' "$nm" >> "$2/.links" 2>/dev/null || true
  return 0
}

# ---------- pruning (#1507) ----------
# Each shared install is about 30 MB, one per pin the clone has been on, and nothing removed them,
# deliberately, because a checkout still on an old pin links to its install. The prune removes an
# install only when nothing can be using it. It KEEPS:
#   - every install any node_modules links to: each worktree's tools/typescript/node_modules (the
#     worktrees read from `git worktree list`, never guessed, the main checkout among them), and
#     every node_modules an install has recorded it was linked from (its .links);
#   - the pin of the checkout it is run from, linked or not;
#   - an install in progress (.<key>.tmp.<pid>) or being removed (.<key>.pruning.<pid>) by a process
#     that is still running.
# It removes the rest, and the leftovers of processes that are gone. It never touches anything but a
# folder directly inside <common git folder>/pinned-typescript, never follows a link there, and
# when a worktree cannot be read but may still exist (git says it is locked, a removable disk) it
# removes nothing at all. An install is renamed aside before it is deleted, so nobody ever links to
# a half deleted one, and put back if a checkout linked to it in that moment.

# The install named in a path into the store, if it is one: <...>/pinned-typescript/<name>[/...].
_pc_name_in(){ local r="${1#*/pinned-typescript/}"; [ "$r" != "$1" ] && [ -n "$r" ] && printf '%s\n' "${r%%/*}"; return 0; }

# The installs the node_modules folder $1 links to, one name per line: its marker and its links.
_pc_refs_in(){
  local nm="$1" e
  [ -L "$nm" ] && _pc_name_in "$(readlink "$nm")"
  [ -d "$nm" ] || return 0
  [ -f "$nm/$PINNED_TS_MARK" ] && _pc_name_in "$(cat "$nm/$PINNED_TS_MARK" 2>/dev/null)"
  for e in "$nm"/* "$nm"/.[!.]*; do
    [ -L "$e" ] && _pc_name_in "$(readlink "$e")"
  done
  return 0
}

# Every install referenced from any checkout of the clone holding the folder $1, into _PC_REFS as
# "\n<name>\n" lines. Returns 1 with PINNED_TS_WHY when it cannot read them all.
_pc_referenced(){
  local dir="$1" root="$2" list field wt="" locked="" refs="" s l
  list="$(mktemp "${TMPDIR:-/tmp}/pinned-ts-worktrees.XXXXXX")" || { PINNED_TS_WHY="could not make a file to read the worktree list into"; return 1; }
  if ! git -C "$dir" worktree list --porcelain -z > "$list" 2>/dev/null; then
    rm -f "$list"
    PINNED_TS_WHY="git worktree list failed in $dir, so which installs are linked could not be read"
    return 1
  fi
  # One NUL ended field per line of a record, and an empty field ends each record; a final record
  # with no empty field after it is ended by the end of the list.
  while :; do
    if IFS= read -r -d '' field; then :; else field=""; [ -n "$wt" ] || break; fi
    case "$field" in
      "worktree "*) wt="${field#worktree }" ;;
      locked|"locked "*) locked=1 ;;
      "")
        if [ -n "$wt" ]; then
          if [ -d "$wt" ]; then
            refs="$refs"$'\n'"$(_pc_refs_in "$wt/tools/typescript/node_modules")"
          elif [ -n "$locked" ]; then
            rm -f "$list"
            PINNED_TS_WHY="the worktree $wt is locked and its folder cannot be read (a disk not mounted?), so it may link to any install, and nothing was removed"
            return 1
          fi
        fi
        wt="" locked="" ;;
    esac
  done < "$list"
  rm -f "$list"
  # Every node_modules an install recorded it was linked from, wherever it is, and those of $3, an
  # install the prune has just renamed aside, which the store's listing no longer shows by name.
  for s in "$root"/* ${3:+"$3"}; do
    [ -d "$s" ] && [ ! -L "$s" ] && [ -f "$s/.links" ] || continue
    while IFS= read -r l; do
      [ -n "$l" ] && refs="$refs"$'\n'"$(_pc_refs_in "$l")"
    done < "$s/.links"
  done
  _PC_REFS=$'\n'"$refs"$'\n'
  return 0
}

# What a prune of the clone holding the checkout folder $1 would do, into _PC_PLAN, one line per
# folder in the store: <keep|remove> TAB <install|leftover> TAB <path> TAB <why>. Anything in the
# store that is not a folder, or is a link, is not listed and never touched.
_pc_plan(){
  local dir e name pid
  _PC_PLAN=""
  dir="$(cd "${1:-}" 2>/dev/null && pwd -P)" || { PINNED_TS_WHY="${1:-<none given>} is not a folder"; return 1; }
  _pc_where "$dir" || return 1
  _PC_DIR="$dir"
  [ -d "$_PC_ROOT" ] || return 0
  _pc_referenced "$dir" "$_PC_ROOT" || return 1
  for e in "$_PC_ROOT"/* "$_PC_ROOT"/.[!.]*; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    name="${e##*/}"
    case "$name" in
      .*.tmp.*|.*.pruning.*)
        pid="${name##*.}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        if _pc_alive "$pid"; then
          _PC_PLAN="$_PC_PLAN"$'keep\tleftover\t'"$e"$'\t'"in progress by pid $pid, which is running"$'\n'
        else
          _PC_PLAN="$_PC_PLAN"$'remove\tleftover\t'"$e"$'\t'"left by pid $pid, which is not running"$'\n'
        fi ;;
      .*) ;;
      *)
        if [ "$name" = "$_PC_KEY" ]; then
          _PC_PLAN="$_PC_PLAN"$'keep\tinstall\t'"$e"$'\t'"the pin of $dir"$'\n'
        elif [[ "$_PC_REFS" == *$'\n'"$name"$'\n'* ]]; then
          _PC_PLAN="$_PC_PLAN"$'keep\tinstall\t'"$e"$'\t'"linked from a checkout"$'\n'
        else
          _PC_PLAN="$_PC_PLAN"$'remove\tinstall\t'"$e"$'\t'"linked by no checkout"$'\n'
        fi ;;
    esac
  done
  return 0
}

_pc_size(){ # kb
  if [ "${1:-0}" -ge 1024 ]; then echo "$(( ($1 + 512) / 1024 )) MB"; else echo "${1:-0} KB"; fi
}

# Remove what _pc_plan says may go. Sets PINNED_TS_PRUNED (installs removed) and PINNED_TS_PRUNED_KB,
# or returns 1 with PINNED_TS_WHY set, having removed nothing.
pinned_compiler_prune(){
  PINNED_TS_WHY=""; PINNED_TS_PRUNED=0; PINNED_TS_PRUNED_KB=0
  local action kind path why name doomed kb
  _pc_plan "${1:-}" || return 1
  while IFS=$'\t' read -r action kind path why; do
    [ "$action" = remove ] || continue
    name="${path##*/}"
    # Only ever a folder directly inside the store, never a link (a second guard on the plan's).
    [ -n "$name" ] && [ "$path" = "$_PC_ROOT/$name" ] && [ -d "$path" ] && [ ! -L "$path" ] || continue
    if [ "$kind" = leftover ]; then rm -rf "$path"; continue; fi
    kb="$(du -sk "$path" 2>/dev/null | awk 'NR == 1 { print $1 + 0 }')"
    doomed="$_PC_ROOT/.$name.pruning.$$"
    # A seam for the test of a checkout linking to it between the plan and its removal.
    [ -z "${PINNED_TS_TEST_BEFORE_REMOVE:-}" ] || "$PINNED_TS_TEST_BEFORE_REMOVE" "$path"
    _pc_rename "$path" "$doomed" || continue
    # A checkout that linked to it after the plan was made, or links that can no longer be read:
    # put it back.
    if ! _pc_referenced "$_PC_DIR" "$_PC_ROOT" "$doomed" || [[ "$_PC_REFS" == *$'\n'"$name"$'\n'* ]]; then
      _pc_rename "$doomed" "$path" || rm -rf "$doomed"
      continue
    fi
    rm -rf "$doomed"
    PINNED_TS_PRUNED=$((PINNED_TS_PRUNED + 1))
    PINNED_TS_PRUNED_KB=$((PINNED_TS_PRUNED_KB + ${kb:-0}))
  done <<EOF
$_PC_PLAN
EOF
  PINNED_TS_WHY=""
  return 0
}

pinned_compiler_ensure(){
  PINNED_TS_WHY=""; PINNED_TS_DID=""
  local dir nm key root store installed="" n
  dir="$(cd "${1:-}" 2>/dev/null && pwd -P)" || { PINNED_TS_WHY="${1:-<none given>} is not a folder"; return 1; }
  nm="$dir/node_modules"
  # An install of its own (npm ci by hand, CI's step): used as it is, never touched.
  if [ ! -f "$nm/$PINNED_TS_MARK" ] && [ -x "$nm/.bin/tsc" ]; then return 0; fi
  [ -f "$dir/package-lock.json" ] || { PINNED_TS_WHY="there is no package-lock.json in $dir to install it from"; return 1; }
  if [ -d "$nm" ] && [ ! -f "$nm/$PINNED_TS_MARK" ] && [ -n "$(ls -A "$nm" 2>/dev/null)" ]; then
    PINNED_TS_WHY="$nm holds packages but no .bin/tsc, and was not linked by this install, so it was left as it is. Replace it with: npm ci --prefix $dir"
    return 1
  fi
  _pc_where "$dir" || return 1
  key="$_PC_KEY" root="$_PC_ROOT" store="$_PC_STORE"
  if [ "$(cat "$nm/$PINNED_TS_MARK" 2>/dev/null)" = "$store" ] && [ -x "$nm/.bin/tsc" ]; then return 0; fi
  if [ ! -f "$store/.complete" ] || [ ! -x "$store/node_modules/.bin/tsc" ]; then
    _pc_install "$dir" "$root" "$store" "$key" || return 1
    installed=1
  fi
  # A seam for the test of the moment between finding the install whole and linking to it.
  [ -z "${PINNED_TS_TEST_BEFORE_LINK:-}" ] || "$PINNED_TS_TEST_BEFORE_LINK" "$store"
  if ! _pc_link "$nm" "$store"; then
    # A prune from another checkout removed the install in that moment: install it again, once,
    # rather than leave this checkout linked to nothing.
    [ ! -f "$store/.complete" ] || return 1
    PINNED_TS_WHY=""
    _pc_install "$dir" "$root" "$store" "$key" || return 1
    installed=1
    _pc_link "$nm" "$store" || return 1
  fi
  if [ -n "$installed" ]; then
    PINNED_TS_DID="installed from $dir/package-lock.json into the shared install $store, and linked into $nm"
    # A new pin is the moment an older install may have stopped being used (#1507).
    if pinned_compiler_prune "$dir"; then
      n="$PINNED_TS_PRUNED"
      [ "$n" -eq 0 ] || PINNED_TS_DID="$PINNED_TS_DID, and removed $n shared install$([ "$n" -eq 1 ] || echo s) no checkout links to ($(_pc_size "$PINNED_TS_PRUNED_KB"))"
    else
      PINNED_TS_DID="$PINNED_TS_DID; the older shared installs were not pruned: $PINNED_TS_WHY"
      PINNED_TS_WHY=""
    fi
  else
    PINNED_TS_DID="linked into $nm from the shared install $store"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --plan ]; then
  # For claude-sync status: what a prune would do, removing nothing.
  if _pc_plan "${2:-}"; then printf '%s' "$_PC_PLAN"; exit 0; fi
  echo "pinned-compiler: could not say which shared installs are linked: $PINNED_TS_WHY" >&2
  exit 1
fi
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --prune ]; then
  if pinned_compiler_prune "${2:-}"; then
    echo "pinned-compiler: removed $PINNED_TS_PRUNED shared install(s) no checkout links to ($(_pc_size "$PINNED_TS_PRUNED_KB"))."
    exit 0
  fi
  echo "pinned-compiler: removed nothing: $PINNED_TS_WHY" >&2
  exit 1
fi
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if pinned_compiler_ensure "${1:-}"; then
    [ -z "$PINNED_TS_DID" ] || echo "pinned-compiler: the pinned TypeScript compiler was $PINNED_TS_DID."
    exit 0
  fi
  echo "pinned-compiler: the pinned TypeScript compiler is not available in ${1:-<none given>}: $PINNED_TS_WHY" >&2
  exit 1
fi
