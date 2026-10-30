#!/usr/bin/env bash
# Every PreToolUse gate that can refuse a call is registered so that a gate Claude Code kills at its
# timeout BLOCKS the call rather than letting it through (claude-config#1899).
#
# Claude Code lets a PreToolUse call go ahead when a hook times out, crashes, cannot start or exits
# with any code other than 0 or 2, unless the hook is registered with "onFailure": "block" (hooks
# documentation, "Block the action when a hook fails"; measured on 2.1.312 on 2026-10-28 by the
# #1881 builder). Under load, which is when overruns happen, every gate without it failed open in
# silence. #1889 gave the scanners gate the field; this suite holds the rest to it.
#
# THE ONE PLACE THE CLASSIFICATION LIVES is the two lists below. Every PreToolUse hook in
# settings.hooks.json must be in exactly one of them, and a hook in none fails here, so a new hook
# cannot arrive unclassified and so unchecked (L96).
#
#   REFUSING   can refuse the call (exit 2, or a deny decision) and is registered with onFailure
#              block, so a killed or crashed gate is a refused call, never a passed one.
#   ADVISORY   never refuses: it only advises, rewrites or records. onFailure block would turn a slow
#              advisory hook into one that blocks work, so it must NOT carry it, and this suite also
#              checks the script holds no refusal, so a hook that starts refusing has to move.
#
# A gate that lets a call through because it could not judge says so with exit 0 and a JSON
# systemMessage (lib/hook-notice.sh, #1906, #1912), never exit 1, which onFailure block refuses.
# The four that used exit 1 for it (#735, #1065) moved off it in #1912 and are REFUSING now.
#
# Because onFailure block also blocks on ANY exit other than 0 or 2, a refusing gate that stumbles on
# an ordinary call would now block every call it is registered for. So each REFUSING gate is also
# run on an ordinary call for every tool its matcher names, and must exit 0 and print nothing that
# could be mistaken for broken JSON. The probe is seen to catch a stray exit 1 and a broken JSON
# line on stubs first (L1).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

REFUSING=(
  push-scope-notice.sh
  check-style-guide.sh
  check-grep-quiet-invert.sh
  check-duplication.sh
  check-deferrals.sh
  check-doc-issue-refs.sh
  check-bundle-budget.sh
  check-closing-keyword.sh
  block-red-merge.sh
  design-score-gate.sh
  pr-review-gate.sh
  pr-review-push-gate.sh
  require-changelog-tag.sh
  check-closing-merge.sh
  require-verification-run.sh
  require-issue-fields.sh
  linux-sections-before-push.sh
  scanners-before-push.sh
  payload-write-gate.sh
  check-add-scope.sh
  no-verify-gate.sh
  amend-force-push-gate.sh
  check-rtk-init.sh
  check-wrapped-commands.sh
  stacked-branch-delete-gate.sh
  scratchpad-subagent-gate.sh
  monitor-action-gate.sh
  handback-claims-gate.sh
  playwright-subagent-gate.sh
  no-session-link-in-comments.sh
  require-tests-before-push.sh
  simplify-before-push.sh
  check-public-assets.sh
  check-gh-watch-interval.sh
)

# Never refuses: rtk-rewrite.sh rewrites a command for rtk and passes every one through, and
# lessons-advisory.sh hands the push its matching lessons as context and exits 0 by design (its
# header: "ADVISORY, never blocking").
ADVISORY=(
  rtk-rewrite.sh
  lessons-advisory.sh
)

. "$DIR/lib/settings-file.sh" 2>/dev/null || { echo "FAIL: lib/settings-file.sh is missing beside this suite"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
REG="$(hook_settings_file "$DIR/..")" || REG=""
if [ -z "$REG" ] || ! command -v python3 >/dev/null 2>&1; then
  # Said out loud rather than skipped in silence (L98): with no hooks block there is nothing to judge.
  echo "FAIL: no settings.hooks.json or settings.json beside $DIR, or no python3, so no registration was checked"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# One line per PreToolUse registration: <script>\t<onFailure or ->\t<matcher>
ROWS="$(python3 - "$REG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for group in d.get("hooks", {}).get("PreToolUse", []):
    m = group.get("matcher", "")
    for h in group.get("hooks", []):
        cmd = h.get("command", "")
        script = cmd.split()[0].rsplit("/", 1)[-1] if cmd else ""
        print("%s\t%s\t%s" % (script, h.get("onFailure", "-"), m))
PY
)"

