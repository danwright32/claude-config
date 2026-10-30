#!/usr/bin/env bash
#
# spool-end-marker.sh: the files issue-spool-session-end.sh leaves its failures in, for the next
# prompt to say (claude-config#1949). Sourced, never run, by that hook, which writes them, and by
# sync-stuck-notice.sh, which says them once on a prompt and removes them. One place for the paths,
# so the writer and the reader cannot drift apart; test-session-end-notice.sh drives both.
#
# Nothing a SessionEnd hook says has been seen to reach the person (lib/hook-notice.sh, "THAT
# RESTED ON THE DOCUMENTATION"), while a UserPromptSubmit systemMessage has. So a failure at the
# end of one session is said at the first prompt of the next.
#
#   SEM_SPOOL_FILE   in the spool root, beside what it reports on
#   SEM_TMP_FILE     in TMPDIR, for when the spool is what cannot be written. Named after the spool
#                    root it stands in for, so a test's throwaway spool never shares a file with
#                    the real one.
#
# The spool root is read as issue_spool_root in lib/issue-spool.sh reads it. Under a test run with
# the spool left at its real place, both are empty, so neither hook writes or takes a marker there:
# the rule that library keeps for every write into the real spool (claude-config#278).

sem_root="${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"
if [ -n "${CLAUDE_SUITE_RUN_ID:-}" ] && [ "$sem_root" = "${HOME%/}/.claude-issue-spool" ]; then
  SEM_SPOOL_FILE=""
  SEM_TMP_FILE=""
else
  SEM_SPOOL_FILE="${sem_root%/}/session-end-failed"
  sem_key="${sem_root//[^A-Za-z0-9_-]/_}"
  [ "${#sem_key}" -le 150 ] || sem_key="${sem_key: -150}"
  SEM_TMP_FILE="${TMPDIR:-/tmp}"
  SEM_TMP_FILE="${SEM_TMP_FILE%/}/claude-issue-spool-session-end-failed.$sem_key"
  unset sem_key
fi
unset sem_root
