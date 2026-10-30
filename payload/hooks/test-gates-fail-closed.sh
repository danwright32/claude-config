#!/usr/bin/env bash
# The class guard for claude-config#1900: a gate allows nothing it could not read.
#
# Two ways a gate allowed what it could not read, each found in one hook and then swept:
#
#   1. A library sourced with `|| exit 0`. With the file missing, or cut short, the gate exited 0 on
#      every call, which looks exactly like a call with nothing to refuse (L10, L1033). Every
#      PreToolUse hook that can refuse is read here, from the settings that register it, and a
#      source of a library under lib/ followed by a bare `exit 0` or `return 0` fails. A library
#      that sources another must say when that one did not load, or it reports itself loaded
#      with half its functions missing. Each gate is then run with each library it sources taken
#      away, and must refuse the command it judges, naming the file, and pass any other.
#
#   2. A python3 reader taking its stdin in text mode. Under a UTF-8 locale a byte that is not UTF-8
#      raises there, where jq reads it as U+FFFD, so a payload jq reads was unreadable to the python3
#      half of the same gate. Every hook and library here reads stdin through its buffer, decoded
#      with errors="replace", and this fails on the next one that does not.
#
# The gates the second half of 1 runs are a table, since each judges a different command. Every
# gate the first half finds must be in it, so a gate added later is not exempt by being unlisted
# (L96).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/settings-file.sh"
# hook_notice_verdict, for the notices below.
. "$DIR/lib/hook-notice.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gfc.XXXXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

if [ -z "$SETTINGS" ] || [ ! -f "$SETTINGS" ]; then
  echo "test-gates-fail-closed: no settings file beside $DIR names which hooks are registered, so no gate could be enumerated." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs settings.hooks.json or settings.json one level above the hooks"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

# ---------------------------------------------------------------------------
echo "every gate refuses when a library it sources cannot be loaded (claude-config#1900)"

# The PreToolUse hooks that can refuse: registered there, and holding an exit 2 somewhere.
python3 - "$SETTINGS" > "$WORK/pre" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
seen = set()
for g in d.get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        m = re.search(r"hooks/([A-Za-z0-9_.-]+\.sh)", h.get("command", ""))
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            print(m.group(1))
PY
GATES=()
while IFS= read -r g; do
  [ -f "$DIR/$g" ] && grep -q 'exit 2' "$DIR/$g" && GATES+=("$g")
done < "$WORK/pre"
[ "${#GATES[@]}" -ge 20 ] && ok || bad "only ${#GATES[@]} refusing PreToolUse gates were found in $SETTINGS, so the enumeration is reading the wrong thing"

# A source line whose failure branch is a bare exit 0 or return 0, on the line itself or on the
# continuation line after a backslash.
SRC_RE='^[[:space:]]*(\{[[:space:]]*)?(\.|source)[[:space:]]+"[^"]*lib/[^"]+\.sh"'
ALLOW_RE='\|\|[[:space:]]*(exit|return)[[:space:]]+0([^0-9]|$)'
# The patterns travel in the environment: awk -v reads backslash escapes and would turn \| into |.
allowing_sources(){ # allowing_sources <file> -> file:line of each library source that allows on failure
  SRC="$SRC_RE" ALLOW="$ALLOW_RE" awk -v f="$1" '
    BEGIN { src = ENVIRON["SRC"]; allow = ENVIRON["ALLOW"] }
    prev != "" { if ($0 ~ "^[[:space:]]*" allow) print f ":" prevn ": " prev; prev = "" }
    $0 ~ src {
      if ($0 ~ allow) print f ":" NR ": " $0
      else if ($0 ~ /\\$/) { prev = $0; prevn = NR }
    }' "$1"
}
found=""
for g in "${GATES[@]}"; do found="$found$(allowing_sources "$DIR/$g")"; done
if [ -z "$found" ]; then ok; else bad "a gate allows every call when a library it sources cannot be loaded:
$found"; fi

