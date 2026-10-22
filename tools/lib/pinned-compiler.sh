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
# apply does not call it, so npm and the network stay off every pull (#833).
#
# Sourced: pinned_compiler_ensure <tools/typescript folder> returns 0 when the compiler is there,
# setting PINNED_TS_DID to what it did when it did anything, or returns 1 with PINNED_TS_WHY saying
# why it could not, for the caller's UNMEASURED line (L411, L11). Run as a script, it does the same
# and prints it.
#
# PINNED_TS_NPM names the npm to run (tests); PINNED_TS_INSTALL_DEADLINE bounds it, in seconds.

PINNED_TS_MARK=".pinned-typescript-store"

# Rename $1 to $2 by rename(2): atomic, never follows a link at $2 (mv into a linked folder would
# put $1 inside it), and fails when $2 is a folder that is not empty.
_pc_rename(){ perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; }

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
  local dir="$1" root="$2" store="$3" key="$4" npm deadline t pid tmp rc said
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
    [ -d "$t" ] || continue
    pid="${t##*.tmp.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -rf "$t"
  done
  tmp="$root/.$key.tmp.$$"
  rm -rf "$tmp"
  if ! { mkdir -p "$tmp" && cp "$dir/package.json" "$dir/package-lock.json" "$tmp/"; } 2>/dev/null; then
    rm -rf "$tmp"
    PINNED_TS_WHY="could not copy $dir/package.json and package-lock.json into $tmp to install from"
    return 1
  fi
  # The log stays with the install, so what npm did is there to read later (L338).
  _pc_bounded "$deadline" "$npm" ci --prefix "$tmp" --prefer-offline --no-audit --no-fund > "$tmp/npm-ci.log" 2>&1; rc=$?
  if [ "$rc" -eq 124 ]; then
    PINNED_TS_WHY="npm ci did not finish within $deadline s (offline with the package not in the npm cache, or the registry did not answer), so it was stopped"
  elif [ "$rc" -ne 0 ]; then
    said="$(awk 'tolower($0) ~ /error/ && n < 3 { sub(/^ */, ""); print; n++ }' "$tmp/npm-ci.log" | paste -sd';' -)"
    [ -n "$said" ] || said="$(sed '/^ *$/d' "$tmp/npm-ci.log" | tail -n 1)"
    PINNED_TS_WHY="npm ci exited $rc: ${said:-it printed nothing}"
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
  return 0
}

pinned_compiler_ensure(){
  PINNED_TS_WHY=""; PINNED_TS_DID=""
  local dir nm common key root store installed=""
  dir="$(cd "${1:-}" 2>/dev/null && pwd -P)" || { PINNED_TS_WHY="${1:-<none given>} is not a folder"; return 1; }
  nm="$dir/node_modules"
  # An install of its own (npm ci by hand, CI's step): used as it is, never touched.
  if [ ! -f "$nm/$PINNED_TS_MARK" ] && [ -x "$nm/.bin/tsc" ]; then return 0; fi
  [ -f "$dir/package-lock.json" ] || { PINNED_TS_WHY="there is no package-lock.json in $dir to install it from"; return 1; }
  if [ -d "$nm" ] && [ ! -f "$nm/$PINNED_TS_MARK" ] && [ -n "$(ls -A "$nm" 2>/dev/null)" ]; then
    PINNED_TS_WHY="$nm holds packages but no .bin/tsc, and was not linked by this install, so it was left as it is. Replace it with: npm ci --prefix $dir"
    return 1
  fi
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -z "$common" ] || [ ! -d "$common" ]; then
    PINNED_TS_WHY="$dir is not in a git checkout, so there is no shared install to keep it in. Install it with: npm ci --prefix $dir"
    return 1
  fi
  key="$(git hash-object "$dir/package-lock.json" 2>/dev/null)" || key=""
  [ -n "$key" ] || { PINNED_TS_WHY="git could not hash $dir/package-lock.json"; return 1; }
  key="$key-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
  root="$common/pinned-typescript"
  store="$root/$key"
  if [ "$(cat "$nm/$PINNED_TS_MARK" 2>/dev/null)" = "$store" ] && [ -x "$nm/.bin/tsc" ]; then return 0; fi
  if [ ! -f "$store/.complete" ] || [ ! -x "$store/node_modules/.bin/tsc" ]; then
    _pc_install "$dir" "$root" "$store" "$key" || return 1
    installed=1
  fi
  _pc_link "$nm" "$store" || return 1
  if [ -n "$installed" ]; then
    PINNED_TS_DID="installed from $dir/package-lock.json into the shared install $store, and linked into $nm"
  else
    PINNED_TS_DID="linked into $nm from the shared install $store"
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if pinned_compiler_ensure "${1:-}"; then
    [ -z "$PINNED_TS_DID" ] || echo "pinned-compiler: the pinned TypeScript compiler was $PINNED_TS_DID."
    exit 0
  fi
  echo "pinned-compiler: the pinned TypeScript compiler is not available in ${1:-<none given>}: $PINNED_TS_WHY" >&2
  exit 1
fi
