#!/usr/bin/env bash
#
# review-check.sh: turns the selection Dan copied from disk-clean's review page into disk-remove.sh's
# plan, or refuses it, saying why (claude-config#1807).
#
#   bash ~/.claude/skills/disk-clean/review-check.sh --out <folder> --payload <file> --plan <plan file>
#
#   --out      the folder the review page was rendered into, which holds the nonce that page carries
#              (review-lib.sh, dcrv_write_nonce)
#   --payload  a file holding exactly what Dan pasted: {"scan_id", "nonce", "count", "ids"} as JSON,
#              on one line or laid out over several
#   --plan     where to write the plan: "scan_id <id>", "count <n>", then "item <id>" per id, the
#              layout disk-remove.sh --plan reads. Written through a temp file renamed into place, and
#              only when every check passes; a refusal leaves whatever was there.
#
# IN ORDER, each refusal its own exit code and message, so what went wrong is never guessed at (L11):
#   2  it cannot be checked: an option it does not know, a missing --out, --payload or --plan, no
#      scan record or one cut short, no review page rendered in --out, or a payload that is not
#      exactly that JSON (an unknown or missing key, a count that is not a number, an id named twice,
#      a string holding an escape or a control character, anything after the closing brace)
#   3  its scan_id is not the last scan's, so a newer scan has replaced the one Dan reviewed
#   4  its nonce is not the one the page rendered last carries: it came from an older copy of the
#      page, or is a selection left on the clipboard from an earlier run
#   5  its count is not the number of ids it lists, so some were lost between the page and the chat
#   7  it chose nothing
#   6  an id is not offerable in the scan now: never in it, or kept, unmeasured or already removed.
#      Every such id is named with the reason.
#   0  the plan is written, and what it will remove is printed: each category's count and total,
#      then every item by path, with any warning its flags carry, for the confirm step to name.
#
# Commands: awk cat mktemp mv rm, the libraries it sources, and the builtins. bash 3.2 safe.
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
LIBS="$HERE/../../hooks/lib"
. "$HERE/review-lib.sh" || { echo "disk-clean review: review-lib.sh is missing beside it, so nothing was planned."; exit 2; }
. "$LIBS/disk-clean-record.sh" || { echo "disk-clean review: hooks/lib/disk-clean-record.sh is missing, so nothing was planned."; exit 2; }
. "$LIBS/disk-clean-units.sh" || { echo "disk-clean review: hooks/lib/disk-clean-units.sh is missing, so nothing was planned."; exit 2; }

S=$'\037'
refuse() { # <exit code> <sentence>
  echo "disk-clean review: $2"
  exit "$1"
}

OUT="" PAYLOAD="" PLAN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out|--payload|--plan)
      [ "$#" -ge 2 ] || refuse 2 "$1 needs a value, so nothing was planned."
      case "$1" in --out) OUT="$2" ;; --payload) PAYLOAD="$2" ;; --plan) PLAN="$2" ;; esac
      shift 2 ;;
    -h|--help) awk 'NR > 1 && /^set -uo/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) refuse 2 "it does not know '$1' (it takes --out, --payload and --plan), so nothing was planned." ;;
  esac
done
[ -n "$OUT" ] || refuse 2 "--out, the folder the review page was rendered into, is missing, so nothing was planned."
[ -n "$PAYLOAD" ] || refuse 2 "--payload, the file holding what was pasted, is missing, so nothing was planned."
[ -n "$PLAN" ] || refuse 2 "--plan, where to write the plan, is missing, so nothing was planned."

# Test mode is the harness's: HOME and the plan must be inside the throwaway directory.
if [ -n "${DISK_CLEAN_TEST_ROOT:-}" ]; then
  dc_home_isolated "${HOME:-}" "$DISK_CLEAN_TEST_ROOT" || refuse 2 "test mode, but HOME ('${HOME:-}') is not inside the throwaway directory $DISK_CLEAN_TEST_ROOT, so nothing was planned."
  _dcrv_allowed "$PLAN" || refuse 2 "test mode, and the plan '$PLAN' is outside the throwaway directory, so nothing was planned."
fi
[ -n "${HOME:-}" ] || refuse 2 "HOME is not set, so there is no scan record to check against, and nothing was planned."

