#!/usr/bin/env bash
#
# transcript-extras.sh: disk-clean's tool output beside transcripts category (claude-config#3235). See
# scan-lib.sh for the module calls.
#
# Beside each session's transcript, <project>/<session id>.jsonl, Claude Code keeps a folder of the
# same id. Its tool-results holds a tool's output too long to put in the transcript, which the
# transcript points to and a resumed session reads back. Once that transcript is gone nothing points
# to it, since resuming needs the transcript. So offered, by moving it to the Trash (it does not come
# back by itself): a <project>/<session id>/tool-results folder whose <session id>.jsonl is gone,
# whose session is in no ~/.claude/sessions/*.json (the live session map), and in which nothing was
# changed or opened in the last 30 days (the floor every kind keeps). The whole category is
# unmeasured when the session map cannot be read, or is empty while Claude Code runs, as
# claude-temp.sh judges it.
#
# Never listed, and said in the kind's note: <session id>/subagents (subagent transcripts, which
# belong to the transcript keep rules, and their small .meta.json records, which Claude Code reads
# with them), <project>/memory (the project's memory files, the only copy of what a session learned),
# and the rest (a session's custom title, a plugin's own files). Measured on the personal MacBook on
# 2026-11-18: 55 tool-results folders (31 MB), none yet without its transcript; 1,210 subagent
# records (4.7 MB).
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

P="$HOME/.claude/projects"
IDS="$DCS_WORK/te.ids"; CWDS="$DCS_WORK/te.cwds"
TE_ID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Sets MAP_WHY to why the session map cannot be trusted, or leaves it empty: unreadable, or empty
# while Claude Code runs, which means the map is wrong, not that every session ended (claude-temp.sh's
# rule, the same reading).
read_map() {
  MAP_WHY=""
  if ! dcs_sessions "$IDS" "$CWDS"; then MAP_WHY="the session map could not be read ($DCS_WHY)"; return; fi
  [ -s "$IDS" ] && return
  dcs_claude_running
  case $? in
    0) MAP_WHY="the session map (~/.claude/sessions) is empty while Claude Code is running, so no session can be told ended" ;;
    2) MAP_WHY="the session map (~/.claude/sessions) is empty, and whether Claude Code is running could not be read" ;;
  esac
}

# Sets V for <target>; read_map has run.
te_rules() { # <target>
  local t="${1%/}" phys rel sdir sid proj
  phys="$(dcs_phys "$t")" || phys=""
  rel="${phys#"$DCS_HOME/.claude/projects/"}"
  # <project>/<session id>/tool-results, nothing more and nothing less.
  case "$phys" in "$DCS_HOME/.claude/projects/"*/*/tool-results) ;; *) V="not offerable: it is not a session's tool output (<project>/<session id>/tool-results in ~/.claude/projects)"; return ;; esac
  sdir="${rel%/tool-results}"; sid="${sdir#*/}"; proj="${sdir%%/*}"
  case "$sid" in */*) V="not offerable: it is not a session's tool output (<project>/<session id>/tool-results in ~/.claude/projects)"; return ;; esac
  [[ "$sid" =~ $TE_ID ]] || { V="not offerable: it is not a session's tool output (<project>/<session id>/tool-results in ~/.claude/projects)"; return; }
  [ -d "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there, or is a link"; return; }
  if [ -e "$DCS_HOME/.claude/projects/$proj/$sid.jsonl" ]; then V="not offerable: its session's transcript is still there, and resuming the session reads it"; return; fi
  if [ -n "$MAP_WHY" ]; then V="unmeasured: $MAP_WHY"; return; fi
  if grep -qixF -- "$sid" "$IDS"; then V="not offerable: a live session ($sid) owns it"; return; fi
  V=offerable
  dcs_floor "$t"
}

do_scan() {
  [ -d "$P" ] || return 0
  read_map
  [ -n "$MAP_WHY" ] && dcs_status "unmeasured: $MAP_WHY"
  find "$P" -mindepth 3 -maxdepth 3 -type d -name tool-results -print > "$DCS_WORK/te.found" 2> "$DCS_WORK/te.err"
  if [ -s "$DCS_WORK/te.err" ]; then
    dcs_status "unmeasured: part of ~/.claude/projects could not be read ($(awk 'NR == 1' "$DCS_WORK/te.err"))"
  fi
  dcs_measure "$DCS_WORK/te.found" > "$DCS_WORK/te.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    te_rules "$p"
    dcs_item "$p" trash "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/te.sized"
  dcs_note "Left out: subagent transcripts and their records, which go with the transcripts, and each project's memory, the only copy of what its sessions learned."
}

case "${1:-}" in
  scan) do_scan ;;
  judge) read_map; te_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: transcript-extras.sh scan | transcript-extras.sh judge <target>" >&2; exit 2 ;;
esac
