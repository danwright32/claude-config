#!/usr/bin/env bash
# tree-proof.sh: may a head whose own checks are still running carry a green it has already earned?
# (claude-config#2310)
#
# WHY. When a pull request falls behind main, merge-when-ready.sh updates it and waits for the new
# head's checks, a full suite run of 30 to 38 minutes here. On 2026-11-05 other sessions kept merging,
# so #2282 was updated three times, never merged inside its 60 minute hold on the merge line, and
# went to the back with twelve pull requests behind it. The lessons review already carries a review
# across an update that changed nothing it reads (lib/pr-review.sh carry_review, #1280); this is the
# suite's equivalent, for the one case L312 names as safe: the updated head's tree is byte for byte a
# tree the suite has already passed on.
#
# THE PROOF, every part of it read from GitHub, none of it remembered by whoever asks:
#   1. a parent of the head has the head's tree, byte for byte (the tree object ids are equal);
#   2. every check on that parent finished green, there is at least one, and every one came from a
#      GitHub Actions run (a status from anywhere else names no commit it tested, so it proves nothing);
#   3. every one of those runs finished green, was a pull request run, and names the base it ran
#      beside, and the parent contains that base. A pull request run tests the parent merged with its
#      base as it was then, so only a base the parent already held makes the tree it tested the
#      parent's own (L312: two runs beside two different bases are not redundant);
#   4. the head itself has no check that has already failed, and no check the parent never passed.
# Anything unread, unanswered or unexpected carries nothing, and the caller waits for the head's own
# checks as it did before (fail closed). A tree that differs from every parent's carries nothing.
#
# Sourced by block-red-merge.sh, which judges the merge with it, and by merge-when-ready.sh, which
# uses it only to decide when to ask that gate (one predicate, L263, L370).
#
#   tp_carried_green <owner/name> <head sha> <account or empty> <the head's statusCheckRollup as JSON>
#     returns 0 when the head carries a parent's green and 1 otherwise; sets TP_FROM (the parent, on
#     0) and TP_WHY (the proof, or why it does not hold, as a clause).
#   tp_record <who> <owner/name> <pr> <head> <taken|not-taken> <parent or empty> <why>
#     appends one line to the record (see THE RECORD); returns non zero, saying where, when it cannot.
#   bash tree-proof.sh rate
#     prints how often the skip was taken of how often it was considered.

TP_QUERY='query($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){object(oid:$oid){... on Commit{oid tree{oid} parents(first:3){totalCount nodes{oid tree{oid} statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{__typename ... on CheckRun{name status conclusion startedAt checkSuite{workflowRun{databaseId event workflow{name}}}} ... on StatusContext{context state createdAt}}}}}}}}}}'

# gh as the account that could see the pull request, when that is not the active one.
tp__gh(){   # $1 = account or empty, then gh's arguments
  local account="$1" tok=""; shift
  [ -n "$account" ] && tok="$(gh auth token -u "$account" 2>/dev/null)"
  if [ -n "$tok" ]; then GH_TOKEN="$tok" gh "$@"; else gh "$@"; fi
}
# The first line that holds anything, cut to 200 characters, read without a pipe that stops early.
tp__first(){ local l; while IFS= read -r l; do [ -n "${l//[[:space:]]/}" ] && { printf '%s' "${l:0:200}"; return 0; }; done <<<"$1"; }

