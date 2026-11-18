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
#   bash ~/.claude/skills/disk-clean/review-check.sh --entries <kind> --plan <plan file>
#
#              lists, by path, every entry of <kind> the plan takes, for when Dan asks to see the
#              entries of a kind chosen whole. It reads the plan and writes nothing; it refuses (2) a
#              plan that is not there, is for another scan, or takes nothing of <kind>.
#
# A KIND CHOSEN WHOLE (#3232). Ticking the Trash's one row copies one id, all:<kind>:<count>:<digest>
# (review-lib.sh, dcrv_whole_token), never an id per entry: 5,979 entries were about 70 KB pasted into
# the chat. It is taken only for a kind on DCRV_WHOLE and only when it is exactly the summary worked
# out again from the record now, whose digest covers the scan id and every entry's id, path and device
# and inode; it is then planned as those entries, where it stood, and the confirm step says the kind in
# one line, its count and total, rather than an entry a line.
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
#      (2 again: a whole kind not written as the page writes one, for a kind the page does not draw
#      as one row, named twice, or beside an entry of its own kind listed alone)
#   8  a whole kind's count or entries are not what the scan offers now: the scan changed after the
#      page was drawn (an entry removed since), the page was drawn for another scan, or it was edited
#   6  an id is not offerable in the scan now: never in it, or kept, unmeasured or already removed.
#      Every such id is named with the reason.
#   0  the plan is written, and what it will remove is printed: each category's count and total,
#      then every item by path, with any warning its flags carry, for the confirm step to name; a
#      kind chosen whole is said in one line, with the command that lists its entries.
#
# Commands: awk cat mktemp mv rm, the libraries it sources (sort and shasum through review-lib.sh's
# summary), and the builtins. bash 3.2 safe.
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

OUT="" PAYLOAD="" PLAN="" ENTRIES=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out|--payload|--plan|--entries)
      [ "$#" -ge 2 ] || refuse 2 "$1 needs a value, so nothing was planned."
      case "$1" in --out) OUT="$2" ;; --payload) PAYLOAD="$2" ;; --plan) PLAN="$2" ;; --entries) ENTRIES="$2" ;; esac
      shift 2 ;;
    -h|--help) awk 'NR > 1 && /^set -uo/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) refuse 2 "it does not know '$1' (it takes --out, --payload and --plan, or --entries and --plan), so nothing was planned." ;;
  esac
done
if [ -z "$ENTRIES" ]; then
  [ -n "$OUT" ] || refuse 2 "--out, the folder the review page was rendered into, is missing, so nothing was planned."
  [ -n "$PAYLOAD" ] || refuse 2 "--payload, the file holding what was pasted, is missing, so nothing was planned."
  [ -n "$PLAN" ] || refuse 2 "--plan, where to write the plan, is missing, so nothing was planned."
else
  case "$ENTRIES" in *[!a-z0-9-]*) refuse 2 "--entries takes a kind's name, such as trash, and '$ENTRIES' is not one, so nothing was listed." ;; esac
  [ -n "$PLAN" ] || refuse 2 "--plan, the plan to list the entries of, is missing, so nothing was listed."
fi

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-review.XXXXXXXX")" || refuse 2 "could not make a working folder under ${TMPDIR:-/tmp}, so nothing was planned."
trap 'rm -rf "$WORK"' EXIT
dcr_review_items "$REC" > "$WORK/items"
cats="$(dcr_header "$REC" categories 2>/dev/null)" || cats=""
commas() { awk -v n="$1" "$DCU_AWK_LIB"'BEGIN { printf "%s", dcu_commas(n) }'; }

