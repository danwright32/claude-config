#!/usr/bin/env bash
#
# push-changes.sh: what a push carries, for the two model judged push gates (claude-config#1076),
# and the record of what each gate did with it (claude-config#1075).
#
# Sourced, never executed, after lib/push-scope.sh, whose readers it uses and never repeats.
# require-tests-before-push.sh and simplify-before-push.sh each resolved the pushed range, folded in
# the pending commit, built a diff under their own copy of one exclude list and launched their own
# copy of one judge call. The copies had already drifted, and both drifts were silent:
#   - the test gate meant to show the judge every NEW file the command's commit takes, and tested a
#     variable it never set, so a test written in the same command reached the judge as a file name
#     and none of its text;
#   - both asked git for paths relative to the root while git read them from the directory the push
#     ran in, so a push from a subdirectory showed the judge nothing outside it, and the gate let it
#     through unjudged, exactly like a push it had approved.
# One copy now, which every gate calls:
#
#   pc_resolve <cmd>      which files the push carries, and from where (sets PC_* below)
#   pc_diff <pathspec>..  the diff of what the push carries, limited to the pathspecs
#   pc_messages           the subjects of the commits it carries
#   pc_judge ...          one isolated model call, its envelope read, its failures named
#   pc_record ...         one line in the ledger of what the gate did
#
# pc_resolve and pc_judge set globals, so they are called in the gate's own shell, never inside a
# command substitution, where what they set would be lost with the subshell.

# Never shown to a judge: generated, locked, minified or binary content, which says nothing about
# the change and spends the budget. One list for every gate (it was two copies).
PC_EXCLUDES=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.snap'
  ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.svg'
  ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif')