in_list(){ # in_list <name> <array items...>
  local n="$1"; shift
  local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1
}

# Code lines only, so a comment that names exit 1 or a deny decision is not read as one.
code_of(){ grep -v -E '^[[:space:]]*#' "$DIR/$1" 2>/dev/null; }

# --- every PreToolUse hook is classified, and every list entry is registered ---------------------
registered=()
while IFS=$'\t' read -r script onfail matcher; do
  [ -n "$script" ] || continue
  registered+=("$script")
  n=0
  in_list "$script" "${REFUSING[@]}" && n=$((n + 1))
  in_list "$script" "${ADVISORY[@]}" && n=$((n + 1))
  if [ "$n" -eq 1 ]; then ok
  else bad "#1899 $script (PreToolUse, matcher $matcher) is in $n of the lists in $(basename "$0"), not exactly one. Read its exit paths and put it in REFUSING (it can refuse) or ADVISORY (it never refuses)."
  fi

  if in_list "$script" "${REFUSING[@]}"; then
    [ "$onfail" = "block" ] && ok \
      || bad "#1899 $script can refuse the call but its registration (matcher $matcher) has onFailure=$onfail, so Claude Code lets the call through when it kills the gate at its timeout. Add \"onFailure\": \"block\" to it in settings.hooks.json."
  elif in_list "$script" "${ADVISORY[@]}"; then
    [ "$onfail" != "block" ] && ok \
      || bad "#1899 $script never refuses, but its registration has onFailure block, so a slow or failed advisory run would now block the call. Remove it, or move the hook to REFUSING if it now refuses."
  fi
done <<< "$ROWS"

for s in "${REFUSING[@]}" "${ADVISORY[@]}"; do
  in_list "$s" "${registered[@]}" && ok \
    || bad "#1899 $s is listed in $(basename "$0") but registered for no PreToolUse event, so the list is stale. Take it out."
done

# --- each list's reason is still true of the script ----------------------------------------------
REFUSAL_RE='exit 2|permissionDecision.{0,12}deny|"decision"[[:space:]]*:[[:space:]]*"block"'
# The code is read into a variable before it is matched, never piped into grep -q, which can stop
# reading early and make the producer fail under pipefail (test-pipefail-shortcircuit.sh).
for s in "${ADVISORY[@]}"; do
  code="$(code_of "$s")"
  hit="$(grep -m1 -o -E "$REFUSAL_RE" <<< "$code")"
  if [ -n "$hit" ]; then
    bad "#1899 $s is listed as never refusing, but its code holds a refusal ($hit). Move it to REFUSING and give its registration onFailure block."
  else ok; fi
done

# --- the ordinary call probe ---------------------------------------------------------------------
# payloads <matcher> <agent id or empty>: one PreToolUse payload per line, one per tool the matcher
# names. A matcher alternative with no sample tool is printed as NOSAMPLE so it fails, never skipped.
payloads(){
  python3 - "$1" "$2" "$WORK" <<'PY'
import json, re, sys
matcher, agent, work = sys.argv[1], sys.argv[2], sys.argv[3]
samples = {
    "Bash": {"command": "ls"},
    "Edit": {"file_path": work + "/probe.txt", "old_string": "a", "new_string": "b"},
    "Write": {"file_path": work + "/probe.txt", "content": "a"},
    "MultiEdit": {"file_path": work + "/probe.txt", "edits": [{"old_string": "a", "new_string": "b"}]},
    "NotebookEdit": {"notebook_path": work + "/probe.ipynb", "new_source": "a"},
    "Monitor": {"command": "ls", "description": "probe"},
    "SubagentHandback": {"message": "Done."},
    "mcp__playwright__browser_snapshot": {},
    "mcp__plugin_playwright_playwright__browser_snapshot": {},
    "mcp__plugin_slack_slack__slack_send_message": {"channel_id": "C0", "message": "hello"},
}
def top_level_alternatives(rx):
    # Split on the bars outside any group, so "a|b_(c|d)" is two alternatives, not three.
    out, depth, cur = [], 0, ""
    for ch in rx:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "|" and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out

seen = set()
for alt in top_level_alternatives(matcher or ".*"):
    hits = [t for t in samples if re.fullmatch(alt, t)]
    if not hits:
        print("NOSAMPLE\t" + alt)
        continue
    for t in hits[:1]:
        if t in seen:
            continue
        seen.add(t)
        p = {"session_id": "probe", "transcript_path": work + "/none.jsonl", "cwd": work,
             "hook_event_name": "PreToolUse", "tool_name": t, "tool_input": samples[t]}
        if agent:
            p["agent_id"] = agent
            p["agent_transcript_path"] = work + "/none-agent.jsonl"
        print(t + "\t" + json.dumps(p))
PY
}

