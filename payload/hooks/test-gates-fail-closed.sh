#!/usr/bin/env bash
# The class guard for claude-config#1900: a gate allows nothing it could not read.
#
# Two ways a gate allowed what it could not read, each found in one hook and then swept (three more
# follow below them):
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
#
# Three more, added with the shared payload reader (claude-config#1944, #1922):
#
#   3. A payload taken off stdin and never cleaned. jq rejects a whole payload holding a lone
#      surrogate escape, so every registered hook, of every event, takes its payload through
#      ps_read_payload or cleans a raw capture with ps_clean_payload before anything parses it.
#   4. An advisory hook stopping in silence when a library will not load: every registered hook is
#      scanned for it, and each advisory hook that sources one is run with it gone, on a call it acts
#      on, and must say once that it did not run.
#   5. Every hook registered to block is run on a call it judges holding the escape and on the same
#      call with a letter in its place, and must decide alike; on that call cut short, where it must
#      refuse naming the payload (or, by recorded decision, let it through saying so); and on an
#      unrelated call cut short, which it must pass. Stand ins replace gh, claude and curl, so each
#      gate runs to its decision in about a second.
#
# And one the first of these left open (claude-config#2634):
#
#   6. A library loaded with a stand in function (`. lib/x.sh || name() {`). The second half of 1
#      left every such library out as optional, so nothing ran a gate with one gone, and a stand in
#      that lets the judged call through looked the same here as one that decides nothing. A gate's
#      stand in is optional only when it is one this suite names as examined; any other library is
#      needed again and taken away in 1. Each gate is then run with each examined one gone, on its
#      judged call whole and cut short, and must decide as it does with the library in place.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/test_bad_byte_locale.sh" || {
  echo "FAIL: $(basename "$0"): lib/test_bad_byte_locale.sh is missing, so its cases with a byte that is not UTF-8 have no locale to run under."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
BAD_BYTE_LOCALE="$(bad_byte_locale)"
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
  declare_gate check-work-names-merge.sh   "gh pr merge 5 --squash"         -
  declare_gate check-work-names-publish.sh "gh pr create --title T --body B" -
  declare_gate require-changelog-tag.sh    "gh pr merge 5 --squash"         ALLOW_UNTAGGED_MERGE
  declare_gate require-verification-run.sh "gh pr merge 5 --squash"         ALLOW_UNVERIFIED_MERGE
  declare_gate design-score-gate.sh        "gh pr merge 5 --squash"         -
  declare_gate check-rtk-init.sh           "rtk init -g"                    -
  declare_gate temp-worktree-gate.sh       "git worktree add /tmp/wt-2528"  ALLOW_TEMP_WORKTREE
  declare_gate stacked-branch-delete-gate.sh "git push origin :feat/x"      -
  declare_gate check-wrapped-commands.sh   "eval \$CMD && git status"       -
  declare_gate pr-review-gate.sh           "cat x/helper-key"               -
  # It judges a file edit, never a shell command: @fresh-worktree is the edit fixture_payload builds.
  declare_gate fresh-worktree-base-gate.sh "@fresh-worktree"                -
  declare_gate require-tests-before-push.sh  "git push origin feature"      "allow0 #1912"
  declare_gate simplify-before-push.sh       "git push origin feature"      "allow0 #1912"
  declare_gate check-public-assets.sh        "git push origin feature"      "allow0 #1912"
  declare_gate check-gh-watch-interval.sh    "gh run watch 5"               "allow0 #1912"
} > "$WORK/table"

payload_for(){ # payload_for <command> <cwd>
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2], "session_id": "s"}))' "$1" "$2"
}
# A judged call that is not a shell command is named @<fixture>, and this builds what it needs under
# the run's own folder and prints the call.
#   @fresh-worktree  an Edit in a worktree with no commits of its own, level with its origin, which
#                    is a bare repository beside it, so no run reaches the network. With every
#                    library in place the gate fetches, finds the worktree current and passes in
#                    silence, so a refusal there can only be about the library taken away.
fx_git(){ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fixture_payload(){ # fixture_payload <@fixture> <run folder>
  local fx="$2/fx"
  case "$1" in
    @fresh-worktree)
      if [ ! -d "$fx/repo/wt" ]; then
        mkdir -p "$fx"
        fx_git init -q --bare "$fx/origin.git"
        fx_git clone -q "$fx/origin.git" "$fx/repo"
        printf 'c1\n' > "$fx/repo/c1.txt"
        fx_git -C "$fx/repo" add c1.txt
        fx_git -C "$fx/repo" commit -q -m c1
        fx_git -C "$fx/repo" push -q origin HEAD:main
        fx_git -C "$fx/repo" worktree add -q "$fx/repo/wt" -b fresh origin/main
      fi
      python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": {"file_path": sys.argv[1], "old_string": "a", "new_string": "b"}, "cwd": sys.argv[2], "session_id": "s"}))' "$fx/repo/wt/c1.txt" "$fx/repo/wt" ;;
    *) return 1 ;;
  esac
}
# The fixture is seen to be one the gate passes with everything in place, so that a refusal below
# is about the library taken away and never about the fixture (L1).
fx_home="$WORK/fx-probe/home"
mkdir -p "$WORK/fx-probe/repo" "$fx_home"
fixture_payload @fresh-worktree "$WORK/fx-probe" > "$WORK/fx-probe/in.json"
fx_out="$( cd "$WORK/fx-probe/repo" && HOME="$fx_home" FRESH_WORKTREE_STATE_DIR="$fx_home/state" bash "$DIR/fresh-worktree-base-gate.sh" < "$WORK/fx-probe/in.json" 2>&1 )"; fx_rc=$?
[ "$fx_rc" -eq 0 ] && [ -z "$fx_out" ] && [ -d "$WORK/fx-probe/fx/repo/wt" ] && ok \
  || bad "the @fresh-worktree fixture is not an edit fresh-worktree-base-gate.sh passes in silence with every library in place (exit $fx_rc), so a refusal with one gone would prove nothing: ${fx_out:0:200}"

