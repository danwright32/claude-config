#!/usr/bin/env bash
#
# stat-order.sh: the one rule for the order a shell or script file asks stat in (claude-config#2003,
# #1874, #2016). The disk cleaning skill's guard and the repository's both read it (#2014).
#
# GNU stat (the Ubuntu CI runner) reads -f as "report on the FILE SYSTEM": it prints a block about
# the filesystem for the path, fails on the format it was handed as another path, and so answers
# something else entirely rather than failing cleanly. BSD stat (macOS) refuses GNU's -c and prints
# nothing on stdout. So a stat that asks BSD's -f first is right on the Mac and wrong on Linux, and
# nothing on the Mac can see it. Every stat therefore asks GNU's -c first, in one of two forms:
#
#   on one line        stat -c '%s' "$p" 2>/dev/null || stat -f '%z' "$p" 2>/dev/null
#   behind a probe     if stat -c '%d:%i' / >/dev/null 2>&1; then <GNU> else <BSD> fi
#
# The rule is the one the disk cleaning skill's guard first applied to its removal tool's readers,
# and then to the whole skill (#1874); it lives here so the repository wide guard
# (tests/test-stat-order.sh) and any other suite read stat the same way rather than through copies
# (L613). An allowance for a form that is BSD only on purpose is the CALLER's, named in that
# caller's suite with its reason; this rule allows nothing by name.
#
# A TypeScript or JavaScript file (a mod, a skill's helper) runs stat from an argument list, so BSD
# stat there is two quoted words, 'stat' and '-f' (#2016): job-watcher and scope-modes ran it, unseen
# by a rule that read only the shell spelling. In those files the rule reads such a list, in any of
# the three quotes, as the shell line it runs, and a `??` between two runs as the shell's `||`, so
# the same two forms pass. A mod is better served by $.fs.stat, which asks no stat at all.
#
# Sourced, never executed.

# Prints "<file>:<line>: <text>" for every stat that asks BSD's -f without GNU's -c first. One awk
# pass over every file named (L297). A comment line is not code and is skipped: `#` in a shell file,
# `//`, `/*` or a block comment's leading `*` in a script file. A probe is open from its `if stat -c`
# to the next `fi`, and BSD is allowed only after its `else`: a nested if inside a probe closes it
# early, which refuses more, never less. The patterns are written `stat -[f]` so this file holds no
# literal BSD first stat for a guard to read in itself.
stat_order_scan() { # <file>...
  awk -v q="[\"'\`]" '
    FNR == 1 { probe = 0; inelse = 0; script = (FILENAME ~ /\.(ts|tsx|js|mjs|cjs)$/) }
    /^[[:space:]]*#/ { next }
    script && /^[[:space:]]*(\/\/|\/\*|\*)/ { next }
    {
      # Padded, so a word at either end of the line needs no anchor inside a group, which not
      # every awk reads alike (BSD awk on the Mac, gawk or mawk on Linux).
      l = " " $0 " "
      if (script) {
        # An argument list read as the line it runs: 'stat', '-f' becomes stat -f, and a ?? the ||.
        gsub(q "stat" q "[[:space:]]*,[[:space:]]*" q "-", "stat -", l)
        gsub(/\?\?/, "||", l)
      }
      if (l ~ /[^[:alnum:]_]if stat -c /) { probe = 1; inelse = 0 }
      if (probe && l ~ /[;[:space:]]else[;[:space:]]/) inelse = 1
      if (l ~ /stat -[f]/) {
        if (l ~ /stat -c[^|]*\|\|[^|]*stat -[f]/) ;
        else if (probe && inelse) ;
        else print FILENAME ":" FNR ": " $0
      }
      if (probe && l ~ /[;[:space:]]fi[;[:space:]]/) { probe = 0; inelse = 0 }
    }' "$@"
}
