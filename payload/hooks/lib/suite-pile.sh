#!/usr/bin/env bash
#
# suite-pile.sh: have this repo's test suites piled up on this Mac? (claude-config#444, #466)
#
# ONE copy of the question, asked by two callers: `claude-sync status`, which prints the whole
# report, and hooks/suite-pile-notice.sh, which says it once in the session on a prompt. The notice
# exists because nobody runs status while a pile is slowing every session, and a second copy of the
# rule beside it would be two definitions drifting apart until status and the notice disagree about
# the same machine (L41, L370).
#
# On 2026-09-18 559 of this repo's suite processes had run for up to seven hours at zero CPU on a
# Mac six agents were working on, 152 of them copies of test-run-all-tests.sh.
#
# A suite process is a `test-*.sh` or the runner, run from anywhere this repo's scripts live: a
# checkout or worktree (whose path holds `claude-config`), the installed hooks, or the named scratch
# the suites build their fixtures in. It is a pile on either of two shapes, each derived in
# DESIGN.md: any one of them older than SYNC_SUITE_MAX_AGE, and more of them started independently
# than SYNC_SUITE_MAX_ROOTS. What to kill is named by pid, and with -9: a TERM is not enough, which
# was measured on 2026-09-18, since a suite with an EXIT trap blocked on a child holds a TERM until
# the child ends, which for a pile is never.
#
# Sourced, never executed. It reads nothing itself except through suite_pile_table, so a caller
# (and every test) decides what process table is judged (L2).

# The limits. Age: no suite may run longer than the slowest one's own ceiling, the sync suite's
# SUITE_TIMEOUT, so anything older is waiting on something that will not come. Breadth: more
# suites started independently than a whole run of the runner ever has going at once, which is how
# a pile looks before any of it is old. Both are derived in DESIGN.md's measured numbers table.
# Whether they are readable is each caller's to decide: status refuses to run, and the notice stays
# quiet, since a notice must never stand in the way of a prompt.
SYNC_SUITE_MAX_AGE="${SYNC_SUITE_MAX_AGE:-3600}"
SYNC_SUITE_MAX_ROOTS="${SYNC_SUITE_MAX_ROOTS:-8}"

# The process table as pid, ppid, etime, command, behind one seam: SYNC_PS_FIXTURE holds the same
# four fields in the same order. Returns non zero when the table could not be read, so a caller can
# tell "nothing running" from "nothing known" (L215).
suite_pile_table(){
  if [ -n "${SYNC_PS_FIXTURE:-}" ]; then cat "$SYNC_PS_FIXTURE" 2>/dev/null
  else ps -eo pid=,ppid=,etime=,command= 2>/dev/null
  fi
}

# Judges a table on stdin. Prints NOTHING when there is no pile. Otherwise prints
#   SUMMARY <suite processes> <independent starts> <past the age limit> <oldest etime, or ->
#   ROOT <pid> <etime> <command, cut to 160>          at most 20 of them
#   MORE <how many roots were not listed>             only when there were more than 20
#   KILL <pid> <pid> ...                              only when some are past the age limit
suite_pile_scan(){   # $1 = max age in seconds  $2 = max independent starts
  awk -v maxage="$1" -v maxroots="$2" '
    function secs(et,   d, n, p, s) {
      d = 0
      if (index(et, "-") > 0) { d = substr(et, 1, index(et, "-") - 1); et = substr(et, index(et, "-") + 1) }
      n = split(et, p, ":"); s = 0
      if (n == 3) s = p[1] * 3600 + p[2] * 60 + p[3]
      else if (n == 2) s = p[1] * 60 + p[2]
      else s = p[1] + 0
      return d * 86400 + s
    }
    {
      p = $1; pp = $2; et = $3; cmd = ""
      for (i = 4; i <= NF; i++) cmd = cmd (i > 4 ? " " : "") $i
      parent[p] = pp
      if (cmd ~ /(\/test-[A-Za-z0-9_.-]+\.sh|\/run-all-tests\.sh)( |$)/ \
          && (cmd ~ /claude-config/ || cmd ~ /\/\.claude\/hooks\// || cmd ~ /\/claude-sync-work\./)) {
        suite[p] = 1; age[p] = et; keep[p] = cmd
      }
    }
    END {
      n = 0; roots = 0; old = 0; oldest = -1; kill = ""
      for (p in suite) {
        n++
        if (!(parent[p] in suite)) { roots++; root[p] = 1 }
        s = secs(age[p])
        if (s >= maxage) { old++; kill = kill " " p; if (s > oldest) { oldest = s; oldest_et = age[p] } }
      }
      if (n == 0 || (old == 0 && roots <= maxroots)) exit
      printf "SUMMARY %d %d %d %s\n", n, roots, old, (old > 0 ? oldest_et : "-")
      shown = 0
      for (p in root) {
        if (shown < 20) printf "ROOT %s %s %s\n", p, age[p], substr(keep[p], 1, 160)
        shown++
      }
      if (shown > 20) printf "MORE %d\n", shown - 20
      if (old > 0) printf "KILL%s\n", kill
    }'
}

# The sentences both callers say about a pile, from the scan's records on stdin, so status and the
# notice cannot word the same finding two ways (L605).
suite_pile_summary(){   # $1 = max age in seconds  $2 = max independent starts
  awk -v maxage="$1" -v maxroots="$2" '$1 == "SUMMARY" {
    printf "%d suite process(es) from this repo, %d started independently (a whole run of the runner is one, and never has more than %d suites going at once).\n", $2, $3, maxroots
    if ($4 > 0) printf "%d of them older than %ds, the longest any suite may run, the oldest running %s. Those are waiting on something that will not come.\n", $4, maxage, $5
  }'
}

# The pids to kill, space separated, from the scan's records on stdin, or nothing.
suite_pile_kill_pids(){
  sed -n 's/^KILL //p'
}
