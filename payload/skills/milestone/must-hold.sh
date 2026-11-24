#!/usr/bin/env bash
# must-hold.sh: read the "Must always be true" list of a plan, an issue body or a pull request body
# (claude-config#3457). The list's rules are in MUST-ALWAYS-BE-TRUE.md, beside this file.
#
#   must-hold.sh check <file>           is the list there and well formed
#   must-hold.sh check --built <file>   the same, and every rule something keeps true also says what
#                                       was seen to fail with that thing taken out
#   must-hold.sh list <file>            one line per rule, tab separated:
#                                       number, rule, what is still possible, kind of holder, its name
#
# Exit codes, each set by this script:
#   0: the list is well formed
#   1: the list has faults, each named on stderr
#   2: wrong usage, or the path given cannot be read
#   3: nothing in what was read is a "Must always be true" section
# A body with no list and a list with a fault are never reported as sound, and `list` prints no
# rules from a list with a fault, so nothing reads half a list. This refuses nothing by itself: no
# gate runs it.
set -uo pipefail

usage(){
  echo "usage: must-hold.sh check [--built] <file> | must-hold.sh list <file>" >&2
  exit 2
}

mode="${1:-}"
[ -n "$mode" ] || usage
shift
built=0
case "$mode" in
  check) if [ "${1:-}" = "--built" ]; then built=1; shift; fi ;;
  list) ;;
  *) usage ;;
esac
[ "$#" -eq 1 ] || usage
file="$1"
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "must-hold: cannot read $file, so no list was checked." >&2
  exit 2
fi

awk -v mode="$mode" -v built="$built" -v file="$file" '
  function fault(msg) { faults[++nfaults] = msg }
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
  # The kind a holder line starts with, and its name in holder_name. Empty when it is no known kind.
  function kind_of(v,   i, k) {
    holder_name = ""
    if (v == "nothing yet") return "nothing yet"
    if (index(v, "nothing yet, ") == 1) { holder_name = trim(substr(v, 14)); return holder_name == "" ? "" : "nothing yet" }
    for (i = 1; i <= nkinds; i++) {
      k = kinds[i]
      if (index(v, k " ") == 1) { holder_name = trim(substr(v, length(k) + 2)); return holder_name == "" ? "" : k }
    }
    return ""
  }
  BEGIN {
    # A kind counts only at the very start of the line and with a name after it, so "property test
    # of refunds" is a property test and "test" alone, or "tested by hand", is no kind at all.
    nkinds = split("database constraint|property test|model check|guard|type|test", kinds, "|")
  }
  { sub(/\r$/, "") }
  /^[ \t]*(```|~~~)/ { fenced = !fenced; if (insec) fault("line " NR " is not part of the list: " $0); next }
  fenced { if (insec) fault("line " NR " is not part of the list: " $0); next }
  /^#+[ \t]/ {
    if (insec) { insec = 0; done = 1; next }
    if (!done && tolower($0) ~ /^#+[ \t]+must always be true[ \t]*$/) { insec = 1; found = 1 }
    next
  }
  !insec { next }
  /^[ \t]*$/ { next }
  /^- R[0-9]+\. / {
    id = $0; sub(/^- /, "", id); sub(/\. .*$/, "", id)
    text = $0; sub(/^- R[0-9]+\. /, "", text); text = trim(text)
    if (id in seen) fault(id " is used for more than one rule")
    seen[id] = 1
    order[++nrules] = id; cur = nrules
    rule[cur] = text
    if (text == "") fault(id " has no sentence")
    next
  }
  /^[ \t]+- (Still possible|Kept true by|Seen to fail):/ {
    if (!cur) { fault("line " NR " comes before any rule: " $0); next }
    label = $0; sub(/^[ \t]+- /, "", label); sub(/:.*$/, "", label)
    value = $0; sub(/^[ \t]+- [^:]+:/, "", value); value = trim(value)
    if ((cur, label) in got) fault(order[cur] " has more than one \047" label ":\047 line")
    got[cur, label] = 1
    if (value == "") fault(order[cur] " has an empty \047" label ":\047 line")
    val[cur, label] = value
    next
  }
  /^Not covered:/ {
    value = $0; sub(/^Not covered:/, "", value); value = trim(value)
    if (covered) fault("more than one \047Not covered:\047 line")
    covered = 1; cur = 0
    if (value == "") fault("the \047Not covered:\047 line names nothing")
    next
  }
  /^None[.:]?[ \t]*$/ { none = 1; fault("None needs its reason: write \047None: <why this has no such rule>\047"); next }
  /^None: / { none = 1; next }
  { fault("line " NR " is not part of the list: " $0) }
  END {
    if (!found) {
      print "must-hold: " file " has no \047Must always be true\047 section." > "/dev/stderr"
      exit 3
    }
    if (none && nrules) fault("the section says None and also lists rules")
    if (!none && !nrules && !nfaults) fault("the section is empty: list the rules, or write \047None: <why>\047")
    for (i = 1; i <= nrules; i++) {
      id = order[i]
      if (!((i, "Still possible") in got)) fault(id " has no \047Still possible:\047 line, so it would pass if the feature did nothing")
      if (!((i, "Kept true by") in got)) fault(id " has no \047Kept true by:\047 line: name what keeps it true, or write \047nothing yet\047")
      else if (val[i, "Kept true by"] != "") {
        kind[i] = kind_of(val[i, "Kept true by"]); name[i] = holder_name
        if (kind[i] == "") fault(id " is kept true by no known kind: start the line with database constraint, type, test, property test, model check or guard and then its name, or with \047nothing yet\047")
        else if (built == 1 && kind[i] != "nothing yet" && !((i, "Seen to fail") in got)) fault(id " has no \047Seen to fail:\047 line: quote what failed with its holder taken out")
      }
    }
    if (nrules && !covered) fault("no \047Not covered:\047 line, so nothing says what the rules leave out")
    if (nfaults) {
      for (i = 1; i <= nfaults; i++) print "must-hold: " faults[i] > "/dev/stderr"
      exit 1
    }
    if (mode == "list") {
      for (i = 1; i <= nrules; i++) printf "%s\t%s\t%s\t%s\t%s\n", order[i], rule[i], val[i, "Still possible"], kind[i], name[i]
    } else if (none) {
      print "must-hold: none, with a reason"
    } else {
      print "must-hold: " nrules (nrules == 1 ? " rule" : " rules") ", each with what is still possible and what keeps it true"
    }
  }
' "$file"
