#!/usr/bin/env bash
#
# transcripts.sh: disk-clean's Claude Code transcript category (claude-config#1806). See scan-lib.sh
# for the module calls.
#
# Claude Code deletes its own transcripts (~/.claude/projects/**/*.jsonl) after 30 days. Dan kept a
# 90 day rule as a safety net (the plan, 2026-10-27): any transcript older than that is offered,
# moved to the Trash, and its presence at all means Claude Code's own cleanup has stopped, which the
# category's note says.
#
# WHAT A TRANSCRIPT IS (#1851). Not every .jsonl under ~/.claude/projects: on the work MacBook on
# 2026-10-28 all 52 files this category offered were vercel-plugin/skill-injections.jsonl, a
# plugin's sidecar file, and the note blamed Claude Code's cleanup for them. Claude Code lays out
#   <project>/<session id>.jsonl                                    the session's transcript
#   <project>/<session id>/subagents/[...]/agent-<id>.jsonl         a subagent's transcript
#   <project>/<session id>/subagents/workflows/<run>/journal.jsonl  a workflow's journal, not one
#   <project>/<session id>/tool-results/...                         tool output, not one
# Subagent transcripts belong: Claude Code's 30 day cleanup removes them with their session (on
# that Mac the oldest subagent transcript was a day older than the oldest session one, and none was
# past 32 days), so one past 90 days says the same thing a session's does. tr_is_transcript is the
# one predicate the scan and the judge both use.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

P="$HOME/.claude/projects"
TR_ID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
TR_SESSION="^[^/]+/${TR_ID}\\.jsonl\$"
TR_SUBAGENT="^[^/]+/${TR_ID}/subagents/([^/]+/)*agent-[0-9A-Za-z_-]+\\.jsonl\$"

# Succeeds when <path>, relative to ~/.claude/projects, is laid out as a Claude Code transcript.
tr_is_transcript() { # <relative path>
  [[ "$1" =~ $TR_SESSION ]] || [[ "$1" =~ $TR_SUBAGENT ]]
}

tr_rules() { # <target>
  local t="$1" phys old rc
  phys="$(dcs_phys "$t")" || phys=""
  case "$phys" in "$DCS_HOME/.claude/projects/"*.jsonl) ;; *) V="not offerable: it is not a Claude Code transcript"; return ;; esac
  tr_is_transcript "${phys#"$DCS_HOME/.claude/projects/"}" || { V="not offerable: it is not a Claude Code transcript"; return; }
  [ -f "$t" ] && [ ! -L "$t" ] || { V="not offerable: it is no longer there"; return; }
  # A find that failed measured nothing, as when the transcript went between the check above and
  # here, so it is unmeasured, never "changed within N days", and never offerable even when it
  # printed the file first (#1907, L11), as claude-temp.sh judges its find.
  old="$(find "$t" -type f -mtime +"$DCS_TRANSCRIPT_DAYS" -print 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then V="unmeasured: find exited $rc reading it, so whether it changed within $DCS_TRANSCRIPT_DAYS days is not known"; return; fi
  [ -n "$old" ] || { V="not offerable: it changed within $DCS_TRANSCRIPT_DAYS days"; return; }
  V=offerable
}

do_scan() {
  [ -d "$P" ] || return 0
  find "$P" -type f -name '*.jsonl' -mtime +"$DCS_TRANSCRIPT_DAYS" -print > "$DCS_WORK/tr.found" 2> "$DCS_WORK/tr.err"
  if [ -s "$DCS_WORK/tr.err" ]; then
    dcs_status "unmeasured: part of ~/.claude/projects could not be read ($(awk 'NR == 1' "$DCS_WORK/tr.err"))"
  fi
  local f
  : > "$DCS_WORK/tr.paths"
  while IFS= read -r f; do
    tr_is_transcript "${f#"$P/"}" && printf '%s\n' "$f" >> "$DCS_WORK/tr.paths"
  done < "$DCS_WORK/tr.found"
  dcs_measure "$DCS_WORK/tr.paths" > "$DCS_WORK/tr.sized"
  local p kib size ident n=0 m
  while IFS="$S" read -r p kib size ident; do
    tr_rules "$p"
    m="$(dcs_mtime "$p")"
    dcs_item "$p" trash "$kib" "$size" "$V" "" "last written $(dcs_date "${m:-0}")" "$ident"
    n=$((n + 1))
  done < "$DCS_WORK/tr.sized"
  [ "$n" -eq 0 ] || dcs_note "Claude Code's 30 day cleanup appears to have stopped: $n transcript(s) are older than $DCS_TRANSCRIPT_DAYS days."
}

case "${1:-}" in
  scan) do_scan ;;
  judge) tr_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: transcripts.sh scan | transcripts.sh judge <target>" >&2; exit 2 ;;
esac