# Each chosen item by path, with its size and the warnings its flags carry, from <want ids> (one id a
# line) over the record's items (#1807). <whole> names kinds chosen whole (#3232): each is said in
# one line, its count and total, and its entries are left to --entries <kind>.
confirm_lines() { # <want ids> <whole kinds>
  awk -F "$S" -v cats="$cats" -v table="$DCR_TITLES" -v whole=" $2 " -v me="${BASH_SOURCE[0]}" -v plan="$PLAN" "$DCU_AWK_LIB$DCU_AWK_TALLY$DCU_AWK_WORDS$DCR_AWK_TITLES$DCRV_AWK_WORDS"'
    FILENAME == ARGV[1] { want[$0] = 1; next }
    !($1 in want) { next }
    {
      c = $2
      if (!(c in seen)) { seen[c] = 1; order[++nc] = c }
      k = ++count[c]; line[c, k] = $0
      # Every chosen item is offerable (checked before), so each is totalled by the shared tally
      # (hooks/lib/disk-clean-units.sh, #1866): never 0 for a size nobody read (L90).
      dcu_tally(c, $6, $8)
      nf = split($9, fl, ",")
      for (j = 1; j <= nf; j++) if (fl[j] != "" && !((c, fl[j]) in mk)) { mk[c, fl[j]] = 1; marks[c] = marks[c] (marks[c] == "" ? "" : ",") fl[j] }
    }
    END {
      # The scan order (the Trash first), then any category the header does not name.
      m = split(cats, co, " "); done = 0
      for (j = 1; j <= m; j++) if (co[j] in seen) { out[++done] = co[j]; put[co[j]] = 1 }
      for (j = 1; j <= nc; j++) if (!(order[j] in put)) out[++done] = order[j]
      for (j = 1; j <= done; j++) {
        c = out[j]
        # Worded by the tally (#2013), as the bottom bar of the review page is, so both say the same.
        words = dcu_commas(count[c]) (count[c] == 1 ? " item" : " items") ", " dcu_tally_words(c)
        print ""
        print dcr_t(c, table) ": " words
        if (index(whole, " " c " ")) {
          w = dcrv_flags(marks[c])
          print "  Every entry the scan listed that can go" (w == "" ? "" : ", some marked: " w) ". To see each by path: bash " me " --entries " c " --plan " plan
          continue
        }
        for (k = 1; k <= count[c]; k++) {
          split(line[c, k], f, FS)
          w = dcrv_flags(f[9])
          print "  " dcrv_size(f[6], f[8]) "  " f[4] (w == "" ? "" : "  (" w ")")
        }
      }
    }' "$1" "$WORK/items"
}

# ---------- --entries <kind>: what a plan takes of one kind, by path, writing nothing (#3232) ----------
if [ -n "$ENTRIES" ]; then
  [ -f "$PLAN" ] && [ -r "$PLAN" ] || refuse 2 "the plan $PLAN is not there to read, so nothing was listed."
  psid="$(awk '$1 == "scan_id" { print $2; exit }' "$PLAN")"
  [ "$psid" = "$LAST" ] || refuse 2 "the plan $PLAN is for scan ${psid:-none}, which is not the last scan ($LAST), so nothing was listed."
  awk '$1 == "item" { print substr($0, 6) }' "$PLAN" > "$WORK/want"
  awk -F "$S" -v k="$ENTRIES" 'FILENAME == ARGV[1] { want[$0] = 1; next } $2 == k && ($1 in want) { print $1 }' "$WORK/want" "$WORK/items" > "$WORK/kind"
  [ -s "$WORK/kind" ] || refuse 2 "the plan $PLAN takes nothing of $ENTRIES, so nothing was listed."
  confirm_lines "$WORK/kind" ""
  exit 0
fi

NONCE="$(dcrv_read_nonce "$OUT")" || refuse 2 "no review page was rendered in $OUT (it holds no $DCRV_NONCE), so there is nothing the selection could have come from, and nothing was planned."
[ -f "$PAYLOAD" ] && [ -r "$PAYLOAD" ] || refuse 2 "the payload file $PAYLOAD is not there to read, so nothing was planned."

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