# A library a gate sources, sourcing another with nothing after it, carries on with that one's
# functions missing, and the gate that sourced it reads it as loaded.
bare=""
for l in $(for g in "${GATES[@]}"; do grep -E "$SRC_RE" "$DIR/$g" | grep -o -E 'lib/[a-z-]+\.sh'; done | sort -u); do
  [ -f "$DIR/$l" ] || continue
  bare="$bare$(grep -n -E '^(\.|source)[[:space:]]+"[^"]+\.sh"[[:space:]]*$' "$DIR/$l" | sed "s#^#$l:#")"
done
if [ -z "$bare" ]; then ok; else bad "a library a gate sources sources another without saying when it did not load:
$bare"; fi

# The scan is seen to fire on the shapes the hooks held before this change.
printf '%s\n' '. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0' > "$WORK/probe1"
printf '%s\n' '. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null \' '  || exit 0' > "$WORK/probe2"
printf '%s\n' '. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || not_judged "x"' > "$WORK/probe3"
[ -n "$(allowing_sources "$WORK/probe1")" ] && ok || bad "the scan does not fire on a one line source that exits 0"
[ -n "$(allowing_sources "$WORK/probe2")" ] && ok || bad "the scan does not fire on a source continued onto an exit 0"
[ -z "$(allowing_sources "$WORK/probe3")" ] && ok || bad "the scan fires on a source whose failure branch refuses"

# The behaviour, gate by gate: the command each judges, and the override it honours (or -). A gate
# that lets a call it could not judge through by recorded decision says so in its third field, with
# its issue. Those four said it with exit 1 (#735, #1065), the one exit whose message Claude Code
# showed while letting the call run; #1912 moved them to exit 0 with the notice as a systemMessage
# (lib/hook-notice.sh), which is shown and which onFailure block does not count as a failure.
declare_gate(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
{
  declare_gate payload-write-gate.sh       "echo hi > payload/LESSONS.md"   SKIP_PAYLOAD_WRITE_CHECK
  declare_gate check-style-guide.sh        "git push origin feature"        SKIP_STYLE_CHECK
  declare_gate check-grep-quiet-invert.sh  "git push origin feature"        SKIP_GREP_QV_CHECK
  declare_gate check-duplication.sh        "git push origin feature"        SKIP_DUPLICATION_CHECK
  declare_gate check-deferrals.sh          "git push origin feature"        SKIP_DEFERRAL_CHECK
  declare_gate check-doc-issue-refs.sh     "git push origin feature"        SKIP_DOC_REFS_CHECK
  declare_gate check-bundle-budget.sh      "git push origin feature"        SKIP_BUNDLE_BUDGET_CHECK
  declare_gate linux-sections-before-push.sh "git push origin feature"      SKIP_LINUX_CHECK
  declare_gate scanners-before-push.sh     "git push origin feature"        SKIP_SCANNERS_CHECK
  declare_gate push-scope-notice.sh        "git push origin feature"        -
  declare_gate check-add-scope.sh          "git add -A"                     SKIP_ADD_SCOPE_CHECK
  declare_gate check-closing-keyword.sh    "git commit -m 'does not close #4'" SKIP_CLOSING_CHECK
  declare_gate block-red-merge.sh          "gh pr merge 5 --squash"         ALLOW_RED_MERGE
  declare_gate check-closing-merge.sh      "gh pr merge 5 --squash"         SKIP_CLOSING_CHECK
  declare_gate require-changelog-tag.sh    "gh pr merge 5 --squash"         ALLOW_UNTAGGED_MERGE
  declare_gate require-verification-run.sh "gh pr merge 5 --squash"         ALLOW_UNVERIFIED_MERGE
  declare_gate design-score-gate.sh        "gh pr merge 5 --squash"         -
  declare_gate check-rtk-init.sh           "rtk init -g"                    -
  declare_gate stacked-branch-delete-gate.sh "git push origin :feat/x"      -
  declare_gate check-wrapped-commands.sh   "eval \$CMD && git status"       -
  declare_gate pr-review-gate.sh           "cat x/helper-key"               -
  declare_gate require-tests-before-push.sh  "git push origin feature"      "allow0 #1912"
  declare_gate simplify-before-push.sh       "git push origin feature"      "allow0 #1912"
  declare_gate check-public-assets.sh        "git push origin feature"      "allow0 #1912"
  declare_gate check-gh-watch-interval.sh    "gh run watch 5"               "allow0 #1912"
} > "$WORK/table"

payload_for(){ # payload_for <command> <cwd>
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2], "session_id": "s"}))' "$1" "$2"
}
# The libraries a gate needs, and, for each, the libraries that one sources in turn. Left out are
# the ones it sources as optional, whose absence it carries on past: `|| true`, or a bare `. x &&`
# that only turns a feature on (scanners-before-push.sh's pid lock), since the gate then goes on to
# judge the command with what it has. So is lib/hook-notice.sh, sourced with the fallback its header
# gives (`|| hook_allow_notice() {`): without it the gate judges exactly as before and says any
# notice through that fallback, which test-hook-notice.sh runs with the library gone (#1906). Any
# other library sourced with a stand in function (`|| bounded_run() {`) is optional the same way.
libs_of(){ # libs_of <gate file>
  local l
  grep -E "$SRC_RE" "$1" | grep -v -E '\|\|[[:space:]]*true' | grep -v -E '\|\|[[:space:]]*[a-z_]+\(\)' \
    | grep -v -E '^[[:space:]]*\.[^|]*&&[^|]*$' | grep -o -E 'lib/[a-z-]+\.sh' | sort -u | while IFS= read -r l; do
    printf '%s\n' "${l#lib/}"
    [ -f "$DIR/$l" ] && grep -E '^(\.|source)[[:space:]]+"\$[A-Za-z_]+/[a-z-]+\.sh"' "$DIR/$l" | grep -o -E '/[a-z-]+\.sh' | sed 's#^/##'
  done | sort -u
}