REC="$HOME/.claude/state/disk-clean/last-scan.json"
[ -f "$REC" ] || refuse 2 "there is no scan record at $REC, so there is no scan to check the selection against, and nothing was planned. Scan again."
dcr_complete "$REC" || refuse 2 "the scan record $REC stopped partway through being written, so it cannot be checked against, and nothing was planned. Scan again."
LAST="$(dcr_header "$REC" scan_id)" || refuse 2 "the scan record $REC names no scan, so nothing was planned. Scan again."
NONCE="$(dcrv_read_nonce "$OUT")" || refuse 2 "no review page was rendered in $OUT (it holds no $DCRV_NONCE), so there is nothing the selection could have come from, and nothing was planned."
[ -f "$PAYLOAD" ] && [ -r "$PAYLOAD" ] || refuse 2 "the payload file $PAYLOAD is not there to read, so nothing was planned."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-review.XXXXXXXX")" || refuse 2 "could not make a working folder under ${TMPDIR:-/tmp}, so nothing was planned."
trap 'rm -rf "$WORK"' EXIT

# ---------- the payload: exactly {"scan_id", "nonce", "count", "ids"}, nothing more ----------
# Parsed by hand, because neither jq nor python3 is a tool a disk-clean script may call. Strings may
# escape only \ " and /, which nothing the page copies ever needs; anything else is refused rather
# than decoded, so the id checked is the id written (L50).
awk 'BEGIN { RS = "\001" } { s = s $0 } END {
  n = length(s); i = 1
  if (n == 0) fail("it is empty")
  ws(); expect("{")
  ws()
  if (ch() != "}") {
    while (1) {
      ws(); k = str("a key"); ws(); expect(":"); ws()
      if (k in seen) fail("it names the key \"" k "\" twice")
      seen[k] = 1
      if (k == "scan_id" || k == "nonce") { v[k] = str("the " k); if (v[k] == "") fail("its " k " is empty") }
      else if (k == "count") { if (!match(substr(s, i), /^[0-9]+/)) fail("its count is not a whole number"); v[k] = substr(s, i, RLENGTH); i += RLENGTH }
      else if (k == "ids") {
        expect("["); ws()
        if (ch() == "]") i++
        else while (1) {
          ws(); id = str("an id"); if (id == "") fail("it lists an empty id")
          if (id in got) fail("it names " id " twice")
          got[id] = 1; ids[++nid] = id; ws()
          c = ch(); i++
          if (c == "]") break
          if (c != ",") fail("its ids are not a list of strings")
        }
      }
      else fail("it carries \"" k "\", which a review page never copies")
      ws(); c = ch(); i++
      if (c == "}") break
      if (c != ",") fail("it is not a JSON object")
    }
  } else i++
  ws(); if (i <= n) fail("it carries more after its closing brace")
  if (!("scan_id" in seen) || !("nonce" in seen) || !("count" in seen) || !("ids" in seen)) fail("it lacks one of scan_id, nonce, count and ids")
  print "scan_id\t" v["scan_id"]; print "nonce\t" v["nonce"]; print "count\t" v["count"]
  for (j = 1; j <= nid; j++) print "id\t" ids[j]
}
function ch() { return substr(s, i, 1) }
function ws() { while (i <= n && index(" \t\r\n", substr(s, i, 1))) i++ }
function expect(c) { if (substr(s, i, 1) != c) fail("it is not the JSON a review page copies"); i++ }
function str(what,    out, c) {
  if (ch() != "\"") fail(what " is not a string")
  i++; out = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") { c = substr(s, i + 1, 1); if (c != "\\" && c != "\"" && c != "/") fail(what " holds an escape a review page never writes"); out = out c; i += 2; continue }
    if (c == "\"") { i++; return out }
    if (c ~ /[\001-\037]/) fail(what " holds a control character")
    out = out c; i++
  }
  fail(what " never ends")
}
function fail(m) { print "error\t" m; exit 0 }' "$PAYLOAD" > "$WORK/parsed" || refuse 2 "could not read the payload $PAYLOAD, so nothing was planned."

err="$(awk -F '\t' '$1 == "error" { print substr($0, 7); exit }' "$WORK/parsed")"
[ -z "$err" ] || refuse 2 "the pasted selection is not what a review page copies: $err. Nothing was planned; copy the selection from the page again."
P_SID="$(awk -F '\t' '$1 == "scan_id" { print substr($0, 9) }' "$WORK/parsed")"
P_NONCE="$(awk -F '\t' '$1 == "nonce" { print substr($0, 7) }' "$WORK/parsed")"
P_COUNT="$(awk -F '\t' '$1 == "count" { print $2 }' "$WORK/parsed")"
awk -F '\t' '$1 == "id" { print substr($0, 4) }' "$WORK/parsed" > "$WORK/ids"
N_IDS="$(awk 'END { print NR }' "$WORK/ids")"

