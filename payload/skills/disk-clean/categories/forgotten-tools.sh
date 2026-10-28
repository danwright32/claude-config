#!/usr/bin/env bash
#
# forgotten-tools.sh: disk-clean's forgotten tool category (claude-config#1806). See scan-lib.sh for
# the module calls.
#
# A folder is a candidate only when it is in the folder to command TABLE (DCS_TOOLS in scan-lib.sh),
# never by a name that looks like a tool's. It is offered, moved to the Trash, only on POSITIVE
# evidence it is forgotten, checked in this order:
#   1. the walk of the home folder was complete: a folder the walk could not read could hold the
#      project that uses it, so a partial walk makes every item unmeasured
#   2. no file a project using it would hold (its markers: pom.xml for ~/.m2, go.mod for ~/go) exists
#      anywhere the walk went
#   3. no shell startup file mentions its folder (or its command, when that is four letters or more)
#   4. nothing in it changed in 180 days
# Toolchains are judged per version, by their dependents read from disk; an unreadable dependent
# makes every version of that toolchain unmeasured, so nothing is tickable on a guess:
#   ~/.nvm/versions/node/<v>   kept when a project's .nvmrc or nvm's default alias names it (an
#                              .nvmrc naming lts/* or node keeps every version); ~/.nvm itself is on
#                              disk-remove's deny list and never listed
#   ~/.pyenv/versions/<v>      considered when ~/.pyenv as a whole is kept; kept when a project's
#                              .python-version or pyenv's global version names it, or a virtual
#                              environment's pyvenv.cfg home points into it
# Not covered: Homebrew formulas (`brew uses --installed`), which no disk-remove method removes.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

SHELL_FILES=".zshrc .zprofile .zshenv .zlogin .bashrc .bash_profile .profile .config/fish/config.fish"

# Sets V when a shell startup file mentions <folder rel> or <command>, and succeeds; fails when none
# does. An unreadable startup file sets V unmeasured and succeeds.
shell_mentions() { # <rel> <command or empty>
  local rel="$1" cmd="$2" f esc
  esc="$(printf '%s' "$rel" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
  for f in $SHELL_FILES; do
    f="$HOME/$f"
    [ -e "$f" ] || continue
    [ -r "$f" ] || { V="unmeasured: the shell file $f could not be read, so whether it uses this is not known"; return 0; }
    if grep -Eq -- "(/|~/)$esc([/\"': ]|\$)" "$f"; then V="not offerable: ${f#"$HOME"/} mentions it"; return 0; fi
    if [ -n "$cmd" ] && [ "${#cmd}" -ge 4 ] && grep -qw -- "$cmd" "$f"; then V="not offerable: ${f#"$HOME"/} mentions $cmd"; return 0; fi
  done
  return 1
}
# Sets V when something in <folder> changed within 180 days, or part of it cannot be read; succeeds
# then. Fails when it is positively stale.
recently_used() { # <folder>
  local r err="$DCS_WORK/ft.find.err.$$"
  r="$(dcs_recent_file "$1" "$DCS_TOOL_DAYS" "$err")"
  if [ -n "$r" ] && [ -d "$r" ]; then V="unmeasured: part of it is kept only in iCloud (${r#"$1"/}), so whether it was used lately is not known"; rm -f "$err"; return 0; fi
  if [ -n "$r" ]; then V="not offerable: something in it changed within $DCS_TOOL_DAYS days (${r#"$1"/})"; rm -f "$err"; return 0; fi
  if [ -s "$err" ]; then V="unmeasured: part of it could not be read ($(awk 'NR == 1' "$err")), so whether it was used lately is not known"; rm -f "$err"; return 0; fi
  rm -f "$err"
  return 1
}
walk_whole() {
  [ "$DCS_WALK_STATE" = complete ] && return 0
  V="unmeasured: the walk of the home folder was $DCS_WALK_STATE, so a project that uses it could be hidden there"
  return 1
}
# The first walked file whose name matches one of <markers>, or nothing.
marker_hit() { # <markers>
  local m line base
  set -f
  while IFS= read -r line; do
    base="${line##*/}"
    for m in $1; do
      case "$base" in $m) [ -f "$line" ] && { set +f; printf '%s\n' "$line"; return 0; } ;; esac
    done
  done < "$DCS_WALK"
  set +f
  return 1
}

tool_rules() { # <rel> <command> <markers>
  local rel="$1" folder="$HOME/$1" hit
  walk_whole || return
  if [ -n "$3" ] && hit="$(marker_hit "$3")"; then V="not offerable: ${hit#"$HOME"/} uses it (${hit##*/})"; return; fi
  shell_mentions "$rel" "$2" && return
  recently_used "$folder" && return
  V=offerable
  D="nothing in it changed in $DCS_TOOL_DAYS days, and no project or shell file mentions it"
}