# A library loaded with a stand in function: `. "$X/lib/y.sh" 2>/dev/null || name() {`. The library,
# the function, and what follows it on the line.
STANDIN_RE='/([a-z-]+\.sh)"[^|]*\|\|[[:space:]]*([a-z_]+)\(\)(.*)$'
# The stand ins a GATE may carry on with, each examined: its library, the function standing in, the
# shape of the stand in on the source line, and why a gate decides the same with it. Any other
# stand in a gate loads leaves its library NEEDED, so the gate is run with it gone below and must
# refuse the call it judges, as with any library (claude-config#2634). Until then every stand in
# was optional by its shape alone, `|| bounded_run() {` among them, and fresh-worktree-base-gate.sh
# let an edit through that it refuses with the library in place. Naming one here is not enough to
# pass: each gate is also run with each of these gone, in the last section.
declare_standin(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
{
  declare_standin hook-notice.sh hook_allow_notice '^[[:space:]]*\{[[:space:]]*(#.*)?$' \
    "says the notice and exits 0, as the library's own does, so it decides nothing; test-hook-notice.sh holds every hook to the one body the library's header gives (#1906)"
  declare_standin this-mac.sh this_mac_name '^[[:space:]]*\{[[:space:]]*return 1;[[:space:]]*\}[[:space:]]*$' \
    "answers as the library's own does when the Mac's name cannot be read; the name goes into a record and decides nothing (#2561)"
} > "$WORK/standins"
examined_standin(){ # examined_standin <library> <function> <rest of the line>
  local lib fn shape _why
  while IFS=$'\t' read -r lib fn shape _why; do
    [ "$lib" = "$1" ] && [ "$fn" = "$2" ] && [[ $3 =~ $shape ]] && return 0
  done < "$WORK/standins"
  return 1
}
# standin_filter <needed|examined> [gate]: source lines on stdin.
#   needed    the lines whose library the hook cannot do without: every line that is not a stand
#             in and, for a gate, a stand in nobody examined. For any other hook every stand in is
#             still optional by its shape: an advisory hook refuses nothing, and this suite does
#             not run one with a stand in library gone.
#   examined  the lines whose stand in is optional.
standin_filter(){
  local line lib fn rest optional
  while IFS= read -r line; do
    if [[ $line =~ $STANDIN_RE ]]; then
      lib="${BASH_REMATCH[1]}"; fn="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
      optional=1
      if [ "${2:-}" = gate ] && ! examined_standin "$lib" "$fn" "$rest"; then optional=0; fi
      if [ "$1" = examined ]; then [ "$optional" = 1 ] && printf '%s\n' "$line"
      else [ "$optional" = 0 ] && printf '%s\n' "$line"; fi
    elif [ "$1" = needed ]; then
      printf '%s\n' "$line"
    fi
  done
  return 0
}
# A library's own source lines: the libraries IT loads.
SUB_SRC_RE='^[[:space:]]*(\{[[:space:]]*)?(\.|source)[[:space:]]+"\$[A-Za-z_]+/[a-z-]+\.sh"'
# The libraries a hook needs, and, for each, the libraries that one sources in turn. Left out are
# the ones it sources as optional, whose absence it carries on past: `|| true`, or a bare `. x &&`
# that only turns a feature on (scanners-before-push.sh's pid lock), since the gate then goes on to
# judge the command with what it has. So is one loaded with an optional stand in (standin_filter):
# lib/hook-notice.sh with the fallback its header gives (`|| hook_allow_notice() {`), without which
# the gate judges exactly as before and says any notice through that fallback (#1906).
libs_of(){ # libs_of <hook file> [gate]
  local l
  grep -E "$SRC_RE" "$1" | grep -v -E '\|\|[[:space:]]*true' | standin_filter needed "${2:-}" \
    | grep -v -E '^[[:space:]]*\.[^|]*&&[^|]*$' | grep -o -E 'lib/[a-z-]+\.sh' | sort -u | while IFS= read -r l; do
    printf '%s\n' "${l#lib/}"
    # The same optional shapes are left out one level down: lib/push-changes.sh loads
    # lib/this-mac.sh with a stand in (`|| this_mac_name() {`), so its absence stops no gate (#2561).
    [ -f "$DIR/$l" ] && grep -E "$SUB_SRC_RE" "$DIR/$l" \
      | grep -v -E '\|\|[[:space:]]*true' | standin_filter needed "${2:-}" | grep -o -E '/[a-z-]+\.sh' | sed 's#^/##'
  done | sort -u
}
# The libraries a gate carries on without by an examined stand in, at its own level and beneath
# each library it needs: what the last section takes away one at a time.
standin_libs_of(){ # standin_libs_of <gate file>
  local l
  { grep -E "$SRC_RE" "$1" | standin_filter examined gate | grep -o -E 'lib/[a-z-]+\.sh' | sed 's#^lib/##'
    for l in $(libs_of "$1" gate); do
      [ -f "$DIR/lib/$l" ] && grep -E "$SUB_SRC_RE" "$DIR/lib/$l" | standin_filter examined gate | grep -o -E '/[a-z-]+\.sh' | sed 's#^/##'
    done
  } | sort -u
}

# A library a gate needs is followed into the libraries IT loads, in either shape a library here
# loads one: a bare source, or `{ . "$X/y.sh" && declare -F f >/dev/null; } || return 1`, which is
# how merge-target.sh loads push-scope.sh and whole-number.sh (claude-config#1948). The second
# shape was not read, so neither was ever taken away beneath the five gates that load merge-target.sh.
printf '%s\n' '. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || { echo "missing merge-target.sh" >&2; exit 2; }' > "$WORK/probe-gate"
probe_libs="$(libs_of "$WORK/probe-gate" | tr '\n' ' ')"
probe_missing=""
for want in merge-target.sh push-scope.sh whole-number.sh; do
  case " $probe_libs" in *" $want "*) ;; *) probe_missing="$probe_missing $want" ;; esac
done
[ -z "$probe_missing" ] && ok \
  || bad "libs_of does not follow a library into the ones it loads as { . lib && declare -F f; } || return 1: it listed [$probe_libs] for a gate loading lib/merge-target.sh, without$probe_missing"