tp_carried_green(){
  local slug="$1" head="$2" account="${3:-}" rollup="${4:-[]}"
  local graph errf rc htree cand="" p ptree pctx key missing runs ids bases b cmp behind red
  TP_FROM=""; TP_WHY=""
  if [ -z "$slug" ] || [ -z "$head" ] || [ "${slug#*/}" = "$slug" ]; then TP_WHY="no repository or head to read"; return 1; fi
  command -v jq >/dev/null 2>&1 || { TP_WHY="jq is not installed, so nothing GitHub answers can be read"; return 1; }

  # 4a. A check on the head that has already failed is news about this tree: never carried past.
  red="$(printf '%s' "$rollup" | jq -r '[.[]? | {n: (.name // .context // "check"), r: ((.conclusion // .state // "") | ascii_upcase)} | select(.r | IN("", "PENDING", "EXPECTED", "SUCCESS", "NEUTRAL", "SKIPPED") | not) | "\(.n)=\(.r)"] | join(", ")' 2>/dev/null)" \
    || { TP_WHY="the head's own checks could not be read"; return 1; }
  [ -z "$red" ] || { TP_WHY="a check on the head itself has already failed ($red)"; return 1; }

  # 1. The head's tree and each parent's, with each parent's checks, in one read.
  errf="$(mktemp "${TMPDIR:-/tmp}/tp-graph.XXXXXX" 2>/dev/null)" || errf=/dev/null
  graph="$(tp__gh "$account" api graphql -f query="$TP_QUERY" -f owner="${slug%%/*}" -f name="${slug#*/}" -f oid="$head" 2>"$errf")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    TP_WHY="could not read the head's commit and its parents from GitHub ($(tp__first "$(cat "$errf" 2>/dev/null)")${rc:+, exit $rc})"
    [ "$errf" != /dev/null ] && rm -f "$errf"; return 1
  fi
  [ "$errf" != /dev/null ] && rm -f "$errf"
  htree="$(printf '%s' "$graph" | jq -r '.data.repository.object.tree.oid // ""' 2>/dev/null)"
  [ -n "$htree" ] || { TP_WHY="GitHub's answer about the head's commit was not one this can read ($(tp__first "$graph"))"; return 1; }
  for p in $(printf '%s' "$graph" | jq -r '.data.repository.object.parents.nodes[]? | "\(.oid):\(.tree.oid)"'); do
    ptree="${p#*:}"
    if [ "$ptree" = "$htree" ]; then cand="${p%%:*}"; break; fi
  done
  [ -n "$cand" ] || { TP_WHY="its tree differs from every parent's"; return 1; }

  # 2. Every check on that parent green, at least one, each from an Actions run.
  pctx="$(printf '%s' "$graph" | jq -c --arg c "$cand" '.data.repository.object.parents.nodes[] | select(.oid == $c) | .statusCheckRollup.contexts // {}')"
  [ "$(printf '%s' "$pctx" | jq -r '.pageInfo.hasNextPage // false')" = false ] \
    || { TP_WHY="${cand:0:7} has more checks than one read returns"; return 1; }
  [ "$(printf '%s' "$pctx" | jq '[.nodes[]?] | length')" -gt 0 ] || { TP_WHY="${cand:0:7}, which has the same tree, has no checks at all"; return 1; }
  key="$(printf '%s' "$pctx" | jq -r '[.nodes[] | select(.__typename != "CheckRun" or (.checkSuite.workflowRun.databaseId // null) == null) | (.context // .name // "check")] | join(", ")')"
  [ -z "$key" ] || { TP_WHY="${cand:0:7} carries a status from outside GitHub Actions ($key), which names no commit it tested"; return 1; }
  key="$(printf '%s' "$pctx" | jq -r '[.nodes[] | select(((.conclusion // "") | ascii_upcase | IN("SUCCESS", "NEUTRAL", "SKIPPED")) | not) | "\(.name)=\(if (.conclusion // "") == "" then (.status // "PENDING") else .conclusion end)"] | join(", ")')"
  [ -z "$key" ] || { TP_WHY="the checks of ${cand:0:7}, which has the same tree, were not all green ($key)"; return 1; }

  # 4b. Every check on the head is one the parent passed.
  missing="$(jq -rn --argjson h "$rollup" --argjson p "$pctx" '
    ([$p.nodes[] | "\(.checkSuite.workflowRun.workflow.name // "")/\(.name)"]) as $green
    | [$h[]? | "\(.workflowName // "")/\(.name // .context // "check")" | select(IN($green[]) | not)] | unique | join(", ")' 2>/dev/null)" \
    || { TP_WHY="the head's checks could not be set beside ${cand:0:7}'s"; return 1; }
  [ -z "$missing" ] || { TP_WHY="the head has a check ${cand:0:7} never passed ($missing)"; return 1; }

  # 3. The runs those checks came from: finished green, pull request runs, beside a base the parent held.
  errf="$(mktemp "${TMPDIR:-/tmp}/tp-runs.XXXXXX" 2>/dev/null)" || errf=/dev/null
  runs="$(tp__gh "$account" api "repos/$slug/actions/runs?head_sha=$cand&per_page=100" 2>"$errf")"; rc=$?
  if [ "$rc" -ne 0 ] || [ "$(printf '%s' "$runs" | jq -r '(.workflow_runs | type) == "array"' 2>/dev/null)" != true ]; then
    TP_WHY="could not read the workflow runs of ${cand:0:7} ($(tp__first "$(cat "$errf" 2>/dev/null) $runs"))"
    [ "$errf" != /dev/null ] && rm -f "$errf"; return 1
  fi
  [ "$errf" != /dev/null ] && rm -f "$errf"
  ids="$(jq -rn --argjson r "$runs" --argjson p "$pctx" '
    ([$r.workflow_runs[].id]) as $have | [$p.nodes[].checkSuite.workflowRun.databaseId | select(IN($have[]) | not)] | unique | map(tostring) | join(", ")')"
  [ -z "$ids" ] || { TP_WHY="a check of ${cand:0:7} came from a run GitHub does not list for it (run $ids)"; return 1; }
  key="$(printf '%s' "$runs" | jq -r '[.workflow_runs[] | select((.status != "completed") or ((.conclusion // "") | IN("success", "neutral", "skipped") | not) or (.event != "pull_request")) | "\(.name // "a workflow") (\(.event // "?"), \(.status // "?") \(.conclusion // ""))"] | join(", ")')"
  [ -z "$key" ] || { TP_WHY="a workflow run of ${cand:0:7} did not finish green as a pull request run: $key"; return 1; }
  bases="$(printf '%s' "$runs" | jq -r '[.workflow_runs[] | if ((.pull_requests // []) | length) == 0 then "none" else .pull_requests[].base.sha // "none" end] | unique | .[]')"
  case $'\n'"$bases"$'\n' in *$'\n'none$'\n'*|$'\n'$'\n') TP_WHY="a run of ${cand:0:7} names no pull request base, so what it was tested beside is unknown"; return 1 ;; esac
  for b in $bases; do
    [ "$b" = "$cand" ] && continue
    cmp="$(tp__gh "$account" api "repos/$slug/compare/$b...$cand?per_page=1" 2>&1)"; rc=$?
    behind="$(printf '%s' "$cmp" | jq -r '.behind_by // ""' 2>/dev/null)"
    case "$behind" in
      0) ;;
      ''|*[!0-9]*) TP_WHY="could not read whether ${cand:0:7} contains ${b:0:7}, the base its run was tested beside ($(tp__first "$cmp"), exit $rc)"; return 1 ;;
      *) TP_WHY="the run of ${cand:0:7} was tested beside base ${b:0:7}, which ${cand:0:7} does not contain, so the tree it passed was not its own"; return 1 ;;
    esac
  done
  TP_FROM="$cand"
  TP_WHY="its tree is byte for byte the tree of ${cand:0:7}, whose checks all passed beside a base it already held"
  return 0
}