# Matches version <v> against a dependent's text <c>: exact, or <c> as a prefix ending at a dot.
version_named() { # <v> <c>
  local v="${1#v}" c="${2#v}"
  [ -n "$c" ] || return 1
  [ "$v" = "$c" ] && return 0
  case "$v" in "$c".*) return 0 ;; esac
  return 1
}
node_rules() { # <version folder>
  local d="${1%/}" v line f c
  v="${d##*/}"
  walk_whole || return
  while IFS= read -r f; do
    case "$f" in */.nvmrc) ;; *) continue ;; esac
    [ -r "$f" ] || { V="unmeasured: the .nvmrc at ${f#"$HOME"/} could not be read, so which node versions projects need is not known"; return; }
    c="$(awk 'NF { print $1; exit }' "$f")"
    case "$c" in
      '') ;;
      [0-9v]*) version_named "$v" "$c" && { V="not offerable: ${f#"$HOME"/} names $c"; return; } ;;
      *) V="not offerable: ${f#"$HOME"/} names $c, which any installed version could satisfy"; return ;;
    esac
  done < "$DCS_WALK"
  f="$HOME/.nvm/alias/default"
  if [ -e "$f" ]; then
    [ -r "$f" ] || { V="unmeasured: nvm's default alias could not be read"; return; }
    c="$(awk 'NF { print $1; exit }' "$f")"
    case "$c" in
      [0-9v]*) version_named "$v" "$c" && { V="not offerable: it is nvm's default ($c)"; return; } ;;
      '') ;;
      *) V="not offerable: nvm's default is $c, which any installed version could satisfy"; return ;;
    esac
  fi
  shell_mentions ".nvm/versions/node/$v" "" && return
  recently_used "$d" && return
  V=offerable
  D="no project's .nvmrc nor nvm's default names it, and nothing in it changed in $DCS_TOOL_DAYS days"
}
py_rules() { # <version folder>
  local d="${1%/}" v f c home
  v="${d##*/}"
  walk_whole || return
  while IFS= read -r f; do
    case "$f" in
      */.python-version)
        [ -r "$f" ] || { V="unmeasured: the .python-version at ${f#"$HOME"/} could not be read, so which python versions projects need is not known"; return; }
        while read -r c; do
          version_named "$v" "$c" && { V="not offerable: ${f#"$HOME"/} names $c"; return; }
        done < "$f" ;;
      */pyvenv.cfg)
        [ -r "$f" ] || { V="unmeasured: the pyvenv.cfg at ${f#"$HOME"/} could not be read, so which python versions environments need is not known"; return; }
        home="$(sed -n 's/^home *= *//p' "$f" | awk 'NR == 1')"
        case "$home" in "$d"|"$d"/*|"$DCS_HOME/.pyenv/versions/$v"|"$DCS_HOME/.pyenv/versions/$v"/*)
          V="not offerable: the virtual environment at ${f%/pyvenv.cfg} was made from it"; return ;; esac ;;
    esac
  done < "$DCS_WALK"
  f="$HOME/.pyenv/version"
  if [ -e "$f" ]; then
    [ -r "$f" ] || { V="unmeasured: pyenv's global version file could not be read"; return; }
    while read -r c; do version_named "$v" "$c" && { V="not offerable: it is pyenv's global version"; return; }; done < "$f"
  fi
  shell_mentions ".pyenv/versions/$v" "" && return
  recently_used "$d" && return
  V=offerable
  D="no project, environment nor pyenv's global version needs it, and nothing in it changed in $DCS_TOOL_DAYS days"
}

emit() { # <path>   V and D set
  local p="$1" flags="" cred sized kib size ident
  printf '%s\n' "$p" > "$DCS_WORK/ft.one"
  sized="$(dcs_measure "$DCS_WORK/ft.one")"
  IFS="$S" read -r _ kib size ident <<< "$sized"
  cred="$(dcs_credential "$p")"
  [ -n "$cred" ] && { flags=credential; D="${D:+$D; }holds ${cred#"$p"/}"; }
  dcs_item "$p" trash "$kib" "$size" "$V" "$flags" "$D" "$ident"
}

do_scan() {
  dcs_walk_ready
  local rel cmd markers v
  while IFS='|' read -r rel cmd markers; do
    [ -n "$rel" ] || continue
    [ -d "$HOME/$rel" ] && [ ! -L "$HOME/$rel" ] || continue
    D=""; tool_rules "$rel" "$cmd" "$markers"
    emit "$HOME/$rel"
    if [ "$rel" = .pyenv ] && [ "$V" != offerable ]; then
      for v in "$HOME/.pyenv/versions"/*/; do
        [ -d "$v" ] || continue
        D=""; py_rules "$v"; emit "${v%/}"
      done
    fi
  done <<EOF
$DCS_TOOLS
EOF
  for v in "$HOME/.nvm/versions/node"/*/; do
    [ -d "$v" ] || continue
    D=""; node_rules "$v"; emit "${v%/}"
  done
}

do_judge() { # <target>
  local t="${1%/}" rel line
  rel="${t#"$HOME"/}"; [ "$rel" != "$t" ] || rel="${t#"$DCS_HOME"/}"
  [ -d "$t" ] && [ ! -L "$t" ] || { echo "not offerable: it is no longer there"; return 0; }
  case "$rel" in
    .nvm/versions/node/*/*|.pyenv/versions/*/*) ;;
    .nvm/versions/node/?*) dcs_walk_ready; D=""; node_rules "$t"; echo "$V"; return 0 ;;
    .pyenv/versions/?*) dcs_walk_ready; D=""; py_rules "$t"; echo "$V"; return 0 ;;
  esac
  line="$(printf '%s\n' "$DCS_TOOLS" | awk -F '|' -v r="$rel" '$1 == r && !f { print; f = 1 }')"
  [ -n "$line" ] || { echo "not offerable: it is not a folder in the forgotten tools table"; return 0; }
  dcs_walk_ready
  IFS='|' read -r rel cmd markers <<< "$line"
  D=""; tool_rules "$rel" "$cmd" "$markers"
  echo "$V"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) do_judge "${2:-}" ;;
  *) echo "usage: forgotten-tools.sh scan | forgotten-tools.sh judge <target>" >&2; exit 2 ;;
esac