# One level down, a library loaded with a stand in function is optional, as it is at the gate's own
# level: a gate loading lib/push-changes.sh needs it, never the lib/this-mac.sh it loads with one.
printf '%s\n' '. "$HOOK_DIR/lib/push-changes.sh" 2>/dev/null || { echo "missing push-changes.sh" >&2; exit 2; }' > "$WORK/probe-gate2"
probe_libs="$(libs_of "$WORK/probe-gate2" gate | tr '\n' ' ')"
case " $probe_libs" in
  *" this-mac.sh "*) bad "libs_of takes lib/this-mac.sh away beneath lib/push-changes.sh, which loads it with a stand in: it listed [$probe_libs]" ;;
  *" push-changes.sh "*) ok ;;
  *) bad "libs_of did not list lib/push-changes.sh for a gate loading it: it listed [$probe_libs]" ;;
esac
[ "$(standin_libs_of "$WORK/probe-gate2" | tr '\n' ' ')" = "this-mac.sh " ] && ok \
  || bad "#2634 standin_libs_of should list lib/this-mac.sh, which lib/push-changes.sh loads with an examined stand in, for a gate loading lib/push-changes.sh: it listed [$(standin_libs_of "$WORK/probe-gate2" | tr '\n' ' ')]"
# A gate's stand in is optional only when it is examined (#2634): the two named above are, in the
# shape named there. Any other function, or one of those names over another body, leaves the
# library needed, so the gate is run with it gone. An advisory hook's stand ins stay optional.
printf '%s\n' \
  '. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing' \
  '. "$HOOK_DIR/lib/this-mac.sh" 2>/dev/null || this_mac_name() { return 1; }' > "$WORK/probe-gate3"
[ -z "$(libs_of "$WORK/probe-gate3" gate)" ] && ok \
  || bad "#2634 libs_of counts a library a gate loads with an examined stand in as needed: it listed [$(libs_of "$WORK/probe-gate3" gate | tr '\n' ' ')]"
[ "$(standin_libs_of "$WORK/probe-gate3" | tr '\n' ' ')" = "hook-notice.sh this-mac.sh " ] && ok \
  || bad "#2634 standin_libs_of should list both libraries a gate loads with an examined stand in: it listed [$(standin_libs_of "$WORK/probe-gate3" | tr '\n' ' ')]"
printf '%s\n' \
  '. "$HOOK_DIR/lib/bounded-run.sh" 2>/dev/null || bounded_run() {  # the library is missing' \
  '. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() { exit 0; }' \
  '. "$HOOK_DIR/lib/this-mac.sh" 2>/dev/null || this_mac_name() { exit 0; }' \
  '. "$HOOK_DIR/lib/whole-number.sh" 2>/dev/null || judge() { return 0; }' > "$WORK/probe-gate4"
[ "$(libs_of "$WORK/probe-gate4" gate | tr '\n' ' ')" = "bounded-run.sh hook-notice.sh this-mac.sh whole-number.sh " ] && ok \
  || bad "#2634 libs_of should count as needed every library a gate loads with a stand in nobody examined (another function, or an examined name over another body): it listed [$(libs_of "$WORK/probe-gate4" gate | tr '\n' ' ')]"
[ -z "$(standin_libs_of "$WORK/probe-gate4")" ] && ok \
  || bad "#2634 standin_libs_of lists a stand in nobody examined as optional: [$(standin_libs_of "$WORK/probe-gate4" | tr '\n' ' ')]"
[ -z "$(libs_of "$WORK/probe-gate4")" ] && ok \
  || bad "#2634 libs_of counts an advisory hook's stand ins as needed, which the advisory section does not ask of them: it listed [$(libs_of "$WORK/probe-gate4" | tr '\n' ' ')]"

# Each run is fed from a file rather than a pipe from python3, which a gate leaving early would
# kill, and in a folder named by a number: a folder named after the gate or the library would put
# push, merge or payload into the payload's cwd and so into every command's raw text.
# Under a HOME of the gate copy's own, as run_judged below does, so whatever a gate records by
# default under ~/.claude (the record of wrapped command refusals among them) lands in the
# throwaway. Without it, a direct run of this suite, where run-all-tests.sh has exported no throwaway
# record, wrote two "eval, reader-lib-missing" refusals into the Mac's real one every time (#2126).
# The record's own override is cleared so the refusal lands under that HOME however the suite is run.
run_gate(){ # run_gate <gate copy> <command> <cwd> -> OUT and RC
  local home
  home="$(dirname "$1")/home"
  mkdir -p "$home"
  case "$2" in
    @*) fixture_payload "$2" "$(dirname "$1")" > "$WORK/in.json" ;;
    *) payload_for "$2" "$3" > "$WORK/in.json" ;;
  esac
  # fresh-worktree-base-gate.sh keeps its per session record under TMPDIR by default; under that HOME
  # too, so no run leaves one on the Mac.
  OUT="$( cd "$3" && env -u WRAPPED_REFUSAL_LEDGER_DIR HOME="$home" FRESH_WORKTREE_STATE_DIR="$home/fresh-worktree-state" bash "$1" < "$WORK/in.json" 2>&1 )"; RC=$?
}
n=0
for g in "${GATES[@]}"; do
  # Only a library the gate needs: one it sources as optional is not taken away here. One it loads
  # with an examined stand in is taken away in the last section instead (#2634).
  libs="$(libs_of "$DIR/$g" gate)"
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
    # The refusal it records lands in this run's own HOME, never in the Mac's real record of wrapped
    # command refusals, which a direct run of this suite used to fill with these fixtures (#2126).
    if [ "$g" = check-wrapped-commands.sh ]; then
      if grep -q -F 'reader-lib-missing' "$T/home/.claude/state/wrapped-commands/refusals.tsv" 2>/dev/null; then ok
      else bad "$g with lib/$lib missing: its refusal should be recorded under the run's own HOME ($T/home), so a direct run of this suite never writes the real record (#2126); nothing was recorded there"; fi
    fi
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
# in text mode under a UTF-8 locale raises on a byte that is not UTF-8.
bad_byte_measured python-stdin "#1900 python3 text mode stdin on a byte that is not UTF-8" && ok
# And the form every reader uses reads it.
if [ "$(printf 'a\xffb' | LC_ALL="$BAD_BYTE_LOCALE" python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace")))')" = "3" ]; then ok
else bad "sys.stdin.buffer.read().decode(\"utf-8\", \"replace\") did not read a byte that is not UTF-8 as one character"; fi