# ---- which files the push carries ----
# Run in the directory the push runs in (ps_repo_dir's answer). Sets:
#   PC_UPSTREAM        the branch's upstream, empty when it has none
#   PC_BASE            the ref the push is judged against (ps_base_ref)
#   PC_MB              where the committed range starts, empty when no range is read
#   PC_COMMIT_IN_CHAIN 1 when the command commits before it pushes
#   PC_WIDENED         1 when the command's git add could not be read and the whole working tree
#                      was counted instead; a refusal must say so (lib/push-scope.sh, #457)
#   PC_FILES           the files, one per line, relative to the repository root
# and moves the shell to the repository root, which every path above is relative to.
#
# Returns 0 when the push carries files, 1 when it carries none with an upstream to compare against
# (a correct, quiet verdict), and 2 when it carries none and there is no upstream: the base may have
# fallen back to the current commit, so "nothing" is the gate being blind, not the push being empty
# (#736), and the caller must say so.
pc_resolve() {   # $1 = command
  local pending_list top f
  PC_UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  PC_BASE="$(ps_base_ref)"
  PC_COMMIT_IN_CHAIN=0
  ps_commit_in_chain "$1" && PC_COMMIT_IN_CHAIN=1

  # Where the committed range starts, from the shared contract in lib/push-scope.sh, ps_pending_base
  # for a plain push too: against a REMOTE base a merge base at HEAD means the push carries no
  # commit, and the plain push helper would re-read the last commit already on the remote. Except
  # the case #736 records: no upstream, and the base fell back to a local branch that IS the current
  # commit. The last commit is then not a measurement of what the push adds, so no range is read.
  PC_MB=""
  local base_is_head=0
  if [ -z "$PC_UPSTREAM" ] && [ -n "$PC_BASE" ]; then
    case "$(git rev-parse --symbolic-full-name "$PC_BASE" 2>/dev/null)" in
      refs/remotes/*) : ;;
      *) [ "$(git rev-parse --verify --quiet "$PC_BASE" 2>/dev/null)" = "$(git rev-parse --verify --quiet HEAD 2>/dev/null)" ] && base_is_head=1 ;;
    esac
  fi
  [ "$base_is_head" -eq 1 ] || PC_MB="$(ps_pending_base "$PC_BASE")"

  local committed="" pending=""
  [ -n "$PC_MB" ] && committed="$(git diff --name-only --diff-filter=ACMR "$PC_MB" HEAD 2>/dev/null)"

  # The PENDING files when the command commits before it pushes: the index, plus what the shared
  # reader says the commit takes beyond it (#457), counting only files that exist. Read here, in the
  # directory the command runs in, because the paths its git add names are relative to it.
  PC_WIDENED=0; PC_PENDING_ALL=""
  if [ "$PC_COMMIT_IN_CHAIN" -eq 1 ]; then
    pending="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)"
    pending_list="$(ps_pending_files "$1")"
    [ "${pending_list%%$'\n'*}" = "WIDENED" ] && PC_WIDENED=1
    # Every path the commit takes beyond the index, deletions included, for pc_push_tree.
    PC_PENDING_ALL="$(printf '%s\n' "$pending_list" | tail -n +2)"
    top="$(git rev-parse --show-toplevel 2>/dev/null)"
    while IFS= read -r f; do
      [ -n "$f" ] && [ -e "$top/$f" ] || continue
      pending="$pending
$f"
    done < <(printf '%s\n' "$pending_list" | tail -n +2)
  fi

  PC_FILES="$(printf '%s\n%s\n' "$committed" "$pending" | sed '/^$/d' | sort -u)"
  # Every path from here on is relative to the root, so the shell stands there.
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] && cd "$top" 2>/dev/null
  if [ -z "$PC_FILES" ]; then
    [ -z "$PC_UPSTREAM" ] && return 2
    return 1
  fi
  return 0
}

# ---- the diff of what the push carries ----
# The committed range, then the pending commit's changes to tracked files, then each NEW file the
# pending commit takes (untracked now, so no diff shows it) as a diff against nothing, all limited
# to the pathspecs and the shared excludes. Only files in PC_FILES are added as new, so an untracked
# file the command's git add does not take is never shown as part of the push. Pathspecs are
# relative to the repository root, where pc_resolve left the shell. PC_DIFF_CONTEXT, when set, is
# the lines of context around each change (git's -U), for a reader that needs the file around a
# line, as the test gate's docs-only check does (claude-config#1238); unset, git's default.
pc_diff() {   # $@ = pathspecs (a path, ".", or ":(exclude)..." items)
  local u
  local -a ctx=()
  [ -n "${PC_DIFF_CONTEXT:-}" ] && ctx=("-U$PC_DIFF_CONTEXT")
  [ -n "$PC_MB" ] && git diff ${ctx[@]+"${ctx[@]}"} "$PC_MB" HEAD -- "$@" "${PC_EXCLUDES[@]}" 2>/dev/null
  [ "${PC_COMMIT_IN_CHAIN:-0}" -eq 1 ] || return 0
  git diff ${ctx[@]+"${ctx[@]}"} HEAD -- "$@" "${PC_EXCLUDES[@]}" 2>/dev/null
  # One join against PC_FILES rather than a search per untracked file: a tree can hold hundreds of
  # untracked files the push has nothing to do with. The list goes in through the environment, never
  # as a first file, so an empty list cannot be mistaken for the stream (test-two-file-awk.sh).
  while IFS= read -r u; do
    [ -f "$u" ] || continue
    git diff --no-index -- /dev/null "$u" 2>/dev/null
  done < <(git ls-files --others --exclude-standard --full-name -- "$@" "${PC_EXCLUDES[@]}" 2>/dev/null \
             | PC_WANT="$PC_FILES" awk 'BEGIN { n = split(ENVIRON["PC_WANT"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 } ($0 in want)')
  return 0
}

# The subjects of the commits the push carries, bounded.
pc_messages() {
  local m
  m="$(git log --no-merges --format='- %s' "${PC_MB:-HEAD}"..HEAD 2>/dev/null)"
  printf '%s' "${m:0:4000}"
}

# ---- one judge call ----
# Runs the model isolated: an empty working directory and only `local` setting sources, so it does
# NOT inherit the user's hooks, CLAUDE.md memory, skills or MCP servers (those otherwise hijack the
# result). Keychain auth still works (no --bare).
#
# Measured, not assumed (claude-config#540, Claude Code 2.1.281, 2026-09-23): the same call from an
# empty directory took 14,802 input tokens with `--setting-sources local` and 56,808 without it, and
# asked whether its context held the line "L1001." it answered ABSENT with the flag and quoted the
# lesson without it. So the flag already keeps the global CLAUDE.md and the lessons index out, and
# each launch below carries the marker the headless launch guard reads instead of a second switch.
#
# Sets PC_JUDGE_OBJ to the JSON object the judge answered, compact, and returns 0. On any failure
# returns 1 with PC_JUDGE_ERR naming which one, in words a fail open notice can carry: no CLI, timed
# out (GNU timeout's 124, which is "too slow" rather than "down", and they have different fixes),
# returned nothing, an error envelope, or an answer that is not a JSON object. Never a verdict: the
# gate reads its own fields from the object. Also sets PC_JUDGE_MODEL, PC_JUDGE_START and
# PC_JUDGE_END (epoch seconds around the call), PC_JUDGE_MS and PC_JUDGE_COST (the envelope's own
# duration_ms and total_cost_usd, empty when it carried none) and PC_JUDGE_BYTES (the input's size).
pc_judge() {   # $1 = model  $2 = timeout seconds  $3 = system prompt (the rubric)  $4 = the input
  local tbin jtmp envelope status parsed
  PC_JUDGE_OBJ=""; PC_JUDGE_ERR=""; PC_JUDGE_MS=""; PC_JUDGE_COST=""
  # The model is named only once a call is launched, so a failure before that is never recorded as
  # a judge call (the report counts calls by it).
  PC_JUDGE_MODEL=""; PC_JUDGE_BYTES=${#4}; PC_JUDGE_START=""; PC_JUDGE_END=""
  if ! command -v claude >/dev/null 2>&1; then
    PC_JUDGE_ERR="judge unavailable: no claude CLI on PATH"; return 1
  fi
  # GNU `timeout` is absent on stock macOS (it ships as `gtimeout` via coreutils).
  tbin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  jtmp="$(mktemp -d)" || { PC_JUDGE_ERR="judge could not start: no scratch directory"; return 1; }
  PC_JUDGE_START="$(date +%s)"; PC_JUDGE_MODEL="$1"
  if [ -n "$tbin" ]; then
    # claude-mds-ok: --setting-sources local keeps the global config out, measured above (#540).
    envelope="$(printf '%s' "$4" | ( cd "$jtmp" && "$tbin" "$2" \
      claude -p --model "$1" --output-format json \
        --strict-mcp-config --setting-sources local --system-prompt "$3" ) 2>/dev/null )"
  else
    # claude-mds-ok: --setting-sources local keeps the global config out, measured above (#540).
    envelope="$(printf '%s' "$4" | ( cd "$jtmp" && \
      claude -p --model "$1" --output-format json \
        --strict-mcp-config --setting-sources local --system-prompt "$3" ) 2>/dev/null )"
  fi
  status=$?
  PC_JUDGE_END="$(date +%s)"
  rm -rf "$jtmp"
  if [ -z "$envelope" ]; then
    if [ "$status" -eq 124 ]; then PC_JUDGE_ERR="judge timed out after ${2}s"
    else PC_JUDGE_ERR="judge unreachable: returned nothing (exit $status)"; fi
    return 1
  fi
  # Line 1 the verdict on the envelope, line 2 its time and cost, line 3 the object.
  parsed="$(printf '%s' "$envelope" | python3 -c '
import sys, json, re
try:
    env = json.load(sys.stdin)
    if not isinstance(env, dict):
        print("ERR_VERDICT"); sys.exit(0)
    def num(v):
        return "" if isinstance(v, bool) or not isinstance(v, (int, float)) else (repr(v) if isinstance(v, float) else str(v))
    meta = num(env.get("duration_ms")) + "\t" + num(env.get("total_cost_usd"))
    if env.get("is_error"):
        print("ERR_ENVELOPE"); print(meta); sys.exit(0)
    txt = (env.get("result") or "").strip()
    txt = re.sub(r"^```[a-zA-Z]*", "", txt).strip()
    txt = re.sub(r"```$", "", txt).strip()
    m = re.search(r"\{.*\}", txt, re.S)
    obj = json.loads(m.group(0)) if m else None
    if not isinstance(obj, dict):
        print("ERR_VERDICT"); print(meta); sys.exit(0)
    print("OK"); print(meta); print(json.dumps(obj, separators=(",", ":")))
except Exception:
    print("ERR_VERDICT")
' 2>/dev/null)"
  local head="${parsed%%$'\n'*}" rest meta
  rest="${parsed#*$'\n'}"; [ "$rest" = "$parsed" ] && rest=""
  meta="${rest%%$'\n'*}"
  PC_JUDGE_MS="${meta%%$'\t'*}"
  case "$meta" in *$'\t'*) PC_JUDGE_COST="${meta#*$'\t'}" ;; esac
  case "$head" in
    OK) PC_JUDGE_OBJ="${rest#*$'\n'}"; return 0 ;;
    ERR_ENVELOPE) PC_JUDGE_ERR="judge returned an error envelope" ;;
    *) PC_JUDGE_ERR="judge verdict was not readable JSON" ;;   # prose, garbage, or this parser failing
  esac
  return 1
}

# ---- the record of what each gate did (claude-config#1075) ----
# One tab separated line per push a gate reaches, appended to
# ${PUSH_GATE_LEDGER_DIR:-~/.claude/state/push-gates}/push-gates.tsv. Under ~/.claude/state, which
# holds per Mac state that is never synced and that nothing sweeps (the lessons review keeps its
# outcome ledger there for the same reason), so it outlives every temp clean. About 200 bytes a
# push. Read with lib/push-gate-report.py.
#
# Columns: finished, host, gate, outcome, repository root, HEAD, tool call id, model, judge wall
# seconds, judge duration_ms, judge cost in USD, bytes sent to the judge, started, detail, and the
# tree the push delivers. The tool call id is the one Claude Code gives every hook on one call, so
# the two gates' lines for one push share it, which is how pushes both judges were called on are
# counted (#1077). The model columns are filled only when a judge was called.
#
# The TREE, not HEAD, is what a block and a later override are matched on. For an add, commit and
# push command the commit does not exist yet when the gate runs, so HEAD names the commit it stands
# on: a blocked chain and an override of the same content after the commit was made on its own
# carried different HEADs, and two different chains from one commit carried the same one. The tree
# is the same content either way (pc_push_tree).
#
# The outcomes are this list and nothing else, so the report and the gates spell them one way:
#   override   SKIP_*_CHECK=1 on the push
#   nosource   no source file in the push, nothing to judge (a correct, silent pass)
#   empty      the push carries nothing judgeable
#   docsonly   the test gate: every changed source line is a comment or blank
#   untested   the test gate: source with no test at all, refused without a model
#   pass       the judge passed it
#   block      the judge refused it
#   cantjudge  the test gate: the judge said untested, over test changes it could not see all of
#   failopen   the gate wanted to decide and could not; the detail says why
PC_OUTCOMES="override nosource empty docsonly untested pass block cantjudge failopen"
PC_LEDGER_NAME="push-gates.tsv"

pc_ledger_path() {
  printf '%s/%s' "${PUSH_GATE_LEDGER_DIR:-$HOME/.claude/state/push-gates}" "$PC_LEDGER_NAME"
}

# The tool call id from a hook payload, or nothing. Read by pattern, since the payload was already
# parsed for what decides the gate and this field decides nothing.
pc_call_id() {   # $1 = payload JSON
  local re='"tool_use_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
  [[ "$1" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# Appends the line. Reads PC_GATE and PC_CALL_ID (set by the gate once it has the payload), the
# repository and HEAD from the shell's directory, and the PC_JUDGE_* values when $3 = judged.
# Returns 2, writing nothing, for an outcome not in PC_OUTCOMES, and 1 when the line could not be
# written: the gate says so rather than losing the record silently, and never changes its verdict.
pc_record() {   # $1 = outcome  $2 = detail  $3 = judged (when a judge was called)
  local outcome="$1" detail="${2:-}" judged="${3:-}" dir file host repo head now
  case " $PC_OUTCOMES " in *" $outcome "*) ;; *) return 2 ;; esac
  file="$(pc_ledger_path)"; dir="${file%/*}"
  mkdir -p "$dir" 2>/dev/null
  host="$(hostname 2>/dev/null)"; host="${host%.local}"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)"
  head="$(git rev-parse --verify --quiet HEAD 2>/dev/null)"
  now="$(date +%s)"
  detail="$(printf '%s' "$detail" | tr '\t\n\r' '   ' | cut -c 1-400)"
  local model="" wall="" ms="" cost="" bytes="" start="$now"
  if [ "$judged" = judged ]; then
    model="$PC_JUDGE_MODEL"; ms="$PC_JUDGE_MS"; cost="$PC_JUDGE_COST"; bytes="$PC_JUDGE_BYTES"
    if [ -n "$PC_JUDGE_START" ] && [ -n "$PC_JUDGE_END" ]; then
      start="$PC_JUDGE_START"; wall=$((PC_JUDGE_END - PC_JUDGE_START))
    fi
  fi
  local tree; tree="$(pc_push_tree)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$host" "${PC_GATE:-}" "$outcome" "$repo" "$head" "${PC_CALL_ID:-}" \
    "$model" "$wall" "$ms" "$cost" "$bytes" "$start" "$detail" "$tree" 2>/dev/null >> "$file" || return 1
  return 0
}

# The tree the push delivers: HEAD's for a plain push, and for a command that commits first, the
# tree that commit will make, written from a COPY of the index with the pending files added, so the
# real index is never touched. Prints nothing when it cannot be worked out; the report then falls
# back to HEAD for that line.
pc_push_tree() {
  local idx tmp f
  local -a paths=()
  if [ "${PC_COMMIT_IN_CHAIN:-0}" != 1 ]; then
    git rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null
    return 0
  fi
  idx="$(git rev-parse --git-path index 2>/dev/null)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/pc-index.XXXXXXXX")" || return 0
  if [ -f "$idx" ]; then cp "$idx" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  else rm -f "$tmp"; GIT_INDEX_FILE="$tmp" git read-tree HEAD 2>/dev/null || { rm -f "$tmp"; return 0; }; fi
  while IFS= read -r f; do [ -n "$f" ] && paths+=("$f"); done <<< "$PC_PENDING_ALL"
  if [ "${#paths[@]}" -gt 0 ]; then
    GIT_INDEX_FILE="$tmp" git add -A -- "${paths[@]}" >/dev/null 2>&1 || { rm -f "$tmp"; return 0; }
  fi
  GIT_INDEX_FILE="$tmp" git write-tree 2>/dev/null
  rm -f "$tmp"
  return 0
}