# Each run is fed from a file rather than a pipe from python3, which a gate leaving early would
# kill, and in a folder named by a number: a folder named after the gate or the library would put
# push, merge or payload into the payload's cwd and so into every command's raw text.
run_gate(){ # run_gate <gate copy> <command> <cwd> -> OUT and RC
  payload_for "$2" "$3" > "$WORK/in.json"
  OUT="$( cd "$3" && bash "$1" < "$WORK/in.json" 2>&1 )"; RC=$?
}
n=0
for g in "${GATES[@]}"; do
  # Only a library the gate needs: one it sources as optional is not taken away.
  libs="$(libs_of "$DIR/$g")"
  [ -n "$libs" ] || continue
  row="$(awk -F '\t' -v g="$g" '$1 == g' "$WORK/table")"
  if [ -z "$row" ]; then
    bad "$g sources a library and can refuse, and is not in this suite's table, so nothing runs it with that library gone"
    continue
  fi
  IFS=$'\t' read -r _ judged override <<< "$row"
  want=2
  case "$override" in allow0*) want=0 ;; esac
  for lib in $libs; do
    n=$((n + 1))
    T="$WORK/$n"
    mkdir -p "$T/repo"
    cp "$DIR/$g" "$T/$g"
    cp -R "$DIR/lib" "$T/lib"
    rm -f "$T/lib/$lib"
    run_gate "$T/$g" "$judged" "$T/repo"
    if [ "$RC" -eq "$want" ]; then ok; else bad "$g with lib/$lib missing: '$judged' should exit $want, exited $RC, said: ${OUT:0:200}"; fi
    # Named by the file, or for the gates that allow by the library's own name. A
    # library missing beneath another is reported as the one the gate sourced, which is what failed
    # to load from where the gate stands.
    named=0
    case "$OUT" in *"${lib%.sh}"*) named=1 ;; esac
    for d in $(grep -E "$SRC_RE" "$DIR/$g" | grep -o -E 'lib/[a-z-]+\.sh' | sort -u); do
      case "$OUT" in *"$d"*) named=1 ;; esac
    done
    [ "$named" -eq 1 ] && ok || bad "$g with lib/$lib missing: the message should name the library that did not load, said: ${OUT:0:200}"
    [ "$want" -eq 2 ] || continue
    run_gate "$T/$g" "ls -la" "$T/repo"
    if [ "$RC" -eq 0 ]; then ok; else bad "$g with lib/$lib missing: a command it does not judge should pass, exited $RC, said: ${OUT:0:200}"; fi
    if [ "$override" != "-" ]; then
      run_gate "$T/$g" "$override=1 $judged" "$T/repo"
      if [ "$RC" -eq 0 ]; then ok; else bad "$g with lib/$lib missing: its override $override=1 should still pass the command, exited $RC, said: ${OUT:0:200}"; fi
    fi
  done
done

# ---------------------------------------------------------------------------
echo "every python3 reader of stdin reads what jq reads (claude-config#1900)"

# Measured first, so a red below is about the hooks and not this machine: python3 reading its stdin
# in text mode under en_US.UTF-8 raises on a byte that is not UTF-8.
if printf 'a\xffb' | LC_ALL=en_US.UTF-8 python3 -c 'import sys; sys.stdin.read()' 2>/dev/null; then
  echo "SUITE-PART-UNMEASURED #1900 python3 text mode stdin under en_US.UTF-8 here reads a byte that is not UTF-8 without raising, so the fault this guards is not shown on this machine"
else ok; fi
# And the form every reader uses reads it.
if [ "$(printf 'a\xffb' | LC_ALL=en_US.UTF-8 python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace")))')" = "3" ]; then ok
else bad "sys.stdin.buffer.read().decode(\"utf-8\", \"replace\") did not read a byte that is not UTF-8 as one character"; fi