# Text mode stdin: .read(), iterating it, json.load on it, or handing it on as a file.
TEXT_RE='sys\.stdin\.read\(|json\.load\(sys\.stdin\)|in sys\.stdin([^.]|$)|return sys\.stdin[[:space:]]*$|sys\.stdin\.readline'
text_reads(){ # text_reads <file>... -> file:line of each text mode read of stdin
  grep -n -E "$TEXT_RE" "$@" 2>/dev/null
}
# The hooks, and every script under payload/skills, which reads gh's answers the same way (#1923).
files=()
for f in "$DIR"/*.sh "$DIR"/*.py "$DIR"/lib/*.sh "$DIR"/lib/*.py; do
  case "$(basename "$f")" in test-*|test_*) continue ;; esac
  files+=("$f")
done
nhooks="${#files[@]}"
# Only what the sync carries: lib/unmanaged-skills.sh is the one list of what it leaves alone (#2001).
. "$DIR/lib/unmanaged-skills.sh" && declare -F carried_skill_paths >/dev/null || {
  echo "FAIL: $(basename "$0"): lib/unmanaged-skills.sh is missing or holds no carried_skill_paths, so the stdin scan cannot tell a skill the sync carries from one it leaves alone."
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$((fail + 1))"
  exit 1
}
skill_scripts(){ # skill_scripts <skills dir> -> each script there the stdin scan reads
  find "$1" -name fixtures -prune -o -type f \( -name '*.sh' -o -name '*.py' \) ! -name 'test-*' ! -name 'test_*' -print 2>/dev/null \
    | carried_skill_paths "$1" | sort
}
# Read into a variable first, never through process substitution, whose child bash 3.2 never waits
# for and whose exit can cut short what this suite prints next (L1035, #1989).
skill_list="$(skill_scripts "$DIR/../skills")"
while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<SKILL_LIST
$skill_list
SKILL_LIST
[ "$(( ${#files[@]} - nhooks ))" -ge 20 ] && ok || bad "only $(( ${#files[@]} - nhooks )) scripts were found under $DIR/../skills, so the stdin scan is not reading the skills"
hits="$(text_reads "${files[@]}" | sed "s#^$DIR/##")"
if [ -z "$hits" ]; then ok; else bad "a python3 reader takes stdin in text mode, which raises on a byte jq reads as U+FFFD; read sys.stdin.buffer and decode with errors=\"replace\":
$hits"; fi
printf '%s\n' '    d = json.load(sys.stdin)' 'for line in sys.stdin:' 'x = sys.stdin.read()' > "$WORK/probe-py"
[ "$(text_reads "$WORK/probe-py" | wc -l | tr -d ' ')" = "3" ] && ok || bad "the stdin scan does not fire on each of the three shapes the hooks held"
printf '%s\n' 'x = sys.stdin.buffer.read().decode("utf-8", "replace")' > "$WORK/probe-py2"
[ -z "$(text_reads "$WORK/probe-py2")" ] && ok || bad "the stdin scan fires on the buffered read it asks for"

# Run from the installed copy, the skills folder also holds what the sync never carries: the Claude
# app's downloads under skills/synced and Claude Code's skills/.trash (claude-config#2001). A reader
# there is nobody's to fix, so the scan leaves out exactly what lib/unmanaged-skills.sh says the sync
# leaves out, and still reads the same script in a real skill, including one inside a folder of the
# real skill that merely happens to be called synced.
for d in synced/acct/skill-a/scripts .trash/stamp/skill-a/scripts real-skill/scripts real-skill/synced real-skill/.trash/old; do
  mkdir -p "$WORK/skills/$d"
  printf '%s\n' 'import sys' 'x = sys.stdin.read()' > "$WORK/skills/$d/reader.py"
done
got="$(skill_scripts "$WORK/skills" | sed "s#^$WORK/skills/##" | tr '\n' ' ')"
[ "$got" = "real-skill/scripts/reader.py real-skill/synced/reader.py " ] && ok \
  || bad "#2001 the stdin scan should read the real skill's scripts and nothing under skills/synced or any .trash, read: $got"
skill_hits=()
skill_list="$(skill_scripts "$WORK/skills")"
while IFS= read -r f; do [ -n "$f" ] && skill_hits+=("$f"); done <<SKILL_LIST
$skill_list
SKILL_LIST
[ "$(text_reads ${skill_hits[@]+"${skill_hits[@]}"} | wc -l | tr -d ' ')" = 2 ] && ok \
  || bad "#2001 the stdin scan should still report the text mode reader in each of the real skill's two scripts"

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
  # issue-spool-session-end.sh is not here: it runs on SessionEnd, which discards a systemMessage,
  # so it declares a fallback for each library instead, and test-session-end-notice.sh runs it with
  # each one gone (claude-config#1949).
  declare_advisory sync-stuck-notice.sh    UserPromptSubmit "-"
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
    # "did not run", or "could not load", which is how payload-revert-warning.sh says it (#1924).
    v="$(hook_notice_verdict "$OUT" '(?i)did not run|could not load' 2>&1)"
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
  judged check-work-names-merge.sh    Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged check-work-names-publish.sh  Bash "$(bash_call 'gh pr create --title T --body B')" '{}' refuse
  judged require-verification-run.sh  Bash "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged require-issue-fields.sh      Bash "$(bash_call "gh issue create --title 'x' --body 'y'")" '{}' refuse
  judged linux-sections-before-push.sh Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged scanners-before-push.sh      Bash "$(bash_call 'git push origin feature')" '{}' refuse
  judged check-add-scope.sh           Bash "$(bash_call 'git add -A')" '{}' refuse
  judged no-verify-gate.sh            Bash "$(bash_call 'git commit --no-verify -m wip')" "$AGENT" refuse
  judged amend-force-push-gate.sh     Bash "$(bash_call 'git commit --amend -m wip')" "$AGENT" refuse
  judged temp-worktree-gate.sh        Bash "$(bash_call 'git worktree add /tmp/wt-2528 -b fix/2528')" '{}' refuse
  judged check-gh-watch-interval.sh   Bash "$(bash_call 'gh run watch 5')" '{}' "notice #1912"
  judged check-rtk-init.sh            Bash "$(bash_call 'rtk init -g')" '{}' refuse
  # In zsh -c, so it is refused whatever shell runs this suite (bash on the Linux runner).
  judged check-zsh-builtins.sh        Bash "$(bash_call "zsh -c 'log show --last 1m'")" '{}' refuse
  judged check-wrapped-commands.sh    Bash "$(bash_call 'eval $CMD && git status')" '{}' refuse
  judged stacked-branch-delete-gate.sh Bash "$(bash_call 'git push origin :feat/x')" '{}' refuse
  # Five gates let a call they cannot parse through, saying so, by the decision each records in its
  # header: refusing there takes away the scratchpad, the hand-back or a browser with no remedy
  # inside the session, since what makes a payload unparseable is not something the agent can change.
  judged scratchpad-subagent-gate.sh  Write '{"file_path": "/private/tmp/claude-501/proj/sess/scratchpad/notes.md", "content": "cut @@", "description": "cut @@"}' "$AGENT" "notice scratchpad-subagent-gate.sh header"
  judged monitor-action-gate.sh       Monitor "$(bash_call 'gh pr merge 5 --squash')" '{}' refuse
  judged handback-claims-gate.sh      SubagentHandback '{"message": "Done. No --no-verify, no overrides. cut @@", "description": "cut @@"}' "{\"agent_id\": \"a1b2c3d4\", \"agent_transcript_path\": \"$WORK/hb/agent.jsonl\"}" "notice handback-claims-gate.sh header"
  # It only tightens, and a session cannot change a payload Claude Code wrote, so refusing the edit
  # would stop work with no remedy (#2517).
  judged fresh-worktree-base-gate.sh  Edit '{"file_path": "/nonexistent-2517/notes-@@.md", "old_string": "cut @@", "new_string": "b"}' '{}' "notice fresh-worktree-base-gate.sh header"
  judged playwright-subagent-gate.sh  mcp__playwright__browser_navigate '{"url": "https://example.com/@@", "description": "cut @@"}' "$AGENT" "notice playwright-subagent-gate.sh header"
  judged chrome-subagent-tab-gate.sh  mcp__claude-in-chrome__navigate '{"url": "https://example.com/@@", "description": "cut @@"}' "$AGENT" "notice chrome-subagent-tab-gate.sh header"
  judged chrome-loopback-post-gate.sh mcp__claude-in-chrome__javascript_tool '{"text": "fetch(\"http://127.0.0.1:8765/@@\", {method: \"POST\", body: \"cut @@\"})", "action": "javascript_exec", "tabId": 7}' '{}' "notice chrome-loopback-post-gate.sh header"
  judged no-session-link-in-comments.sh Bash "$(bash_call "gh pr comment 5 --body 'see https://claude.ai/code/session_01abc'")" '{}' refuse
  judged slack-drafts-only-gate.sh    Bash "$(bash_call 'curl -d x https://slack.com/api/chat.postMessage')" '{}' refuse
  # It never refuses: it ASKS Dan about a database call it cannot classify, by Dan's decision on
  # 2026-11-09 (#2521), so a call it cannot parse is asked about, naming the payload.
  judged db-write-ask.sh mcp__claude_ai_Supabase__execute_sql '{"query": "update runs set note = '"'"'@@'"'"' where false", "project_id": "probe"}' '{}' "ask db-write-ask.sh header"
  # And about a database client in a shell command it cannot parse (#2536).
  judged db-write-ask.sh              Bash "$(bash_call "psql -c 'delete from runs where false'")" '{}' "ask db-write-ask.sh header"
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
# Three shapes that parse as JSON and still cannot be read as a call (claude-config#2057): the field
# the gate judges (the first one in the tool's input) as a list of its words, the whole input as one
# JSON string, and the whole payload inside a list. Each holds the judged call's every word.
ti = d["tool_input"]
key = next(iter(ti))
if how == "listfield":
    ti[key] = str(ti[key]).split()
elif how == "tistring":
    d["tool_input"] = json.dumps(ti)
text = json.dumps([d] if how == "toplist" else d).replace("@@", mark)
if how == "cut":
    text = text[:-1]
elif how == "empty":
    text = ""
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
# Started by a subshell that ends at once and writes nowhere, its pid recorded, so it is never this
# suite's child: one that ran out while a check was printing would cut the line short on bash 3.2
# (L1035, #2040).
( bash -c 'exec -a "'"$WORK"'/src/claude-sync watch" sleep 600' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$WORK/watch.pid" ) </dev/null >/dev/null 2>&1
WATCH_PID="$(cat "$WORK/watch.pid" 2>/dev/null)"
trap 'kill "$WATCH_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WATCH_PID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
export SYNC_WATCH_PID_FILE="$WORK/watch.pid" SYNC_HOLD_FILE="$WORK/no-hold"
# run_judged <run dir> <gate> <payload file> [<hooks folder>]: the gate in its own HOME and repo,
# bounded, and its decision as one line: the exit code, any permissionDecision, and whether it said
# anything. The gate is the one beside this suite unless a copy of the hooks is named.
run_judged(){
  local R="$1" said decision
  mkdir -p "$R/home" "$R/repo"
  ( cd "$R/repo" && git init -q . 2>/dev/null )
  bounded_run 60 env HOME="$R/home" PATH="$WORK/bin:$PATH" CLAUDE_DETACHED_RUN= \
    bash -c 'cd "$1" && exec bash "$2" < "$3" 2> "$4"' _ "$R/repo" "${4:-$DIR}/$2" "$3" "$R/err"
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
# What a gate does with a call it cannot parse, by its row: refuse it, let it through saying so, or
# ask. decided_as <unread> <decision line> is true when the decision is the one the row names.
UNREAD_SAID_RE='(?i)did not run|not judged|could not (read|judge|parse)|unread'
decided_as(){
  case "$1" in
    refuse) case "$2" in "exit 2,"*|*"decision deny"*) return 0 ;; esac ;;
    notice*) [ "$2" = "exit 0, decision none, said something" ] && return 0 ;;
    ask*) case "$2" in "exit 0, decision ask,"*) return 0 ;; esac ;;
  esac
  return 1
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
  for c in listfield tistring toplist empty; do
    mkdir -p "$R/$c"; judged_payload "$tool" "$inp" "$extra" 'Q' "$R/$c/repo" "$c" > "$R/$c.json"
  done
  mkdir -p "$R/olist"; judged_payload Bash '{"command": "ls -la"}' '{}' '' "$R/olist/repo" listfield > "$R/olist.json"
  ( for c in esc plain cut other listfield tistring toplist empty olist; do run_judged "$R/$c" "$g" "$R/$c.json"; done ) &
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
      decided_as "$unread" "$cutd" && ok || bad "$g let a call it could not parse through although its raw text names what it judges ($cutd): ${cut:0:200}"
      case "$cut" in *payload*|*Payload*) ok ;; *) bad "$g refused a call it could not parse without naming the payload as the reason: ${cut:0:200}" ;; esac ;;
    notice*)
      decided_as "$unread" "$cutd" && ok || bad "$g, which lets a call it cannot parse through by recorded decision (${unread#notice }), should allow it and say so ($cutd): ${cut:0:200}"
      v="$(hook_notice_verdict "$(cat "$R/cut/stdout" 2>/dev/null)" "$UNREAD_SAID_RE" 2>&1)"
      [ -z "$v" ] && ok || bad "$g let a call it could not parse through without saying so in a systemMessage: $v" ;;
    ask*)
      decided_as "$unread" "$cutd" && ok || bad "$g, which asks Dan about a call it cannot classify (${unread#ask }), let one it could not parse through without asking ($cutd): ${cut:0:200}"
      case "$cut" in *payload*|*Payload*) ok ;; *) bad "$g asked about a call it could not parse without naming the payload as the reason: ${cut:0:200}" ;; esac ;;
  esac
  otherd="$(cat "$R/other/decision" 2>/dev/null)"
  case "$otherd" in "exit 0, decision none"*) ok ;; *) bad "$g refused an unrelated call it could not parse ($otherd): $(head -c 200 "$R/other/said" 2>/dev/null)" ;; esac
  # JSON that parses into a shape no gate can read as a call (claude-config#2057): a gate that
  # refuses what it cannot parse refuses each, and one that lets it through by recorded decision
  # refuses or says so, and none lets it through in silence. The gate decides from every word the
  # payload holds, so a list of words reads as the command they make.
  for c in listfield tistring toplist; do
    cd_="$(cat "$R/$c/decision" 2>/dev/null)"; cs="$(cat "$R/$c/said" 2>/dev/null)"
    case "$unread" in
      refuse)
        case "$cd_" in "exit 2,"*|*"decision deny"*) ok ;; *) bad "#2057 $g let a call whose payload parses as JSON it cannot read ($c) through, though every word of what it judges is in it ($cd_): ${cs:0:200}" ;; esac ;;
      notice*)
        case "$cd_" in "exit 2,"*|*"decision deny"*|"exit 0, decision none, said something") ok ;; *) bad "#2057 $g let a call whose payload parses as JSON it cannot read ($c) through without saying so ($cd_): ${cs:0:200}" ;; esac ;;
      ask*)
        case "$cd_" in "exit 0, decision ask,"*) ok ;; *) bad "#2057 $g let a call whose payload parses as JSON it cannot read ($c) through without asking ($cd_): ${cs:0:200}" ;; esac ;;
    esac
  done
  # An empty payload names nothing, so by #1922's recorded decision it passes as any call naming
  # nothing does: refusing it would refuse every call and be a gate nobody keeps (L36).
  ed="$(cat "$R/empty/decision" 2>/dev/null)"
  case "$ed" in "exit 0, decision none"*) ok ;; *) bad "#2057 $g refused an empty payload, which names nothing it judges ($ed): $(head -c 200 "$R/empty/said" 2>/dev/null)" ;; esac
  od="$(cat "$R/olist/decision" 2>/dev/null)"
  case "$od" in "exit 0, decision none"*) ok ;; *) bad "#2057 $g refused an unrelated call whose command came as a list of words ($od): $(head -c 200 "$R/olist/said" 2>/dev/null)" ;; esac
done < "$WORK/judged"

# ---------------------------------------------------------------------------
echo "a gate decides alike without a library it loads with a stand in (claude-config#2634)"

# The first section takes away only what a gate needs, so a library loaded with an examined stand
# in was run with it gone nowhere, and "the stand in decides nothing" was a sentence in a comment.
# Each blocking gate is run here from a copy of the hooks with that one library gone, beside a whole
# copy, so the two differ in the library and nothing else: its judged call must be decided alike,
# the same call cut short must still be refused, said or asked about as its row says, and an
# unrelated call must pass.
copy_hooks(){ # copy_hooks <dest>: the hooks as they are installed
  mkdir -p "$1" && cp -R "$DIR/." "$1/"
}
# standin_runs <folder> <gate> <tool> <input> <extra> <whole copy> <copy without the library>
standin_runs(){
  local S="$1" c
  mkdir -p "$S"
  judged_payload "$3" "$4" "$5" 'Q' "$S/with/repo" whole > "$S/with.json"
  judged_payload "$3" "$4" "$5" 'Q' "$S/whole/repo" whole > "$S/whole.json"
  judged_payload "$3" "$4" "$5" '' "$S/cut/repo" cut > "$S/cut.json"
  judged_payload Bash '{"command": "ls -la"}' '{}' '' "$S/other/repo" cut > "$S/other.json"
  # Each run's records in a folder of its own, wherever the runner pointed them (lib/suite-isolation.sh),
  # so the two arms' can be read side by side below.
  WRAPPED_REFUSAL_LEDGER_DIR="$S/with/ledger" PUSH_GATE_LEDGER_DIR="$S/with/ledger" run_judged "$S/with" "$2" "$S/with.json" "$6"
  for c in whole cut other; do
    WRAPPED_REFUSAL_LEDGER_DIR="$S/$c/ledger" PUSH_GATE_LEDGER_DIR="$S/$c/ledger" run_judged "$S/$c" "$2" "$S/$c.json" "$7"
  done
}
# The Mac each line of a run's records names: the second field of both records a gate keeps.
macs_recorded(){ # macs_recorded <run folder>
  cat "$1"/ledger/*.tsv 2>/dev/null | cut -f2
}
# standin_verdict <folder> <unread>: each way the gate decided otherwise with the library gone, or
# nothing.
standin_verdict(){
  local S="$1" with gone cutd otherd v
  with="$(cat "$S/with/decision" 2>/dev/null)"; gone="$(cat "$S/whole/decision" 2>/dev/null)"
  cutd="$(cat "$S/cut/decision" 2>/dev/null)"; otherd="$(cat "$S/other/decision" 2>/dev/null)"
  case "$with" in ''|"exit 124"*) printf 'with every library in place its judged call came to no decision (%s), so there is nothing to compare; ' "${with:-no run}" ;; esac
  [ "$gone" = "$with" ] || printf 'it decides its judged call differently (%s) than with the library in place (%s), and said: %s; ' "${gone:-no run}" "${with:-no run}" "$(head -c 200 "$S/whole/said" 2>/dev/null)"
  decided_as "$2" "$cutd" || printf 'the same call cut short is decided "%s" where its row says %s, and it said: %s; ' "${cutd:-no run}" "$2" "$(head -c 200 "$S/cut/said" 2>/dev/null)"
  case "$2" in notice*)
    v="$(hook_notice_verdict "$(cat "$S/cut/stdout" 2>/dev/null)" "$UNREAD_SAID_RE" 2>&1)"
    [ -z "$v" ] || printf 'it let the call cut short through without saying so in a systemMessage (%s); ' "$v" ;;
  esac
  case "$otherd" in "exit 0, decision none"*) ;; *) printf 'it does not pass an unrelated call (%s): %s; ' "${otherd:-no run}" "$(head -c 200 "$S/other/said" 2>/dev/null)" ;; esac
}

# Every blocking gate and each library it loads with an examined stand in, with the call its row
# in the table above judges.
: > "$WORK/standin-pairs"
m=0
while IFS=$'\t' read -r g tool inp extra unread; do
  for lib in $(standin_libs_of "$DIR/$g"); do
    m=$((m + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$m" "$g" "$lib" "$tool" "$inp" "$extra" "$unread" >> "$WORK/standin-pairs"
  done
done < "$WORK/judged"
# Twenty four on 2026-11-10: lib/hook-notice.sh under twenty gates, lib/this-mac.sh under four.
[ "$m" -ge 20 ] && ok || bad "#2634 only $m pairs of a blocking gate and a library it loads with an examined stand in were found, so the enumeration is reading the wrong thing"
copies_ok=1
copy_hooks "$WORK/hooks/whole" || copies_ok=0
for lib in $(cut -f3 "$WORK/standin-pairs" | sort -u); do
  copy_hooks "$WORK/hooks/without-$lib" && rm -f "$WORK/hooks/without-$lib/lib/$lib" || copies_ok=0
  [ -f "$WORK/hooks/whole/lib/$lib" ] && [ ! -e "$WORK/hooks/without-$lib/lib/$lib" ] || copies_ok=0
done
[ "$copies_ok" = 1 ] && ok || bad "#2634 the hooks could not be copied whole and with each stand in library gone under $WORK/hooks, so no gate was run without one"

# The check is seen to fail on a gate whose stand in lets a call through, and to pass the same gate
# with a stand in that does not (L1). Three canaries, each refusing every push it can read:
#   canary-said.sh   lets a push it cannot parse through saying so, with the stand in the library's
#                    header gives. Passes.
#   canary-quiet.sh  the same gate with a stand in that says nothing, so that push passes in
#                    silence with the library gone. Must fail.
#   canary-open.sh   names the Mac before it refuses, with a stand in that ends the gate, so every
#                    push passes with the library gone. Must fail.
canary(){ # canary <name> <library> <stand in line...>: a gate under $WORK/canary
  local name="$1" lib="$2"; shift 2
  { printf '%s\n' '#!/usr/bin/env bash' 'HOOK_DIR="${BASH_SOURCE[0]%/*}"'
    printf '%s\n' "$@"
    printf '%s\n' 'payload="$(cat)"' 'case "$payload" in *"git push"*) ;; *) exit 0 ;; esac'
    printf '%s\n' 'if ! printf "%s" "$payload" | python3 -c '"'"'import json, sys; json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))'"'"' 2>/dev/null; then'
    case "$lib" in
      hook-notice.sh) printf '%s\n' '  hook_allow_notice "CANARY DID NOT RUN: it could not read the hook payload, so this push was not judged."' ;;
      *) printf '%s\n' '  echo "REFUSED: the canary could not read the hook payload." >&2; exit 2' ;;
    esac
    printf '%s\n' 'fi'
    [ "$lib" = this-mac.sh ] && printf '%s\n' 'this_mac_name >/dev/null'
    printf '%s\n' 'echo "REFUSED: the canary refuses every push it can read." >&2' 'exit 2'
  } > "$WORK/canary/$name"
  cp "$WORK/canary/$name" "$WORK/hooks/whole/$name" && cp "$WORK/canary/$name" "$WORK/hooks/without-$lib/$name"
}
mkdir -p "$WORK/canary"
canary canary-said.sh hook-notice.sh \
  '. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing' \
  '  printf '"'"'%s\n'"'"' "$1" >&2' \
  '  printf '"'"'{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n'"'"' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }'
canary canary-quiet.sh hook-notice.sh \
  '. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() { exit 0; }'
canary canary-open.sh this-mac.sh \
  '. "$HOOK_DIR/lib/this-mac.sh" 2>/dev/null || this_mac_name() { exit 0; }'
PUSH_CALL="$(bash_call 'git push origin feature')"

# A few pairs at a time, as above, and waited on by pid.
pids=()
while IFS=$'\t' read -r i g lib tool inp extra unread; do
  ( standin_runs "$WORK/st$i" "$g" "$tool" "$inp" "$extra" "$WORK/hooks/whole" "$WORK/hooks/without-$lib" ) &
  pids+=("$!")
  if [ "${#pids[@]}" -ge 6 ]; then wait "${pids[@]}"; pids=(); fi
done < "$WORK/standin-pairs"
( standin_runs "$WORK/st-said" canary-said.sh Bash "$PUSH_CALL" '{}' "$WORK/hooks/whole" "$WORK/hooks/without-hook-notice.sh"
  standin_runs "$WORK/st-quiet" canary-quiet.sh Bash "$PUSH_CALL" '{}' "$WORK/hooks/whole" "$WORK/hooks/without-hook-notice.sh"
  standin_runs "$WORK/st-open" canary-open.sh Bash "$PUSH_CALL" '{}' "$WORK/hooks/whole" "$WORK/hooks/without-this-mac.sh" ) &
pids+=("$!")
wait "${pids[@]}"

why="$(standin_verdict "$WORK/st-said" "notice canary")"
[ -z "$why" ] && ok || bad "#2634 canary: a gate whose stand in says the notice as the library's header gives fails the check: $why"
why="$(standin_verdict "$WORK/st-quiet" "notice canary")"
case "$why" in *"cut short"*) ok ;; *) bad "#2634 canary: a gate whose stand in lets a call it cannot parse through in silence passes the check, so the check cannot see a stand in that allows quietly (it said: ${why:-nothing})" ;; esac
why="$(standin_verdict "$WORK/st-open" refuse)"
case "$why" in *"decides its judged call differently"*) ok ;; *) bad "#2634 canary: a gate whose stand in ends it before it refuses passes the check, so the check cannot see a stand in that lets the judged call through (it said: ${why:-nothing})" ;; esac

reached=0
while IFS=$'\t' read -r i g lib tool inp extra unread; do
  why="$(standin_verdict "$WORK/st$i" "$unread")"
  [ -z "$why" ] && ok || bad "#2634 $g with lib/$lib gone, which it loads with a stand in: $why"
  # Deciding alike proves little about a stand in the call never reached. Where the judged call
  # makes the gate record what it did, naming the Mac, the same record written with lib/this-mac.sh
  # gone names none, which is the stand in answering, and the decision above was made past it.
  [ "$lib" = this-mac.sh ] || continue
  named="$(macs_recorded "$WORK/st$i/with" | grep -c '[A-Za-z0-9]')"
  [ "$named" -gt 0 ] || continue
  reached=$((reached + 1))
  unnamed="$(macs_recorded "$WORK/st$i/whole" | grep -c -x -E '(unknown)?')"
  gone_records="$(cat "$WORK/st$i/whole/ledger"/*.tsv 2>/dev/null)"
  [ "$unnamed" -eq "$named" ] && ok \
    || bad "#2634 $g with lib/this-mac.sh gone: its judged call writes $named record line(s) naming the Mac with the library in place, and should write as many naming none through the stand in; it wrote $unnamed such line(s): ${gone_records:0:200}"
done < "$WORK/standin-pairs"
# Three of the four did on 2026-11-10 (scanners-before-push.sh records nothing on a push with
# nothing to scan). Not asked where this machine's name cannot be read at all, since the library's
# own answer is then the stand in's (L411).
if ( . "$DIR/lib/this-mac.sh" 2>/dev/null && this_mac_name >/dev/null 2>&1 ); then
  [ "$reached" -ge 1 ] && ok || bad "#2634 no gate's judged call reached this_mac_name, so deciding alike with lib/this-mac.sh gone shows nothing about its stand in"
fi

# Every PreToolUse hook registered without onFailure block is advisory by design, and each is named
# here with the reason, so a hook registered later is neither judged above nor exempt by being
# unlisted (L96, L129). Each runs on every unreadable shape and never refuses.
declare_advisory_pre(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
{
  declare_advisory_pre rtk-rewrite.sh      '{"command": "gh api repos/o/r"}' "rewrites a command to its rtk form and never refuses; a payload it cannot read is left as it came"
  declare_advisory_pre lessons-advisory.sh '{"command": "git push origin feature"}' "hands Claude the lessons a push matches and never refuses (its header: WHY ADVISORY AND NOT A GATE)"
  declare_advisory_pre read-only-query-allow.sh '{"command": "select 1"}' "approves a read only query or says nothing, and never refuses; a payload it cannot read goes to the usual permission check (#2343)"
} > "$WORK/advisory-pre"
while IFS= read -r g; do
  grep -q -x -F "$g" "$WORK/blocking" && continue
  if ! awk -F '\t' -v g="$g" '$1 == g { f = 1 } END { exit !f }' "$WORK/advisory-pre"; then
    bad "#2057 $g is a registered PreToolUse hook that is neither registered to block nor named as advisory by design in this suite, so nothing says what it does with a payload it cannot read"
    continue
  fi
  if grep -q -E 'exit 2|"deny"' "$DIR/$g"; then bad "#2057 $g is named advisory by design and holds a refusal"; else ok; fi
  inp="$(awk -F '\t' -v g="$g" '$1 == g { print $2 }' "$WORK/advisory-pre")"
  for c in listfield tistring toplist empty cut; do
    k=$((k + 1)); R="$WORK/a$k"; mkdir -p "$R"
    judged_payload Bash "$inp" '{}' 'Q' "$R/repo" "$c" > "$R/in.json"
    run_judged "$R" "$g" "$R/in.json"
    case "$(cat "$R/decision")" in "exit 0, decision none"*) ok ;; *) bad "#2057 advisory $g refused or failed on an unreadable payload ($c): $(cat "$R/decision")" ;; esac
  done
done < "$WORK/pre"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