# probe <script path> <payload> <allowed codes, e.g. "0" or "0 2">: prints why it would fail, or nothing.
probe(){
  local out rc
  out="$(cd "$WORK" && printf '%s' "$2" | HOME="$WORK/home" bash "$1" 2>/dev/null)"; rc=$?
  case " $3 " in *" $rc "*) ;; *) echo "exited $rc"; return ;; esac
  case "$out" in
    '{'*) printf '%s' "$out" | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null \
      || echo "printed output that starts like JSON and does not parse: ${out:0:200}" ;;
  esac
}
mkdir -p "$WORK/home"

# The probe is seen to fail first, on stubs, so a quiet probe means the gates passed (L1).
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$WORK/stub-exit1.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "{not json"\nexit 0\n' > "$WORK/stub-badjson.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$WORK/stub-clean.sh"
sample="$(payloads Bash "" | cut -f2-)"
[ -n "$(probe "$WORK/stub-exit1.sh" "$sample" "0")" ] && ok || bad "#1899 canary: the probe did not catch a gate that exits 1 on an ordinary call"
[ -n "$(probe "$WORK/stub-badjson.sh" "$sample" "0")" ] && ok || bad "#1899 canary: the probe did not catch a gate that prints broken JSON"
[ -z "$(probe "$WORK/stub-clean.sh" "$sample" "0")" ] && ok || bad "#1899 control: the probe failed a stub that exits 0 in silence"
[ -n "$(payloads 'NoSuchTool' "" | grep '^NOSAMPLE')" ] && ok || bad "#1899 canary: a matcher naming a tool with no sample was not reported"

probed=0
while IFS=$'\t' read -r script onfail matcher; do
  in_list "$script" "${REFUSING[@]}" || continue
  for agent in "" "probe-agent"; do
    # The main session's ordinary call must pass. A subagent's may be refused (the Playwright gate
    # refuses every one), but never fail any other way.
    allowed="0"; who="the main session"
    [ -n "$agent" ] && { allowed="0 2"; who="a subagent"; }
    # A matcher the sample builder cannot read is a failure, never a gate quietly left unprobed (L98).
    calls="$(payloads "$matcher" "$agent" 2>&1)" \
      || { bad "#1899 $script: the matcher '$matcher' could not be read to build sample calls: ${calls:0:300}"; continue; }
    [ -n "$calls" ] || { bad "#1899 $script: no sample call was built for the matcher '$matcher'"; continue; }
    while IFS=$'\t' read -r tool p; do
      if [ "$tool" = NOSAMPLE ]; then
        bad "#1899 $script: its matcher alternative '$p' names no tool this suite has a sample call for. Add one to payloads() so the gate is probed."
        continue
      fi
      probed=$((probed + 1))
      why="$(probe "$DIR/$script" "$p" "$allowed")"
      [ -z "$why" ] && ok \
        || bad "#1899 $script, registered with onFailure block, $why on an ordinary $tool call from $who, so Claude Code would block every such call. Make that path exit 0."
    done <<< "$calls"
  done
done <<< "$ROWS"

# Judged by the count it ran (L288): every refusing gate is probed at least once from the main
# session and once from a subagent, so fewer probes than that means some gate was never run.
if [ "$probed" -ge $(( ${#REFUSING[@]} * 2 )) ]; then ok
else bad "#1899 only $probed ordinary calls were probed for ${#REFUSING[@]} refusing gates, fewer than two each, so some gate was never run"
fi
echo "  probed $probed ordinary calls across ${#REFUSING[@]} refusing gates"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