# Text mode stdin: .read(), iterating it, json.load on it, or handing it on as a file.
TEXT_RE='sys\.stdin\.read\(|json\.load\(sys\.stdin\)|in sys\.stdin([^.]|$)|return sys\.stdin[[:space:]]*$|sys\.stdin\.readline'
text_reads(){ # text_reads <file>... -> file:line of each text mode read of stdin
  grep -n -E "$TEXT_RE" "$@" 2>/dev/null
}
files=()
for f in "$DIR"/*.sh "$DIR"/*.py "$DIR"/lib/*.sh "$DIR"/lib/*.py; do
  case "$(basename "$f")" in test-*|test_*) continue ;; esac
  files+=("$f")
done
hits="$(text_reads "${files[@]}" | sed "s#^$DIR/##")"
if [ -z "$hits" ]; then ok; else bad "a python3 reader takes stdin in text mode, which raises on a byte jq reads as U+FFFD; read sys.stdin.buffer and decode with errors=\"replace\":
$hits"; fi
printf '%s\n' '    d = json.load(sys.stdin)' 'for line in sys.stdin:' 'x = sys.stdin.read()' > "$WORK/probe-py"
[ "$(text_reads "$WORK/probe-py" | wc -l | tr -d ' ')" = "3" ] && ok || bad "the stdin scan does not fire on each of the three shapes the hooks held"
printf '%s\n' 'x = sys.stdin.buffer.read().decode("utf-8", "replace")' > "$WORK/probe-py2"
[ -z "$(text_reads "$WORK/probe-py2")" ] && ok || bad "the stdin scan fires on the buffered read it asks for"

# ---------------------------------------------------------------------------
echo "every hook takes its payload through the shared reader (claude-config#1944)"

# Every registered hook, of every event, and the files it runs.
python3 - "$SETTINGS" > "$WORK/all-hooks" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
seen = set()
for ev, groups in d.get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            m = re.search(r"hooks/([A-Za-z0-9_.-]+\.sh)", h.get("command", ""))
            if m and m.group(1) not in seen:
                seen.add(m.group(1))
                print(m.group(1))
PY
ALL_HOOKS=()
while IFS= read -r h; do [ -f "$DIR/$h" ] && ALL_HOOKS+=("$h"); done < "$WORK/all-hooks"
[ "${#ALL_HOOKS[@]}" -ge 50 ] && ok || bad "only ${#ALL_HOOKS[@]} registered hook scripts were found in $SETTINGS, so the enumeration is reading the wrong thing"

# A hook's stdin taken with cat and never cleaned. Two shapes are fine: payload="$(ps_read_payload)",
# and a raw capture that a later line cleans in place, payload="$(ps_clean_payload "$payload")", which
# a hook uses when it searches the raw text for its words before loading anything, so that the
# commonest call leaves without a library. Also fine is a capture inside the block a hook runs when
# lib/push-scope.sh did not load, where the reader is exactly what is missing and the raw text is only
# searched for words: the block opened by a source of push-scope.sh, or of merge-target.sh which
# sources it, whose failure branch is `|| {`, ending at the closing brace at that line's own indent.
raw_captures(){ # raw_captures <file>... -> file:line of each stdin capture nothing cleans
  awk '
    function flush(   v) { for (v in cap) if (!(v in cleaned) || cleaned[v] < capn[v]) print cap[v]; delete cap; delete capn; delete cleaned }
    FNR == 1 { flush(); inblk = 0; ind = "" }
    {
      if (inblk) {
        if ($0 ~ "^" ind "}") inblk = 0
        next
      }
      if ($0 ~ /lib\/(push-scope|merge-target)\.sh/ && $0 ~ /\|\|[[:space:]]*\{[[:space:]]*$/) {
        inblk = 1; match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH); next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      if (match($0, /[A-Za-z_][A-Za-z0-9_]*=["]?\$\(cat( 2>\/dev\/null)?( \|\| true)?\)/)) {
        v = substr($0, RSTART); sub(/=.*/, "", v)
        if (!(v in cap)) { cap[v] = FILENAME ":" FNR ": " $0; capn[v] = FNR }
      }
      if (match($0, /[A-Za-z_][A-Za-z0-9_]*="\$\(ps_clean_payload "\$[A-Za-z_][A-Za-z0-9_]*"\)"/)) {
        v = substr($0, RSTART); sub(/=.*/, "", v); cleaned[v] = FNR
      }
    }
    END { flush() }' "$@"
}
caps="$(cd "$DIR" && raw_captures "${ALL_HOOKS[@]}")"
if [ -z "$caps" ]; then ok; else bad "a hook takes its payload off stdin with cat, so a lone surrogate escape in it reaches jq, which then reads nothing; take it with payload=\"\$(ps_read_payload)\" from lib/push-scope.sh:
$caps"; fi
printf '%s\n' 'payload="$(cat)"' 'input=$(cat)' 'x="$(cat 2>/dev/null || true)"' > "$WORK/probe-cap"
[ "$(raw_captures "$WORK/probe-cap" | wc -l | tr -d ' ')" = "3" ] && ok || bad "the capture scan does not fire on each of the three shapes the hooks held"
printf '%s\n' '{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_read_payload >/dev/null; } || {' '  payload="$(cat)"' '}' 'payload="$(ps_read_payload)"' 'raw="$(cat)"' 'case "$raw" in *push*) ;; *) exit 0 ;; esac' 'raw="$(ps_clean_payload "$raw")"' > "$WORK/probe-cap2"
[ -z "$(raw_captures "$WORK/probe-cap2")" ] && ok || bad "the capture scan fires on the library missing block, on the reader it asks for, or on a capture cleaned in place: $(raw_captures "$WORK/probe-cap2")"
printf '%s\n' 'other="$(ps_clean_payload "$other")"' 'payload="$(cat)"' > "$WORK/probe-cap3"
[ -n "$(raw_captures "$WORK/probe-cap3")" ] && ok || bad "the capture scan accepts a capture cleaned only above it, or cleaned under another name"

