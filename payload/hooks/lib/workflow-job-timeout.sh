#!/usr/bin/env bash
#
# workflow-job-timeout.sh: the one reader of a GitHub workflow job's `timeout-minutes`.
#
# Two places ask it. tests/test-claude-sync.sh holds every job in every workflow to a timeout above
# the sync suite's own ceiling (#210), and run-all-tests.sh reads the limit of the job it is running
# in so a flake recheck ends, and the report is printed, before the job is cancelled (#1901). They
# ask the same question of the same file, so they read it through this one rule rather than two
# copies of it (L370).
#
# A job is a two space key under `jobs:`, and its block runs to the next such key or the end of the
# file. Its timeout is a `timeout-minutes:` line indented four spaces inside that block, holding a
# whole number; anything else (an expression, a value on another indent) is read as no timeout,
# because guessing a number here decides when a run is cut off (L50).
#
# Sourced. Only builtins and awk, so it finds nothing of its own (test-lib-self-locate.sh).

_workflow_job_timeout_awk='
function close_job() {
  if (job != "") printf "%s\t%s\t%s\n", FILENAME, job, (t == "" ? "NONE" : t)
  job = ""; t = ""
}
/^jobs:[[:space:]]*$/ { injobs = 1; next }
injobs && /^[^[:space:]#]/ { close_job(); injobs = 0 }
injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
  close_job()
  job = $1; sub(/:$/, "", job)
  next
}
injobs && job != "" && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
  t = $2
}
END { close_job() }
'

workflow_job_timeouts(){   # workflow_job_timeouts <file>... -> "<file>\t<job>\t<minutes or NONE>" per job
  local _wjt_f
  for _wjt_f in "$@"; do awk "$_workflow_job_timeout_awk" "$_wjt_f"; done
}

workflow_job_timeout_minutes(){   # workflow_job_timeout_minutes <file> <job> -> its minutes; 1 when it has none
  local _wjt_m
  _wjt_m="$(workflow_job_timeouts "$1" 2>/dev/null | awk -F'\t' -v j="$2" '$2 == j { print $3; exit }')"
  case "$_wjt_m" in
    ''|NONE|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$_wjt_m"
}
