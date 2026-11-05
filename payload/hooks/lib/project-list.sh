#!/usr/bin/env bash
#
# lib/project-list.sh: the one reader of the Projects section of CLAUDE.md (claude-config#2112).
#
# Sourced by check-project-list.sh, which checks the list, and lib/write-project-list-local.sh,
# which writes a Mac's own projects.local.txt from an earlier version of that section. Both have to
# agree on what a machine's block is and what an entry is, or the writer would hand the check a
# file it reads differently, so the rules live here once.
#
# The shape it reads:
#   ## Projects
#   On <hostname> (any name a person calls it):
#   - `<path>`: anything
#   - A sentence holding the import @projects.local.txt, which says this machine's entries are kept
#     in that Mac's own file rather than here.
#
# A machine's entries move to that file when they must not appear in the public CLAUDE.md, as the
# work MacBook's did (#2112). The import sits INSIDE a sentence on purpose: Claude Code loads an
# inline import, and skips one whose file is missing without a word (both measured headless on
# 2026-11-04), while claude-sync refuses a pull whose line start import is missing
# (verify_rule_imports). The file is missing on every other Mac by design.

# The local file's name, beside the CLAUDE.md it belongs to. *.local.txt is a shape the sync
# already keeps on the Mac that wrote it (LOCAL_FILE_GLOBS in claude-sync, and .gitignore).
PL_LOCAL_NAME="projects.local.txt"

# stdin: a CLAUDE.md. stdout: the lines of its Projects section, heading excluded.
pl_section() {
  awk '/^## Projects[[:space:]]*$/ {inside=1; next} /^## / {inside=0} inside {print}'
}

# A block heading's hostname: the first word after "On ", any trailing colon dropped. The rest of
# the heading, like "(personal MacBook)", is for people. Prints nothing for a line that is not one.
pl_heading_host() { # <line>
  case "$1" in
    "On "*:) ;;
    *) return 0 ;;
  esac
  local h="${1#On }"
  h="${h%:}"
  h="${h%% *}"
  printf '%s' "$h"
}

# stdin: a Projects section. stdout: how many machine blocks it names.
pl_block_count() {
  local line n=0
  while IFS= read -r line; do
    [ -n "$(pl_heading_host "$line")" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# stdin: a Projects section. stdout: the lines of <host>'s block, its heading excluded.
pl_block() { # <host>
  local line h current=""
  while IFS= read -r line; do
    h="$(pl_heading_host "$line")"
    if [ -n "$h" ]; then current="$h"; continue; fi
    [ "$current" = "$1" ] && printf '%s\n' "$line"
  done
  return 0
}

# stdin: lines. stdout: the entry lines among them, whole. An entry is a list item whose path is
# in backticks; anything else is prose.
pl_entry_lines() {
  local line p
  while IFS= read -r line; do
    case "$line" in
      '- `'*) ;;
      *) continue ;;
    esac
    p="${line#- \`}"; p="${p%%\`*}"
    [ -n "$p" ] && printf '%s\n' "$line"
  done
  return 0
}

# stdin: lines. stdout: the path of each entry, one per line.
pl_entry_paths() {
  local line p lines
  lines="$(pl_entry_lines)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="${line#- \`}"; p="${p%%\`*}"
    printf '%s\n' "$p"
  done <<EOF
$lines
EOF
  return 0
}

# stdin: a machine's block. True when it says its entries are kept in the local file: a line
# importing it inside a sentence, which is the only form claude-sync lets be missing.
pl_names_local_file() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *[![:space:]]*" @$PL_LOCAL_NAME"|*[![:space:]]*" @$PL_LOCAL_NAME"[[:space:]]*) return 0 ;;
    esac
  done
  return 1
}