# ---------------------------------------------------------------------------
echo "an advisory hook that cannot load a library says it did not run (claude-config#1922)"

# Every registered hook, not only the refusing ones: an advisory hook sourcing its library with a bare
# exit 0 went quiet, which reads exactly like a call it had nothing to say about.
found=""
for h in "${ALL_HOOKS[@]}"; do s="$(allowing_sources "$DIR/$h")"; [ -n "$s" ] && found="$found$s"$'\n'; done
if [ -z "$found" ]; then ok; else bad "a hook stops in silence when a library it sources cannot be loaded; say it did not run through hook_allow_notice:
$found"; fi

# And run: each named advisory hook, with each library it needs taken away, on a call it acts on,
# says once that it did not run, naming the file, and allows the call. A table, since each acts on a
# different call; a registered hook that sources a library and is in neither table fails below.
declare_advisory(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
{
  declare_advisory rtk-rewrite.sh          PreToolUse   "gh api repos/o/r"
  declare_advisory lessons-advisory.sh     PreToolUse   "git push origin feature"
  declare_advisory ai-review-on-push.sh    PostToolUse  "git push origin feature"
  declare_advisory ai-review-on-pr.sh      PostToolUse  "gh pr create --title x --body y"
  declare_advisory ai-review-nudge.sh      UserPromptSubmit "-"
  declare_advisory durable-lesson-check.sh PostToolUse  "gh issue create --title x --body y"
  declare_advisory pr-merge-quiz.sh        PostToolUse  "gh pr merge 5 --squash"
  declare_advisory sync-main-to-dev.sh     PostToolUse  "gh pr merge 5 --squash"
  declare_advisory check-filed-issue-session.sh PostToolUse "gh issue create --title x --body y"
  declare_advisory payload-revert-warning.sh UserPromptSubmit "-"
} > "$WORK/advisory"
# A stand in rtk, so rtk-rewrite.sh reaches the reading it needs the library for on a machine with no
# rtk or a different one: it rewrites every command by putting rtk in front.
mkdir -p "$WORK/advbin"
printf '#!/bin/sh\ncase "$1" in --version) echo "rtk 0.31.0" ;; rewrite) echo "rtk $2" ;; *) exit 1 ;; esac\n' > "$WORK/advbin/rtk"
chmod +x "$WORK/advbin/rtk"
advisory_payload(){ # advisory_payload <event> <command> <cwd>
  python3 -c '
import json, sys
ev, cmd, cwd = sys.argv[1:4]
d = {"hook_event_name": ev, "session_id": "s", "cwd": cwd, "transcript_path": cwd + "/t.jsonl"}
if cmd != "-":
    d.update(tool_name="Bash", tool_input={"command": cmd}, tool_response={"stdout": "", "stderr": ""})
else:
    d.update(prompt="hello")
print(json.dumps(d))' "$1" "$2" "$3"
}
# The refusing gates, PreToolUse hooks registered with onFailure block, are the section below's.
python3 - "$SETTINGS" > "$WORK/blocking" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
seen = set()
for g in d.get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        m = re.search(r"hooks/([A-Za-z0-9_.-]+\.sh)", h.get("command", ""))
        if m and h.get("onFailure") == "block" and m.group(1) not in seen:
            seen.add(m.group(1))
            print(m.group(1))
PY
for h in "${ALL_HOOKS[@]}"; do
  grep -q -x -F "$h" "$WORK/blocking" && continue
  libs="$(libs_of "$DIR/$h" | grep -v -x 'hook-notice.sh')"
  [ -n "$libs" ] || continue
  row="$(awk -F '\t' -v g="$h" '$1 == g' "$WORK/advisory")"
  if [ -z "$row" ]; then
    bad "$h is an advisory hook that sources a library, and is not in this suite's advisory table, so nothing runs it with that library gone"
    continue
  fi
  IFS=$'\t' read -r _ event acts <<< "$row"
  for lib in $libs; do
    n=$((n + 1))
    T="$WORK/$n"
    mkdir -p "$T/repo"
    cp "$DIR/$h" "$T/$h"
    cp -R "$DIR/lib" "$T/lib"
    rm -f "$T/lib/$lib"
    advisory_payload "$event" "$acts" "$T/repo" > "$WORK/in.json"
    OUT="$( cd "$T/repo" && HOME="$T" PATH="$WORK/advbin:$PATH" CLAUDE_DETACHED_RUN= bash "$T/$h" < "$WORK/in.json" 2>/dev/null )"; RC=$?
    if [ "$RC" -eq 0 ]; then ok; else bad "$h with lib/$lib missing: an advisory hook must allow, exited $RC"; fi
    v="$(hook_notice_verdict "$OUT" '(?i)did not run' 2>&1)"
    if [ -z "$v" ]; then ok; else bad "$h with lib/$lib missing should say once that it did not run: $v"; fi
    case "$OUT" in *"${lib%.sh}"*) ok ;; *)
      named=0
      for d in $(grep -E "$SRC_RE" "$DIR/$h" | grep -o -E 'lib/[a-z-]+\.sh' | sort -u); do case "$OUT" in *"$d"*) named=1 ;; esac; done
      [ "$named" -eq 1 ] && ok || bad "$h with lib/$lib missing: the notice should name the library that did not load, said: ${OUT:0:200}" ;;
    esac
  done