# ---------- a kind chosen whole: all:<kind>:<count>:<digest> (#3232) ----------
# Taken only for a kind the page draws as one row, and only when it is exactly the summary
# review-lib.sh works out from the record now: same scan, same count, same entries by id, path and
# device and inode. It then stands for those entries and no others, so an entry put in the Trash
# after the scan, which the record does not hold, is never reached.
awk 'index($0, "all:") == 1' "$WORK/ids" > "$WORK/wholes"
WHOLE=""
: > "$WORK/expand"
while IFS= read -r tok; do
  rest="${tok#all:}"; k="${rest%%:*}"; rest="${rest#*:}"; cnt="${rest%%:*}"; dg="${rest#*:}"
  case "$tok" in all:*:*:*) ;; *) k="" ;; esac
  case "$k" in ''|*[!a-z0-9-]*) k="" ;; esac
  case "$cnt" in ''|*[!0-9]*) k="" ;; esac
  case "$dg" in *[!0-9a-f]*) k="" ;; esac
  [ "${#dg}" -eq 32 ] || k=""
  [ -n "$k" ] || refuse 2 "the pasted selection is not what a review page copies: $tok is not a whole kind written as the page writes one. Nothing was planned; copy the selection from the page again."
  case " $DCRV_WHOLE " in
    *" $k "*) ;;
    *) only=""; for w in $DCRV_WHOLE; do only="${only:+$only and }the $(dcr_title "$w")"; done
       refuse 2 "the pasted selection chooses every entry of $(dcr_title "$k") at once, but the review page draws only ${only:-nothing} as one row, so it never copies that. Nothing was planned; copy the selection from the page again." ;;
  esac
  case " $WHOLE " in *" $k "*) refuse 2 "the pasted selection chooses every entry of the $(dcr_title "$k") twice, which a review page never copies. Nothing was planned; copy the selection from the page again." ;; esac
  WHOLE="${WHOLE:+$WHOLE }$k"
  want="$(dcrv_whole_token "$WORK/items" "$LAST" "$k")" || want=""
  # An empty summary means the scan offers none of the kind now, unless it does, when the summary
  # itself could not be worked out (shasum or sort failed), which is said as that.
  if [ -z "$want" ] && [ -n "$(dcrv_whole_entries "$WORK/items" "$k")" ]; then
    refuse 2 "the summary of the $(dcr_title "$k") could not be worked out from the scan record (sort or shasum failed), so the selection cannot be checked, and nothing was planned."
  fi
  have="${want#all:*:}"; have="${have%%:*}"; [ -n "$want" ] || have=0
  title="$(dcr_title "$k")"
  [ "$cnt" = "$have" ] || refuse 8 "the selection chooses all $(commas "$cnt") $title entries, but the scan offers $(commas "$have") now, so the scan changed after the page was drawn, or the selection was edited. Nothing was planned; open the review page again, which draws what the scan offers now, and copy the selection from it."
  [ "$tok" = "$want" ] || refuse 8 "the selection chooses all $(commas "$cnt") $title entries the page drew, but they are not the ones the scan offers now: the page was drawn for another scan, or the selection was edited. Nothing was planned; open the review page again and copy the selection from it."
  dcrv_whole_entries "$WORK/items" "$k" | awk -F "$S" -v k="$k" '{ print k "\t" $1 }' >> "$WORK/expand"
done < "$WORK/wholes"
# An entry listed on its own beside the summary of its kind is never what a page copies.
if [ -n "$WHOLE" ]; then
  awk -F "$S" -v whole=" $WHOLE " 'FILENAME == ARGV[1] { want[$0] = 1; next } ($1 in want) && index(whole, " " $2 " ") { print $1 }' "$WORK/ids" "$WORK/items" > "$WORK/both"
  [ ! -s "$WORK/both" ] || refuse 2 "the pasted selection chooses every entry of the $(dcr_title "${WHOLE%% *}") and also lists $(awk 'NR > 1 { printf ", " } { printf "%s", $0 }' "$WORK/both") on its own, which a review page never copies. Nothing was planned; copy the selection from the page again."
fi
# The plan's ids: each summary replaced, where it stood, by the entries it stands for.
awk -F '\t' 'FILENAME == ARGV[1] { e[$1] = e[$1] (e[$1] == "" ? "" : "\n") $2; next }
  index($0, "all:") == 1 { split($0, p, ":"); print e[p[2]]; next }
  { print }' "$WORK/expand" "$WORK/ids" > "$WORK/plan-ids"
N_PLAN="$(awk 'END { print NR }' "$WORK/plan-ids")"

awk -F "$S" -v sid="$LAST" '
  FILENAME == ARGV[1] { want[++n] = $0; next }
  { state[$1] = $5 }
  END {
    for (j = 1; j <= n; j++) {
      id = want[j]
      if (!(id in state)) print id ": not in scan " sid
      else if (state[id] != "offerable") print id ": " state[id]
    }
  }' "$WORK/plan-ids" "$WORK/items" > "$WORK/bad"
if [ -s "$WORK/bad" ]; then
  echo "disk-clean review: $(awk 'END { print NR }' "$WORK/bad") of the $(commas "$N_PLAN") chosen items cannot be removed now, so nothing was planned:"
  awk '{ print "  " $0 }' "$WORK/bad"
  exit 6
fi

# ---------- the plan ----------
tmp="$PLAN.tmp.$$"
{ printf 'scan_id %s\ncount %s\n' "$LAST" "$N_PLAN"; awk '{ print "item " $0 }' "$WORK/plan-ids"; } > "$tmp" \
  || { rm -f "$tmp"; refuse 2 "could not write the plan $PLAN, so nothing was planned."; }
mv -f "$tmp" "$PLAN" || { rm -f "$tmp"; refuse 2 "could not move the plan into place at $PLAN, so nothing was planned."; }

# ---------- what it will remove, for the confirm step ----------
echo "Plan written to $PLAN: $(commas "$N_PLAN") item(s) from scan $LAST."
confirm_lines "$WORK/plan-ids" "$WHOLE"
exit 0