# THE RECORD (#2310): one line per decision, so how often the skip fires, and of how many heads it was
# considered for, can be measured rather than guessed (L557, L654). Tab separated: epoch seconds, who
# decided, repository, pull request, head, taken or not-taken, the parent carried from, and why. Kept
# under this Mac's own state, never synced. TP_LEDGER_DIR and TP_NOW (a command printing epoch
# seconds) are the test seams.
tp__ledger(){ printf '%s/decisions.tsv' "${TP_LEDGER_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/tree-proof}"; }
tp__now(){ local t=""; [ -n "${TP_NOW:-}" ] && t="$("$TP_NOW" 2>/dev/null)"; case "$t" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$t" ;; esac; }
tp__field(){ printf '%s' "$1" | tr '\t\n' '  '; }
tp_record(){   # $1 who, $2 slug, $3 pr, $4 head, $5 taken|not-taken, $6 parent, $7 why
  local f; f="$(tp__ledger)"
  if ! mkdir -p "${f%/*}" 2>/dev/null || ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(tp__now)" "$(tp__field "$1")" "$(tp__field "$2")" \
       "$(tp__field "$3")" "$(tp__field "$4")" "$(tp__field "$5")" "$(tp__field "$6")" "$(tp__field "$7")" >> "$f" 2>/dev/null; then
    echo "tree-proof: could not write the decision to $f" >&2
    return 1
  fi
}
tp_rate(){
  local f; f="$(tp__ledger)"
  [ -s "$f" ] || { echo "tree-proof: nothing recorded yet in $f, so there is no rate to give."; return 0; }
  awk -F'\t' '{ n[$2]++; if ($6 == "taken") t[$2]++ }
    END { for (w in n) printf "%s: the identical tree skip was taken %d of %d time(s) it was considered\n", w, t[w] + 0, n[w] }' "$f"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    rate) tp_rate ;;
    *) echo "usage: bash tree-proof.sh rate" >&2; exit 64 ;;
  esac
fi
