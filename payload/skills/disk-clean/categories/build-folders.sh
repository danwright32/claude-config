#!/usr/bin/env bash
#
# build-folders.sh: disk-clean's build folder category (claude-config#1806). See scan-lib.sh for the
# module calls.
#
# From the walk: node_modules and .next beside a package.json, and .wrangler/tmp in a project with a
# wrangler config, offered by deleting them, since an install or a build makes them again. A project
# counts as in use when any file of its OWN (outside node_modules, .next, .git, .wrangler and .claude)
# changed within 30 days, by modification time: access times are unreliable on APFS (the plan). Never
# offered: .wrangler/state, which holds a project's local D1, KV and R2 data and is never even
# listed; anything inside a home dotfolder (~/.nvm's global packages, which carry Claude Code itself,
# ~/.npm's npx copies); a node_modules no package.json claims.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

# Sets PROJ to the project a build folder belongs to, or fails setting V to why it is not one.
project_of() { # <target>
  local t="${1%/}" p
  PROJ=""
  case "$t" in "$HOME"/.*/*|"$DCS_HOME"/.*/*) V="not offerable: it is inside a home dotfolder, where build folders belong to tools, not projects"; return 1 ;; esac
  case "$t" in
    */.wrangler/state|*/.wrangler/state/*) V="not offerable: .wrangler/state holds the project's local D1, KV and R2 data, which is never offered"; return 1 ;;
    */.wrangler/tmp)
      p="${t%/.wrangler/tmp}"
      if [ -f "$p/wrangler.toml" ] || [ -f "$p/wrangler.json" ] || [ -f "$p/wrangler.jsonc" ]; then PROJ="$p"; return 0; fi
      V="not offerable: no wrangler config beside its .wrangler folder says whose it is"; return 1 ;;
    */node_modules|*/.next)
      p="${t%/*}"
      [ -f "$p/package.json" ] && { PROJ="$p"; return 0; }
      V="not offerable: no package.json beside it says whose it is"; return 1 ;;
  esac
  V="not offerable: it is not a build folder this category offers (node_modules, .next or .wrangler/tmp)"
  return 1
}

# Sets V and D for <target>, whose project is PROJ.
build_rules() { # <target>
  local t="${1%/}" recent err="$DCS_WORK/build.find.err.$$"
  [ -d "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  recent="$(dcs_recent_file "$PROJ" "$DCS_BUILD_DAYS" "$err" node_modules .next .git .wrangler .claude)"
  if [ -n "$recent" ] && [ -d "$recent" ]; then
    V="unmeasured: part of the project is kept only in iCloud (${recent#"$PROJ"/}), so whether it is in use is not known"; rm -f "$err"; return
  fi
  if [ -n "$recent" ]; then V="not offerable: the project's own files changed within $DCS_BUILD_DAYS days (${recent#"$PROJ"/})"; rm -f "$err"; return; fi
  if [ -s "$err" ]; then V="unmeasured: part of the project could not be read ($(awk 'NR == 1' "$err")), so whether it is in use is not known"; rm -f "$err"; return; fi
  rm -f "$err"
  V=offerable
  D="project $PROJ, none of whose own files changed in $DCS_BUILD_DAYS days"
}

do_scan() {
  dcs_walk_ready
  : > "$DCS_WORK/build.paths"
  local t
  while IFS= read -r t; do
    case "$t" in */node_modules|*/.next|*/.wrangler/tmp) ;; *) continue ;; esac
    [ -d "$t" ] || continue
    project_of "$t" || continue
    printf '%s\n' "$t" >> "$DCS_WORK/build.paths"
  done < "$DCS_WALK"
  dcs_measure "$DCS_WORK/build.paths" > "$DCS_WORK/build.sized"
  local p kib size ident flags
  while IFS="$S" read -r p kib size ident; do
    project_of "$p"
    D=""; build_rules "$p"
    flags=""; dcs_icloud "$p" && flags=icloud
    dcs_item "$p" delete "$kib" "$size" "$V" "$flags" "$D" "$ident"
  done < "$DCS_WORK/build.sized"
}

do_judge() { # <target>
  project_of "$1" || { echo "$V"; return 0; }
  build_rules "$1"
  echo "$V"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) do_judge "${2:-}" ;;
  *) echo "usage: build-folders.sh scan | build-folders.sh judge <target>" >&2; exit 2 ;;
esac