done

# ---------------------------------------------------------------------------
echo "every refusing gate judges a call it cannot parse by its raw text (claude-config#1922), and a lone surrogate escape changes no gate's decision (#1944)"

# The refusing gates, read above. Each judged call is a tool, its input with @@ where text holding the
# escape goes, any fields an agent's payload adds, and what the gate does with a call it cannot parse:
# refuse, or let it through saying so, by recorded decision.
[ "$(wc -l < "$WORK/blocking" | tr -d ' ')" -ge 30 ] && ok || bad "only $(wc -l < "$WORK/blocking" | tr -d ' ') blocking PreToolUse gates were found in $SETTINGS"
AGENT='{"agent_id": "a1b2c3d4"}'
# A transcript in which the agent committed with --no-verify, for the hand-back gate to compare.
mkdir -p "$WORK/hb"
python3 - "$WORK/hb/agent.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_01", "name": "Bash", "input": {"command": "git commit --no-verify -m wip"}}]}}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_01", "content": "done", "is_error": False}]}}) + "\n")
PY
judged(){ printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
bash_call(){ python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1] + " && echo \"cut @@\"", "description": "cut @@"}))' "$1"; }
{
  judged payload-write-gate.sh        Bash "$(bash_call 'echo hi > payload/LESSONS.md')" '{}' refuse
  judged push-scope-notice.sh         Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged require-tests-before-push.sh Bash "$(bash_call 'git push origin feature')" '{}' "notice #1912"
  judged simplify-before-push.sh      Bash "$(bash_call 'git push origin feature')" '{}' "notice #1912"
  judged check-style-guide.sh         Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-grep-quiet-invert.sh   Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-duplication.sh         Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-public-assets.sh       Bash "$(bash_call 'git push origin feature')" '{}' "notice #1912"
  judged check-deferrals.sh           Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-doc-issue-refs.sh      Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-bundle-budget.sh       Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-closing-keyword.sh     Bash "$(bash_call "git commit -m 'does not close #4'")" '{}' refuse
  judged block-red-merge.sh           Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged design-score-gate.sh         Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged pr-review-gate.sh            Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged pr-review-push-gate.sh       Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged require-changelog-tag.sh     Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged check-closing-merge.sh       Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged require-verification-run.sh  Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged require-issue-fields.sh      Bash "$(bash_call "gh issue create --title 'x' --body 'y'")" '{}' refuse
  judged linux-sections-before-push.sh Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged scanners-before-push.sh      Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-add-scope.sh           Bash "$(bash_call 'git add -A')" '{}' refuse
  judged no-verify-gate.sh            Bash "$(bash_call 'git commit --no-verify -m wip')" "$AGENT" refuse
  judged amend-force-push-gate.sh     Bash "$(bash_call 'git commit --amend -m wip')" "$AGENT" refuse
  judged check-gh-watch-interval.sh   Bash "$(bash_call 'gh run watch 5')" '{}' "notice #1912"
  judged check-rtk-init.sh            Bash "$(bash_call 'rtk init -g')" '{}' refuse
  judged check-wrapped-commands.sh    Bash "$(bash_call 'eval $CMD && git status')" '{}' refuse
  judged stacked-branch-delete-gate.sh Bash "$(bash_call 'git push origin :feat/x')" '{}' refuse
  # Three gates let a call they cannot parse through, saying so, by the decision each records in its
  # header: refusing there takes away the scratchpad, the hand-back or the browser with no remedy
  # inside the session, since what makes a payload unparseable is not something the agent can change.
  judged scratchpad-subagent-gate.sh  Write '{"file_path": "/private/tmp/claude-501/proj/sess/scratchpad/notes.md", "content": "cut @@", "description": "cut @@"}' "$AGENT" "notice scratchpad-subagent-gate.sh header"
  judged monitor-action-gate.sh       Monitor "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged handback-claims-gate.sh      SubagentHandback '{"message": "Done. No --no-verify, no overrides. cut @@", "description": "cut @@"}' "{\"agent_id\": \"a1b2c3d4\", \"agent_transcript_path\": \"$WORK/hb/agent.jsonl\"}" "notice handback-claims-gate.sh header"
  judged playwright-subagent-gate.sh  mcp__playwright__browser_navigate '{"url": "https://example.com/@@", "description": "cut @@"}' "$AGENT" "notice playwright-subagent-gate.sh header"
  judged no-session-link-in-comments.sh Bash "$(bash_call "gh pr comment 5 --body 'see https://claude.ai/code/session_01abc'")" '{}' refuse
} > "$WORK/judged"
# Every blocking gate is in the table, so one added later is not exempt by being unlisted (L96).
while IFS= read -r g; do
  awk -F '\t' -v g="$g" '$1 == g { f = 1 } END { exit !f }' "$WORK/judged" && ok \
    || bad "$g is registered to block and is not in this suite's table of judged calls, so nothing runs it on a payload it cannot parse or one holding a lone surrogate escape"
done < "$WORK/blocking"

# judged_payload <tool> <input> <extra> <mark> <cwd> <whole|cut>: the call as JSON TEXT, with @@ as
# <mark>, which is written into the text after encoding so that \ud800 stays the escape it is in a
# real payload. cut drops the closing brace, which no JSON reader accepts.
judged_payload(){
  python3 - "$@" <<'PY'
import json, sys
tool, inp, extra, mark, cwd, how = sys.argv[1:7]
d = {"hook_event_name": "PreToolUse", "session_id": "s", "cwd": cwd, "transcript_path": cwd + "/t.jsonl",
     "tool_name": tool, "tool_input": json.loads(inp)}
d.update(json.loads(extra))
text = json.dumps(d).replace("@@", mark)
if how == "cut":
    text = text[:-1]
sys.stdout.write(text)
PY
}
# A stand in for every tool that would reach the network or a model, so each gate runs to its
# decision in a second rather than the minutes the #1923 probe took against the real ones. Both
# halves of a pair meet the same stand in, so whatever it makes the gate decide, it decides twice.
mkdir -p "$WORK/bin"
for t in gh claude curl; do
  printf '#!/bin/sh\necho "%s stand-in: this suite reaches no network or model" >&2\nexit 1\n' "$t" > "$WORK/bin/$t"
  chmod +x "$WORK/bin/$t"
done
. "$DIR/lib/bounded-run.sh"
# A watch daemon running from another clone, which is what payload-write-gate.sh protects against:
# with none, a write under payload/ has nothing to revert it and is never refused, readable or not.
bash -c 'exec -a "'"$WORK"'/src/claude-sync watch" sleep 600' &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
printf '%s\n' "$WATCH_PID" > "$WORK/watch.pid"
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WATCH_PID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
export SYNC_WATCH_PID_FILE="$WORK/watch.pid" SYNC_HOLD_FILE="$WORK/no-hold"
# run_judged <run dir> <gate> <payload file>: the gate in its own HOME and repo, bounded, and its
# decision as one line: the exit code, any permissionDecision, and whether it said anything.
run_judged(){
  local R="$1" said decision
  mkdir -p "$R/home" "$R/repo"
  ( cd "$R/repo" && git init -q . 2>/dev/null )
  bounded_run 60 env HOME="$R/home" PATH="$WORK/bin:$PATH" CLAUDE_DETACHED_RUN= \
    bash -c 'cd "$1" && exec bash "$2" < "$3" 2> "$4"' _ "$R/repo" "$DIR/$2" "$3" "$R/err"
  # stdout alone, which is where a notice or a permissionDecision has to be; stderr beside it for
  # the reason a refusal gives.
  printf '%s' "$BOUNDED_OUT" > "$R/stdout"
  said="$BOUNDED_OUT$(cat "$R/err" 2>/dev/null)"
  local re='"permissionDecision"[[:space:]]*:[[:space:]]*"([a-z]+)"'
  decision=none
  [[ $BOUNDED_OUT =~ $re ]] && decision="${BASH_REMATCH[1]}"
  printf 'exit %s, decision %s, %s\n' "$BOUNDED_RC" "$decision" "$([ -n "$said" ] && echo "said something" || echo "said nothing")" > "$R/decision"
  printf '%s' "$said" > "$R/said"
}
# Each gate's runs go in the background, a few at a time, since each waits on its own git and python.
# Waited on by pid, never with a bare wait, which would wait on the watcher above too.
k=0
pids=()
while IFS=$'\t' read -r g tool inp extra unread; do
  k=$((k + 1))
  R="$WORK/j$k"
  mkdir -p "$R/esc" "$R/plain" "$R/cut" "$R/other"
  judged_payload "$tool" "$inp" "$extra" '\ud800' "$R/esc/repo" whole > "$R/esc.json"
  judged_payload "$tool" "$inp" "$extra" 'Q' "$R/plain/repo" whole > "$R/plain.json"
  judged_payload "$tool" "$inp" "$extra" '' "$R/cut/repo" cut > "$R/cut.json"
  judged_payload Bash '{"command": "ls -la"}' '{}' '' "$R/other/repo" cut > "$R/other.json"
  ( for c in esc plain cut other; do run_judged "$R/$c" "$g" "$R/$c.json"; done ) &
  pids+=("$!")
  if [ "${#pids[@]}" -ge 6 ]; then wait "${pids[@]}"; pids=(); fi
done < "$WORK/judged"
[ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}"
k=0
while IFS=$'\t' read -r g tool inp extra unread; do
  k=$((k + 1))
  R="$WORK/j$k"
  esc="$(cat "$R/esc/decision" 2>/dev/null)"; plain="$(cat "$R/plain/decision" 2>/dev/null)"
  if [ -n "$esc" ] && [ "$esc" = "$plain" ]; then ok
  else bad "$g decides differently on a call holding a lone surrogate escape ($esc) than on the same call with a letter in its place ($plain); it said: $(head -c 300 "$R/esc/said" 2>/dev/null)"; fi
  case "$esc" in "exit 124"*) bad "$g ran past its 60 second bound on the judged call, so the decisions above compare two timeouts" ;; esac
  cut="$(cat "$R/cut/said" 2>/dev/null)"; cutd="$(cat "$R/cut/decision" 2>/dev/null)"
  case "$unread" in
    refuse)
      case "$cutd" in "exit 2,"*|*"decision deny"*) ok ;; *) bad "$g let a call it could not parse through although its raw text names what it judges ($cutd): ${cut:0:200}" ;; esac
      case "$cut" in *payload*|*Payload*) ok ;; *) bad "$g refused a call it could not parse without naming the payload as the reason: ${cut:0:200}" ;; esac ;;
    notice*)
      case "$cutd" in "exit 0, decision none, said something") ok ;; *) bad "$g, which lets a call it cannot parse through by recorded decision (${unread#notice }), should allow it and say so ($cutd): ${cut:0:200}" ;; esac
      v="$(hook_notice_verdict "$(cat "$R/cut/stdout" 2>/dev/null)" '(?i)did not run|not judged|could not (read|judge|parse)|unread' 2>&1)"
      [ -z "$v" ] && ok || bad "$g let a call it could not parse through without saying so in a systemMessage: $v" ;;
  esac
  otherd="$(cat "$R/other/decision" 2>/dev/null)"
  case "$otherd" in "exit 0, decision none"*) ok ;; *) bad "$g refused an unrelated call it could not parse ($otherd): $(head -c 200 "$R/other/said" 2>/dev/null)" ;; esac
done < "$WORK/judged"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