# ---------- the checks, in the order the header gives ----------
[ "$P_SID" = "$LAST" ] || refuse 3 "the selection is from scan $P_SID, which is not the last scan ($LAST): a newer scan has replaced the one reviewed. Nothing was planned; review the page for the new scan."
[ "$P_NONCE" = "$NONCE" ] || refuse 4 "the selection's nonce is not the page rendered last's, so it came from an older copy of the review page or was left on the clipboard from an earlier run. Nothing was planned; copy the selection from the page open now."
[ "$P_COUNT" -eq "$N_IDS" ] 2>/dev/null || refuse 5 "the selection says $P_COUNT items but lists $N_IDS, so some were lost between the page and the chat. Nothing was planned; copy the selection again."
[ "$N_IDS" -gt 0 ] || refuse 7 "nothing was chosen on the page, so there is nothing to remove, and nothing was planned."

dcr_review_items "$REC" > "$WORK/items"
awk -F "$S" -v sid="$LAST" '
  FILENAME == ARGV[1] { want[++n] = $0; next }
  { state[$1] = $5 }
  END {
    for (j = 1; j <= n; j++) {
      id = want[j]
      if (!(id in state)) print id ": not in scan " sid
      else if (state[id] != "offerable") print id ": " state[id]
    }
  }' "$WORK/ids" "$WORK/items" > "$WORK/bad"
if [ -s "$WORK/bad" ]; then
  echo "disk-clean review: $(awk 'END { print NR }' "$WORK/bad") of the $N_IDS chosen items cannot be removed now, so nothing was planned:"
  awk '{ print "  " $0 }' "$WORK/bad"
  exit 6
fi

# ---------- the plan ----------
tmp="$PLAN.tmp.$$"
{ printf 'scan_id %s\ncount %s\n' "$LAST" "$N_IDS"; awk '{ print "item " $0 }' "$WORK/ids"; } > "$tmp" \
  || { rm -f "$tmp"; refuse 2 "could not write the plan $PLAN, so nothing was planned."; }
mv -f "$tmp" "$PLAN" || { rm -f "$tmp"; refuse 2 "could not move the plan into place at $PLAN, so nothing was planned."; }

# ---------- what it will remove, for the confirm step ----------
echo "Plan written to $PLAN: $N_IDS item(s) from scan $LAST."
cats="$(dcr_header "$REC" categories 2>/dev/null)" || cats=""
awk -F "$S" -v cats="$cats" -v table="$DCR_TITLES" "$DCU_AWK_LIB$DCR_AWK_TITLES$DCRV_AWK_WORDS"'
  FILENAME == ARGV[1] { want[$0] = 1; next }
  !($1 in want) { next }
  {
    c = $2
    if (!(c in seen)) { seen[c] = 1; order[++nc] = c }
    k = ++count[c]; line[c, k] = $0
    if ($6 ~ /^[0-9]+$/) kib[c] += int($6 / 1024); else unread[c]++
    if ($8 == "partial") partial[c] = 1
  }
  END {
    # The scan order (the Trash first), then any category the header does not name.
    m = split(cats, co, " "); done = 0
    for (j = 1; j <= m; j++) if (co[j] in seen) { out[++done] = co[j]; put[co[j]] = 1 }
    for (j = 1; j <= nc; j++) if (!(order[j] in put)) out[++done] = order[j]
    for (j = 1; j <= done; j++) {
      c = out[j]
      words = count[c] (count[c] == 1 ? " item" : " items") ", " (partial[c] ? "at least " : "") dcu_h(kib[c])
      if (unread[c]) words = words ", plus " unread[c] " whose size was not read"
      print ""
      print dcr_t(c, table) ": " words
      for (k = 1; k <= count[c]; k++) {
        split(line[c, k], f, FS)
        w = dcrv_flags(f[9])
        print "  " dcrv_size(f[6], f[8]) "  " f[4] (w == "" ? "" : "  (" w ")")
      }
    }
  }' "$WORK/ids" "$WORK/items"
exit 0
