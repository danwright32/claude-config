#!/usr/bin/env bash
# Tests for the disk-clean skill's own text (claude-config#1808): the flow Claude follows from the
# scan to the verified result, written against the scripts it calls.
#
# A skill is a sequence of commands and of what to say about each outcome. The outcome is the exit
# code (L184), so every code each script can return must have a sentence in the step that runs it,
# or the first time a script refuses, Claude has to guess what to tell Dan. The codes are DERIVED
# from the scripts' source here, never listed by hand, so a script that gains a code fails this
# suite until the skill says what it means (L96). And a code the skill names that the script cannot
# return fails too: a sentence about an outcome that never happens is read as one that might.
#
# The commands Claude runs that can be run safely are RUN as written (L442), through the disk-clean
# harness, so HOME is a throwaway one and the clipboard is a stub: the review page command, then the
# checker command on a selection copied from that page. disk-remove.sh is never run here; its plan
# path is checked to be the one the checker writes.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$DIR/../../hooks" && pwd)"
SKILL="$DIR/SKILL.md"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
eq() { [ "$1" = "$2" ] && echo ok || echo "expected '$2', got '$1'"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-skill.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-disk-clean-skill: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

check "the skill is there to read" "$([ -f "$SKILL" ] && echo ok || echo "no $SKILL")"
[ -f "$SKILL" ] || finish

# ================================================================================================
# 1. The frontmatter
# ================================================================================================
fm() { awk -v key="$1" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && index($0, key ":") == 1 { v = substr($0, length(key) + 2); sub(/^[ \t]+/, "", v); print v; exit }' "$SKILL"; }
check "SKILL.md names the skill" "$(eq "$(fm name)" disk-clean)"
check "its description is there" "$([ -n "$(fm description)" ] && echo ok || echo "no description")"
check "its description no longer says it is not ready" "$(grep -qi 'not ready' <<< "$(fm description)" && echo "still says not ready" || echo ok)"
# Removing things is started by Dan typing /disk-clean, never by Claude on its own (L9): the low
# space warning and disk-full point him at it, and he starts it.
check "only Dan starts it" "$(eq "$(fm disable-model-invocation)" true)"

# ================================================================================================
# 2. The exit codes each script can return, derived from its source
# ================================================================================================
# Prints "<line>\t<code>" for every `exit N` and `refuse N` with a literal number in a script's shell
# code. Comments, quoted text (so every awk program and every message) and here documents are
# skipped, which is what keeps an awk `exit 1` or a message saying "(exit 2)" from counting.
cat > "$TMP/codes.awk" <<'AWK'
function emit(c) { buf = buf c }
{
  line = $0; n = length(line)
  if (hd != "") {
    t = line; if (hdtab) sub(/^\t+/, "", t)
    if (t == hd) hd = ""
    out[NR] = ""; next
  }
  pendhd = ""
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1); m = mode[sp]
    if (m == "S") { emit(" "); if (c == "'") sp--; continue }
    if (m == "A") { emit(" "); if (c == "\\") { i++; emit(" ") } else if (c == "'") sp--; continue }
    if (m == "D") {
      if (c == "\\") { i++; emit("  "); continue }
      if (c == "\"") { sp--; emit(" "); continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") { mode[++sp] = "C"; depth[sp] = 1; i++; emit("$("); continue }
      emit(" "); continue
    }
    if (c == "\\") { emit(substr(line, i, 2)); i++; continue }
    if (c == "#") { p = (i == 1) ? " " : substr(line, i - 1, 1); if (p ~ /[ \t;&|(]/) break }
    if (c == "'") { mode[++sp] = (i > 1 && substr(line, i - 1, 1) == "$") ? "A" : "S"; emit(" "); continue }
    if (c == "\"") { mode[++sp] = "D"; emit(" "); continue }
    if (c == "$" && substr(line, i + 1, 1) == "(") { mode[++sp] = "C"; depth[sp] = 1; i++; emit("$("); continue }
    if (m == "C" && c == "(") { depth[sp]++; emit(c); continue }
    if (m == "C" && c == ")") { if (--depth[sp] == 0) sp--; emit(c); continue }
    if (c == "<" && substr(line, i, 2) == "<<" && substr(line, i, 3) != "<<<") {
      rest = substr(line, i + 2); tab = (substr(rest, 1, 1) == "-"); if (tab) rest = substr(rest, 2)
      if (match(rest, /^[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) { w = substr(rest, RSTART, RLENGTH); gsub(/[ \t'"]/, "", w); pendhd = w; pendtab = tab }
    }
    emit(c)
  }
  out[NR] = buf; buf = ""
  if (pendhd != "" && sp == 0) { hd = pendhd; hdtab = pendtab }
}
END {
  for (k = 1; k <= NR; k++) {
    s = out[k]
    while (match(s, /(^|[^A-Za-z0-9_.-])(exit|refuse)[ \t]+[0-9]+/)) {
      hit = substr(s, RSTART, RLENGTH); sub(/^.*(exit|refuse)[ \t]+/, "", hit)
      print k "\t" hit
      s = substr(s, RSTART + RLENGTH)
    }
  }
}
AWK

# The files a script sources, by name, looked up beside it, in the skill and in hooks/lib.
sourced() { # <script>
  local f="$1" name d
  grep -E '^[[:space:]]*\.[[:space:]]+"[^"]*\.sh"' "$f" | sed -E 's/^[[:space:]]*\.[[:space:]]+"([^"]*)".*/\1/' | while IFS= read -r name; do
    name="${name##*/}"
    for d in "$(dirname "$f")" "$DIR" "$HOOKS/lib"; do
      [ -f "$d/$name" ] && { printf '%s\n' "$d/$name"; break; }
    done
  done
}
# Every code a script can exit with: its own and those of everything it sources, sorted, unique.
codes_of() { # <script>
  local seen=" " todo="$1" f
  while [ -n "$todo" ]; do
    f="${todo%%$'\n'*}"; [ "$f" = "$todo" ] && todo="" || todo="${todo#*$'\n'}"
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    awk -f "$TMP/codes.awk" "$f" | cut -f2
    todo="$todo${todo:+$'\n'}$(sourced "$f")"
    todo="${todo%$'\n'}"
  done | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}
# The ## section of a skill whose code blocks run <script>, and the codes it names as **Exit N**.
section_running() { # <skill> <script basename>
  awk -v s="$2" '
    /^## / { sec++; next }
    /^```/ { inside = !inside; next }
    inside && $0 ~ ("^bash ~/\\.claude/(skills/disk-clean|hooks/lib)/" s "( |$)") { print sec }
  ' "$1" | sort -u
}
named_codes() { # <skill> <section number>
  awk -v want="$2" '/^## / { sec++; next } sec == want' "$1" \
    | grep -oE '\*\*Exit [0-9]+\*\*' | grep -oE '[0-9]+' | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}
# Says "ok", or which codes the section leaves out and which it names that the script cannot return.
coverage() { # <skill> <script path>
  local skill="$1" script="$2" base secs derived named missing extra c
  base="$(basename "$script")"
  secs="$(section_running "$skill" "$base")"
  [ -n "$secs" ] || { echo "no section of the skill runs $base in a command block"; return; }
  [ "$(printf '%s\n' "$secs" | wc -l | tr -d ' ')" -eq 1 ] || { echo "more than one section runs $base: $(echo $secs)"; return; }
  derived="$(codes_of "$script")"
  [ -n "$derived" ] || { echo "no exit code could be derived from $base"; return; }
  named="$(named_codes "$skill" "$secs")"
  missing="" extra=""
  for c in $derived; do case " $named " in *" $c "*) ;; *) missing="$missing $c" ;; esac; done
  for c in $named; do case " $derived " in *" $c "*) ;; *) extra="$extra $c" ;; esac; done
  if [ -z "$missing$extra" ]; then echo ok
  else echo "$base can exit with: $derived; the skill names: ${named:-none};${missing:+ never says what to do on:$missing;}${extra:+ names codes it cannot return:$extra}"; fi
}

# --- the controls first: the derivation is only real once seen to fail (L1) ---
F="$TMP/fixture"; mkdir -p "$F"
cat > "$F/lib-fixture.sh" <<'SH'
helper() { echo "from the library"; exit 11; }
SH
cat > "$F/tool.sh" <<'SH'
#!/usr/bin/env bash
HERE="${BASH_SOURCE[0]%/*}"
. "$HERE/lib-fixture.sh" || exit 2
refuse() { echo "$2"; exit "$1"; }
# exit 6 is only a comment
awk 'END { if (!done) exit 1 }' /dev/null
msg="it failed (exit 4)"
cat <<EOF
exit 3 inside a here document
EOF
[ -n "${1:-}" ] || refuse 8 "no argument"
case "$1" in --x) exit 9 ;; esac
exit 0
SH
check "the derivation finds every code a fixture can exit with, its library's included" "$(eq "$(codes_of "$F/tool.sh")" "0 2 8 9 11")"
cat > "$F/SKILL.md" <<'MD'
## Run it

```bash
bash ~/.claude/skills/disk-clean/tool.sh --x
```

- **Exit 0**: fine.
- **Exit 2**: its library is missing.
- **Exit 8**: no argument.
- **Exit 11**: the library refused.
- **Exit 12**: a code it cannot return.
MD
cov="$(coverage "$F/SKILL.md" "$F/tool.sh")"
check "a skill that never names a code the script returns fails" "$(grep -q 'never says what to do on: 9;' <<< "$cov" && echo ok || echo "said: $cov")"
check "a skill that names a code the script cannot return fails" "$(grep -q 'names codes it cannot return: 12' <<< "$cov" && echo ok || echo "said: $cov")"
sed -i.bak -e 's/^- \*\*Exit 12\*\*.*/- **Exit 9**: the x option./' "$F/SKILL.md"
check "and one naming exactly the script's codes passes" "$(eq "$(coverage "$F/SKILL.md" "$F/tool.sh")" ok)"

# --- the four scripts the skill calls ---
for s in "$DIR/scan.sh" "$DIR/review-page.sh" "$DIR/review-check.sh" "$HOOKS/lib/disk-remove.sh"; do
  check "the skill says what to tell Dan for every exit code of $(basename "$s"), and only those" "$(coverage "$SKILL" "$s")"
done
# A sanity anchor on the derivation against what each script's own header documents today, so a
# derivation gone blind (every set empty or 0 alone) cannot pass by agreeing with an empty skill.
check "scan.sh's derived codes include its lock refusal" "$(grep -qw 75 <<< "$(codes_of "$DIR/scan.sh")" && echo ok || echo "got: $(codes_of "$DIR/scan.sh")")"
check "review-check.sh's derived codes include each refusal" "$(eq "$(codes_of "$DIR/review-check.sh")" "0 2 3 4 5 6 7")"

# ================================================================================================
# 3. The order: scan, review page, check, remove, and the Full Disk Access result first
# ================================================================================================
s_scan="$(section_running "$SKILL" scan.sh)"; s_page="$(section_running "$SKILL" review-page.sh)"
s_check="$(section_running "$SKILL" review-check.sh)"; s_remove="$(section_running "$SKILL" disk-remove.sh)"
check "the steps run in order: scan, review page, check, remove" \
  "$([ -n "$s_scan" ] && [ -n "$s_page" ] && [ -n "$s_check" ] && [ -n "$s_remove" ] && [ "$s_scan" -lt "$s_page" ] && [ "$s_page" -lt "$s_check" ] && [ "$s_check" -lt "$s_remove" ] && echo ok || echo "sections: scan $s_scan, page $s_page, check $s_check, remove $s_remove")"
sec() { awk -v want="$1" '/^## / { sec++; next } sec == want' "$SKILL"; }
code_of() { awk '/^```/ { inside = !inside; next } inside'; }
scan_sec="$(sec "$s_scan")"
check "the scan command is the installed script with no options" \
  "$(grep -qxF 'bash ~/.claude/skills/disk-clean/scan.sh' <<< "$(code_of <<< "$scan_sec")" && echo ok || echo "no block line is exactly: bash ~/.claude/skills/disk-clean/scan.sh")"
fda_line="$(grep -n -m 1 'Full Disk Access' <<< "$scan_sec" | cut -d: -f1)"
total_line="$(grep -n -m 1 -i 'total' <<< "$scan_sec" | cut -d: -f1)"
check "the scan step reports Full Disk Access before any total" \
  "$([ -n "$fda_line" ] && [ -n "$total_line" ] && [ "$fda_line" -lt "$total_line" ] && echo ok || echo "Full Disk Access at line '${fda_line}', first total at '${total_line}'")"
check "and states an unmeasured kind as unmeasured with its reason, never as zero" \
  "$(grep -qi 'unmeasured' <<< "$scan_sec" && grep -qi 'never as zero' <<< "$scan_sec" && grep -qi 'reason' <<< "$scan_sec" && echo ok || echo "the scan step does not say so")"

# ================================================================================================
# 4. The review page: rendered with the clipboard cleared, opened in Chrome by name
# ================================================================================================
page_sec="$(sec "$s_page")"; page_code="$(code_of <<< "$page_sec")"
page_line="$(grep -m 1 -E '^bash ~/\.claude/skills/disk-clean/review-page\.sh ' <<< "$page_code")"
check "the review page is rendered with --out and --clear-clipboard" \
  "$(grep -qF -- '--out <folder>' <<< "$page_line" && grep -qF -- '--clear-clipboard' <<< "$page_line" && echo ok || echo "the line is: $page_line")"
PAGE_NAME="$(awk -F= '/^DCRV_PAGE=/ { print $2; exit }' "$DIR/review-lib.sh")"
check "it is opened in Chrome by name, at the file the script writes" \
  "$(grep -qxF "open -a \"Google Chrome\" <folder>/$PAGE_NAME" <<< "$page_code" && echo ok || echo "no block line is exactly: open -a \"Google Chrome\" <folder>/$PAGE_NAME")"
check "and the step tells Dan focus will move before it opens" \
  "$(grep -qi 'focus' <<< "$page_sec" && echo ok || echo "the step does not mention focus")"
bare="$(code_of < "$SKILL" | awk '/(^|[;&| ])open / && index($0, "open -a \"Google Chrome\"") == 0')"
check "no bare open, which goes to the Island browser" "$([ -z "$bare" ] && echo ok || echo "found: $bare")"
check "the hour disk-remove allows from the scan is said before Dan picks" \
  "$(grep -qi 'within an hour' <<< "$page_sec" && echo ok || echo "the review page step does not say so")"

# ================================================================================================
# 5. The check and the one confirm picker
# ================================================================================================
check_sec="$(sec "$s_check")"; check_code="$(code_of <<< "$check_sec")"
check_line="$(grep -m 1 -E '^bash ~/\.claude/skills/disk-clean/review-check\.sh ' <<< "$check_code")"
check "the checker is given the page's folder, the pasted selection and a plan path" \
  "$(grep -qF -- '--out <folder>' <<< "$check_line" && grep -qF -- '--payload <folder>/selection.json' <<< "$check_line" && grep -qF -- '--plan <folder>/plan.txt' <<< "$check_line" && echo ok || echo "the line is: $check_line")"
check "the pasted selection is written with the Write tool, never through a shell" \
  "$(grep -qF 'Write tool' <<< "$check_sec" && echo ok || echo "the step does not say how the selection reaches the file")"
check "there is exactly one AskUserQuestion confirm picker" \
  "$(eq "$(grep -c 'AskUserQuestion' "$SKILL")" 1)"
check "and it sits in the step after the check" "$(grep -q 'AskUserQuestion' <<< "$check_sec" && echo ok || echo "not in the check step")"
check "the Trash and Dan's own files are named one by one in it" \
  "$(grep -qF 'Trash' <<< "$check_sec" && grep -qF 'Large personal files' <<< "$check_sec" && grep -qF 'Tools not used in 180 days' <<< "$check_sec" && grep -qi 'by path' <<< "$check_sec" && echo ok || echo "the step does not name them")"

# ================================================================================================
# 6. The removal, its verified result by df, and nothing removed by hand
# ================================================================================================
remove_sec="$(awk -v a="$s_remove" '/^## / { sec++; next } sec >= a' "$SKILL")"; remove_code="$(code_of <<< "$remove_sec")"
check "disk-remove runs the plan the checker wrote" \
  "$(grep -qxF 'bash ~/.claude/hooks/lib/disk-remove.sh --plan <folder>/plan.txt' <<< "$remove_code" && echo ok || echo "no block line is exactly: bash ~/.claude/hooks/lib/disk-remove.sh --plan <folder>/plan.txt")"
check "free space is read by df -m before and after" \
  "$(grep -qxF 'df -m /System/Volumes/Data' <<< "$remove_code" && grep -qi 'before' <<< "$remove_sec" && grep -qi 'after' <<< "$remove_sec" && echo ok || echo "no df -m reading around the removal")"
check "and the result is never du alone" "$(grep -qi 'never .*du' <<< "$remove_sec" && echo ok || echo "the step does not say so")"
mine="$(code_of < "$SKILL" | grep -vE '^sudo ')"
check "no command Claude runs removes anything by hand" \
  "$(awk '/(^|[;&|][[:space:]]*)(rm|trash|mv|\/usr\/bin\/trash) /' <<< "$mine" | awk 'END { exit NR > 0 }' && echo ok || echo "found: $(awk '/(^|[;&|][[:space:]]*)(rm|trash|mv) /' <<< "$mine")")"

# Every sudo command is Dan's: the paragraph introducing its block says so, and Claude never runs one.
unhanded="$(awk '
  /^```/ { if (!inside) before = para; inside = !inside; next }
  inside { if ($0 ~ /^sudo /) { if (before !~ /Dan/) print $0 }; next }
  /^[[:space:]]*$/ { blank = 1; next }
  { if (blank) para = $0; else para = para " " $0; blank = 0 }
' "$SKILL")"
check "every sudo command is introduced as Dan's to run" "$([ -z "$unhanded" ] && echo ok || echo "not handed to Dan: $unhanded")"
check "and the scan saw the one the skill hands over (L159)" "$(eq "$(code_of < "$SKILL" | grep -c '^sudo ')" 1)"
check "and the skill says it never runs sudo itself" "$(grep -qi 'never runs .*sudo\|never run.*sudo' "$SKILL" && echo ok || echo "it does not say so")"

# ================================================================================================
# 7. The review page and checker commands, run as written (L442)
# ================================================================================================
. "$HOOKS/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
. "$HOOKS/lib/disk-clean-record.sh" || { check "the record library is there to source" "could not source it"; finish; }
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }
trap 'rm -rf "$TMP"; dc_cleanup' EXIT
H="$DC_HOME"; S=$'\037'; SID="scan-1761600000-4242"
FOLDER="$H/scratch/disk-clean"
mkdir -p "$H/.claude/state/disk-clean" "$FOLDER"
dc_stub pbcopy 'cat > "$HOME/clipboard.txt"; exit 0'
printf '%s\n' "trash-1${S}trash${S}delete${S}$H/.Trash/old.zip${S}2097152${S}offerable${S}1:2${S}measured${S}${S}" \
  "caches-1${S}caches${S}delete${S}$H/Library/Caches/com.big${S}3221225472${S}offerable${S}1:3${S}measured${S}${S}" > "$H/items.txt"
printf 'categories%strash caches\n' "$S" > "$H/notes.txt"
dcr_write "$H/.claude/state/disk-clean/last-scan.json" "$SID" 1761600000 "$H/items.txt" "$H/notes.txt" || check "the fixture record is written" "dcr_write failed"
as_written() { local l="$1"; l="${l//\~\/.claude\/skills\/disk-clean\//$DIR/}"; l="${l//\~\/.claude\/hooks\//$HOOKS/}"; printf '%s' "${l//<folder>/$FOLDER}"; }

out="$(dc_run bash -c "$(as_written "$page_line")" 2>&1)"; rc=$?
check "the review page command, run as written, writes the page" "$([ "$rc" -eq 0 ] && [ -f "$FOLDER/$PAGE_NAME" ] && echo ok || echo "exit $rc, said: $out")"
check "and clears the clipboard first" "$([ -f "$H/clipboard.txt" ] && [ ! -s "$H/clipboard.txt" ] && echo ok || echo "the clipboard stub was not called empty")"
NONCE="$(awk '$1 == "nonce" { print $2 }' "$FOLDER/disk-clean-review.nonce" 2>/dev/null)"
printf '{"scan_id":"%s","nonce":"%s","count":2,"ids":["trash-1","caches-1"]}\n' "$SID" "$NONCE" > "$FOLDER/selection.json"
out="$(dc_run bash -c "$(as_written "$check_line")" 2>&1)"; rc=$?
check "the checker command, run as written on a selection from that page, writes the plan" \
  "$([ "$rc" -eq 0 ] && [ -f "$FOLDER/plan.txt" ] && echo ok || echo "exit $rc, said: $out")"
check "and the plan names the scan and both items" \
  "$(eq "$(tr '\n' ' ' 2>/dev/null < "$FOLDER/plan.txt")" "scan_id $SID count 2 item trash-1 item caches-1 ")"
check "and prints each kind with its size, for the picker to name" \
  "$(grep -qF 'Trash: 1 item' <<< "$out" && grep -qF 'App caches: 1 item' <<< "$out" && echo ok || echo "said: $out")"
check "nothing outside the throwaway directory was written" "$(eq "$(dc_refusals)" "")"

finish
