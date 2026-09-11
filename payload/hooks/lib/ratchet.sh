#!/usr/bin/env bash
#
# ratchet.sh: the one rule a count based ratchet applies, for the shell callers
# (claude-config#377).
#
# The TWIN of lib/ratchet.py. Two of the guards that need this are shell suites and two are python
# scans, and neither language can call the other's reader without paying a process per run. Twin
# implementations in two languages consume one shared committed fixture (L26): both are driven
# against lib/ratchet-cases.tsv, so they cannot agree on the day they are written and nowhere
# after it.
#
# Sourced, never executed.

# The recorded counts, as "<path> <count>" lines on stdout, sorted by path.
#
# A line that is not `<path>: <number>` is SKIPPED rather than guessed at, because a baseline is
# edited by hand and a half written line read as a zero would silently forgive every finding in
# that file (L50).
ratchet_read_baseline(){   # $1 = baseline text
  printf '%s\n' "${1-}" | awk '
    { sub(/#.*/, "") }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
    $0 == "" { next }
    {
      i = index($0, ":")
      if (i == 0) next
      path = substr($0, 1, i - 1)
      count = substr($0, i + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", count)
      if (path == "" || count !~ /^[0-9]+$/) next
      printf "%s %s\n", path, count
    }' | sort
}

# BOTH directions, always, and never as an else: a run routinely has one of each, and a reader
# reporting only the first would pass every case but that one.
#
# Prints "GROWN <path> <recorded> <measured>" and "STALE <path> <recorded> <measured>" lines, and
# then one "VERDICT <word>" line, where the word is ok, grown, stale or both.
ratchet_verdict(){   # $1 = baseline text, $2 = measured text (the same shape)
  # Both sides are fed into ONE awk as a tagged stream rather than through `-v`. A `-v` value
  # holding a newline is rejected outright by the one true awk the Mac ships, with "newline in
  # string", while gawk takes it: passing them that way works on a Linux runner and fails on the
  # machine this is written on (L434).
  {
    ratchet_read_baseline "${1-}" | sed 's/^/R /'
    ratchet_read_baseline "${2-}" | sed 's/^/M /'
  } | awk '
    $1 == "R" { R[$2] = $3 + 0; next }
    $1 == "M" { M[$2] = $3 + 0; next }
    END {
      grown = 0; stale = 0
      n = 0
      for (p in M) keys[++n] = p
      asortish(keys, n)
      for (i = 1; i <= n; i++) {
        p = keys[i]
        r = (p in R) ? R[p] : 0
        if (M[p] > r) { printf "GROWN %s %d %d\n", p, r, M[p]; grown = 1 }
      }
      n = 0; delete keys
      for (p in R) keys[++n] = p
      asortish(keys, n)
      for (i = 1; i <= n; i++) {
        p = keys[i]
        m = (p in M) ? M[p] : 0
        if (R[p] > m) { printf "STALE %s %d %d\n", p, R[p], m; stale = 1 }
      }
      if (grown && stale) print "VERDICT both"
      else if (grown)     print "VERDICT grown"
      else if (stale)     print "VERDICT stale"
      else                print "VERDICT ok"
    }
    # A plain insertion sort, because `asort` is a gawk extension and the Mac has one true awk.
    # The order is what a person reads, so it may not depend on which awk is installed (L434).
    function asortish(a, n,   i, j, t) {
      for (i = 2; i <= n; i++) {
        t = a[i]; j = i - 1
        while (j >= 1 && a[j] > t) { a[j + 1] = a[j]; j-- }
        a[j + 1] = t
      }
    }'
}
