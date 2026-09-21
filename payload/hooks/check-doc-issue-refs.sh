#!/usr/bin/env bash
#
# check-doc-issue-refs.sh
# Claude Code PreToolUse(Bash) hook.
#
# Refuse a `git push` whose documentation says a GitHub issue is still PENDING when
# GitHub says it is closed (claude-config#431).
#
# Slate's docs/pii.md said the booker had no privacy link anywhere and named #1041 as
# the issue that would add one. #1041 closed on 2026-08-17. A month later an outside
# reviewer read the doc and reported the gap as open (Try-Pennie/slate#2561, item 7).
# L32 says docs state testable claims and L244 says a status recorded in a loaded file
# must be derived or checked; nothing checked a doc's issue references until this.
#
# WHAT IT READS: the doc files this push touches, whole. `docs/**`, any `README*`,
# `CLAUDE.md`, `AGENTS.md` and any `*.md` or `*.mdx`, outside node_modules, build output
# and vendored trees. The WHOLE file rather than the added lines, because a claim goes
# stale by the world moving, not by anybody editing it; touching the file is the moment
# somebody is looking at it, so that is when it is re-verified. A push touching no doc
# prints nothing and costs nothing.
#
# EXCEPT a file that DECLARES itself a dated record, with `<!-- doc-issue-refs:
# dated-record -->` in its first 20 lines, which is skipped entirely (#535). An append
# only diary is the one shape the paragraph above is wrong about: its old entries are the
# record of what was true that day, so the remedy this prints, rewrite the sentence, would
# mean editing history. Measured 2026-09-21 in danwright32/downbeat, six pushes in one
# session were each refused on the same six paragraphs the push had not touched, and the
# override was used six times, which is how a gate stops being read (L36). Declared rather
# than inferred, because a marker somebody writes is a decision and a rule guessing from
# prose would exempt any doc that happened to word itself that way.
#
# WHAT COUNTS: the sentence, not the line, and only a sentence whose pending phrase is
# ANCHORED to the reference ("#N is the issue for", "tracked in #N", "#N tracks", "#N
# will", "once #N", "when #N", "#N lands", "#N is open", "#N is pending", "not yet ...
# #N", "planned in #N"; "see #N" only beside a future tense word). The list, each with
# its reason, is in ONE place: lib/doc-issue-refs.py, which is pure (text in, candidate
# rows out, never a network call), so the test drives it on text alone. A reference
# followed by a past tense verb, or cited in parentheses, is never a candidate: "#1041
# added the links" is a true statement about a closed issue.
#
# MEASURED 2026-09-18 against Slate main (fc7397d7), 121 markdown files and AGENTS.md,
# 932 issue references in all:
#   the first draft matched the phrase anywhere in the sentence and produced 63 rows
#   naming 50 distinct issues, 48 of them closed or merged. About ten of the 63 were
#   pending claims; the rest cited finished work ("Until #1629 it saw only ...", "which
#   is the #1495 failure itself", "#428 reconcileCancelledBusyBlocks covers ...").
#   Almost every issue a doc names is closed, so a loose phrase does not make noise,
#   it refuses nearly every push that touches AGENTS.md.
#   anchoring the phrases to the reference produces 13 rows naming 10 distinct issues,
#   8 of them closed or merged (#1041 twice, #239, #246 twice, #256, #305, #392, #466,
#   #492) and 2 open (#1246, #1367). Every one of the 13 reads as a claim that the
#   issue is unfinished. The review's real finding, docs/pii.md:102 on #1041, is row 5,
#   and its twin in docs/pii-retention.md:357 is row 4.
#
# LOOKUPS: issue ids are deduplicated and capped at 40 per push, and the cap is SAID
# when it bites, because the 41st reference not being checked must not read as it
# passing (L98). Each id is one `gh issue view N --repo owner/name --json state,title`,
# run 6 at a time. A pull request number answers MERGED, which is reported as merged
# and refused the same way: a doc waiting on a merged pull is stale too.
#
# FAILS OPEN, OUT LOUD: `gh` missing, unauthenticated, or unable to reach GitHub prints
# one line saying nothing was checked and exits 0, following Slate's
# .githooks/lib/workflow-settings-guard.sh. A silent skip is indistinguishable from a
# pass. A repo whose origin is not on GitHub says so and exits 0 the same way. An issue
# number GitHub cannot resolve is noted, not refused: a dangling reference is a
# different defect from a stale claim (L11).
#
# Override: SKIP_DOC_REFS_CHECK=1 git push ...   one command only. Explain to Dan first
# why the claim is right despite the state (or why the sentence is not a claim), never
# skip silently.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
SCANNER="$HOOK_DIR/lib/doc-issue-refs.py"

payload="$(cat)"

# THE DETECTOR'S OWN READER, asked before anything is measured (claude-config#486, L490).
#
# lib/doc-issue-refs.py, which finds the sentences claiming an issue is still pending, runs under
# python3, and nothing here asked whether python3 was installed. Without it the candidate list came
# back empty, the emptiness test exited 0, and not one reference in any doc was ever checked
# against GitHub: every push passed, with nothing said (L42, L98). Two more readings below (the
# origin URL and the verdicts) are python3 too, so there is nothing left to fall back on.
#
# Asked above the payload read, because python3 is also one of the two tools ps_parse_payload
# reads with: with neither jq nor python3 the parse below exits 0 first and this question would
# never be reached (L135, L667). Narrowed by a cheap substring on the raw payload, since nothing
# here can tell a push from an `ls` when the payload is unreadable (L36, L54), and the override is
# read the same way so the refusal is never a dead end (L109).
if ps_reader_missing python3; then
  case "$payload" in
    *SKIP_DOC_REFS_CHECK=1*) exit 0 ;;
    *push*)
      echo "PUSH BLOCKED: $(ps_detector_absent_why "python3 is not on PATH" \
        "check-doc-issue-refs.sh runs its scanner, lib/doc-issue-refs.py, under it to find the sentences in this push's docs that claim an issue is still pending, so with python3 absent nothing here reads the docs at all." \
        "python3")" >&2
      echo "OVERRIDE, this one push: SKIP_DOC_REFS_CHECK=1 <your original git push command>" >&2
      exit 2 ;;
  esac
  exit 0
fi

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0

if ps_has_override "$cmd" SKIP_DOC_REFS_CHECK; then
  echo "note: SKIP_DOC_REFS_CHECK=1 is set, so the issue references in this push's docs were not checked against GitHub." >&2
  exit 0
fi

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

[ -f "$SCANNER" ] || { echo "note: skipping the doc issue reference check: its scanner is missing at $SCANNER, so nothing was checked." >&2; exit 0; }

# ---- which doc files does this push carry? -------------------------------------------

is_doc_path() {  # $1 = a repo-relative path
  case "$1" in
    */node_modules/*|node_modules/*|.next/*|*/.next/*|.open-next/*|*/.open-next/*|dist/*|*/dist/*|build/*|*/build/*|out/*|*/out/*|coverage/*|*/coverage/*|vendor/*|*/vendor/*|.git/*)
      return 1 ;;
  esac
  case "$1" in
    *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.svg|*.ico|*.woff|*.woff2|*.zip|*.gz|*.lock) return 1 ;;
  esac
  case "$1" in
    docs/*|*/docs/*|README*|*/README*|CLAUDE.md|*/CLAUDE.md|AGENTS.md|*/AGENTS.md|*.md|*.mdx) return 0 ;;
  esac
  return 1
}

base="$(ps_base_ref || true)"
commit_in_chain=0
ps_commit_in_chain "$cmd" && commit_in_chain=1
# Where the range starts, from the shared contract: a command that commits first answers for its
# own commit, not for the last one already on the remote (claude-config#441, #457).
if [ "$commit_in_chain" -eq 1 ]; then
  mb="$(ps_pending_base "$base")"
else
  mb="$(ps_merge_base "$base")"
fi
# A repo with a single commit has no HEAD~1 either; judge against the empty tree so the
# push's whole content is read rather than nothing.
[ -n "$mb" ] || mb="$(git hash-object -t tree /dev/null 2>/dev/null)"

# Two sources, each read where its content lives: committed paths from HEAD, and, when
# this command commits before it pushes, the working tree paths that commit would take.
committed_paths=""
[ -n "$mb" ] && committed_paths="$(git diff --name-only --diff-filter=AMR "$mb" HEAD 2>/dev/null)"
# The pending side is the index plus what the shared reader says the commit takes beyond it
# (claude-config#457). Any add made this read every untracked file, so another session's untracked
# doc was judged as this commit's.
pending_paths=""
pending_widened=0
if [ "$commit_in_chain" -eq 1 ]; then
  pending_paths="$(git diff --cached --name-only --diff-filter=AMR 2>/dev/null)"
  pending_list="$(ps_pending_files "$cmd")"
  [ "${pending_list%%$'\n'*}" = "WIDENED" ] && pending_widened=1
  pending_paths="${pending_paths}
$(printf '%s\n' "$pending_list" | tail -n +2)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-doc-refs.XXXXXXXX")" || exit 0
case "${WORK%/}" in ''|/|"${HOME%/}") exit 0 ;; esac
trap 'rm -rf "$WORK"' EXIT

: > "$WORK/candidates"
doc_count=0
scan_one() {  # $1 = path, $2 = committed | pending
  if [ "$2" = committed ]; then
    git show "HEAD:$1" 2>/dev/null | python3 "$SCANNER" --stdin "$1" 2>/dev/null
  else
    [ -f "$1" ] && python3 "$SCANNER" --stdin "$1" < "$1" 2>/dev/null
  fi
}
seen_paths=""
# The source word and the path are split on the single space between them; the path keeps
# any spaces of its own because it is the last field.
while IFS=' ' read -r src p; do
  [ -n "$p" ] || continue
  is_doc_path "$p" || continue
  case "$seen_paths" in *"|$p|"*) continue ;; esac
  seen_paths="${seen_paths}|$p|"
  doc_count=$((doc_count + 1))
  scan_one "$p" "$src" >> "$WORK/candidates"
done < <(
  printf '%s\n' "$committed_paths" | sed '/^$/d; s/^/committed /'
  printf '%s\n' "$pending_paths" | sed '/^$/d; s/^/pending /'
)

# Nothing this push carries is a doc: say nothing, cost nothing.
[ "$doc_count" -gt 0 ] || exit 0
[ -s "$WORK/candidates" ] || exit 0

# ---- who to ask -----------------------------------------------------------------------

origin_url="$(git remote get-url origin 2>/dev/null)"
# Parsed in python rather than sed: BSD sed has no lazy repetition and the four URL shapes
# GitHub hands out (git@, ssh://git@, https://, with and without .git) need one.
repo_slug="$(DR_URL="$origin_url" python3 -c '
import os, re
m = re.match(r"^(?:git@|ssh://git@|https?://|git://)?(?:www\.)?github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", os.environ["DR_URL"].strip())
print(m.group(1) + "/" + m.group(2) if m else "")
' 2>/dev/null)"
n_cands="$(sed '/^$/d' "$WORK/candidates" | wc -l | tr -d ' ')"
if [ -z "$repo_slug" ]; then
  echo "note: skipping the doc issue reference check: origin is not a GitHub remote (${origin_url:-none}), so the $n_cands pending claim(s) in this push's docs were not checked." >&2
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "note: skipping the doc issue reference check (gh not found), so the $n_cands pending claim(s) about issues in this push's docs were not checked against GitHub." >&2
  exit 0
fi

# Distinct issue ids in first-seen order. A row's id is a bare number (this repo) or
# owner/repo#number (a full URL in the doc).
CAP=40
ids="$(cut -d: -f3 "$WORK/candidates" | awk 'NF && !seen[$0]++')"
n_ids="$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')"
capped=0
if [ "$n_ids" -gt "$CAP" ]; then
  capped=$((n_ids - CAP))
  # awk rather than head: a piped head leaves early and kills its producer, which the repo's
  # short circuit ratchet counts (L183), and the same shape in push-scope.sh uses awk for it.
  ids="$(printf '%s\n' "$ids" | awk -v n="$CAP" 'NR <= n')"
fi

# ---- ask, six at a time ---------------------------------------------------------------

mkdir -p "$WORK/answers"
lookup() {  # $1 = id ; writes answers/<key>.{json,err,code}
  local id="$1" key repo num
  key="$(printf '%s' "$id" | tr '/#' '__')"
  case "$id" in
    *#*) repo="${id%#*}"; num="${id##*#}" ;;
    *)   repo="$repo_slug"; num="$id" ;;
  esac
  gh issue view "$num" --repo "$repo" --json state,title \
    > "$WORK/answers/$key.json" 2> "$WORK/answers/$key.err"
  echo $? > "$WORK/answers/$key.code"
}
export -f lookup
export WORK repo_slug
printf '%s\n' "$ids" | sed '/^$/d' | xargs -P 6 -I{} bash -c 'lookup "$1"' _ {} 2>/dev/null

# ---- judge ----------------------------------------------------------------------------

# One python pass reads every answer beside every candidate row and prints the verdict
# in a shape the shell can act on without re-parsing JSON:
#   REFUSE\t<file>\t<line>\t<id>\t<state>\t<title>\t<the line>
#   MISSING\t<id>
#   UNREACHABLE\t<id>\t<first line of gh's error>
verdicts="$(DR_WORK="$WORK" python3 - <<'PY'
import json, os, sys
work = os.environ["DR_WORK"]
rows = []
with open(os.path.join(work, "candidates"), encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split(":", 3)
        if len(parts) < 4:
            continue
        rows.append(parts)
answers = {}
adir = os.path.join(work, "answers")
for f in os.listdir(adir):
    if not f.endswith(".code"):
        continue
    key = f[:-5]
    try:
        code = int(open(os.path.join(adir, key + ".code")).read().strip() or "1")
    except ValueError:
        code = 1
    body = open(os.path.join(adir, key + ".json"), encoding="utf-8", errors="replace").read()
    err = open(os.path.join(adir, key + ".err"), encoding="utf-8", errors="replace").read()
    answers[key] = (code, body, err)
out = []
reported = set()
for path, ln, iid, text in rows:
    key = iid.replace("/", "_").replace("#", "_")
    if key not in answers:
        continue  # past the cap: counted by the shell, not judged here
    code, body, err = answers[key]
    if code == 0:
        try:
            d = json.loads(body)
        except ValueError:
            out.append("UNREACHABLE\t%s\tgh answered with something that is not JSON" % iid)
            continue
        state = str(d.get("state", "")).upper()
        if state in ("CLOSED", "MERGED"):
            out.append("REFUSE\t%s\t%s\t%s\t%s\t%s\t%s" % (path, ln, iid, state.lower(), d.get("title", ""), text))
        continue
    first = (err.strip().splitlines() or ["gh exited %d with no message" % code])[0]
    if "could not resolve to an issue" in err.lower() or "could not resolve to a" in err.lower():
        if ("MISSING", iid) not in reported:
            reported.add(("MISSING", iid))
            out.append("MISSING\t%s" % iid)
        continue
    if ("UNREACHABLE", iid) not in reported:
        reported.add(("UNREACHABLE", iid))
        out.append("UNREACHABLE\t%s\t%s" % (iid, first))
print("\n".join(out))
PY
)"

refusals="$(printf '%s\n' "$verdicts" | grep '^REFUSE' || true)"
missing="$(printf '%s\n' "$verdicts" | grep '^MISSING' || true)"
unreachable="$(printf '%s\n' "$verdicts" | grep '^UNREACHABLE' || true)"
n_unreach="$(printf '%s\n' "$unreachable" | sed '/^$/d' | wc -l | tr -d ' ')"

fmt_id() {  # a bare number becomes #N; owner/repo#N stays
  case "$1" in *#*) printf '%s' "$1" ;; *) printf '#%s' "$1" ;; esac
}

notes() {
  if [ "$capped" -gt 0 ]; then
    echo "note: this push's docs name $n_ids distinct issues in pending sentences and only the first $CAP were asked about, so $capped of them were NOT checked. Push the docs in smaller pieces, or check the rest by hand." >&2
  fi
  if [ -n "$missing" ]; then
    while IFS=$'\t' read -r _ iid; do
      [ -n "$iid" ] || continue
      echo "note: $(fmt_id "$iid") does not exist in $repo_slug, so a doc in this push points at nothing; not refused, but worth fixing." >&2
    done <<< "$missing"
  fi
}

if [ -z "$refusals" ]; then
  if [ "$n_unreach" -gt 0 ]; then
    first_err="$(printf '%s\n' "$unreachable" | awk -F'\t' 'NR == 1 { print $3 }')"
    echo "note: skipping the doc issue reference check: gh could not answer for $n_unreach of the $n_ids issue(s) this push's docs name ($first_err), so nothing verified that those claims are still current." >&2
  fi
  notes
  exit 0
fi

{
  echo "PUSH BLOCKED: a doc in this push says an issue is still pending, and GitHub says it is not."
  echo ""
  while IFS=$'\t' read -r _ path ln iid state title text; do
    [ -n "$path" ] || continue
    echo "  $path:$ln  $(fmt_id "$iid") is $state: \"$title\""
    echo "      $text"
  done <<< "$refusals"
  echo ""
  echo "Each sentence above talks about the issue as unfinished work. Rewrite it to say what"
  echo "actually happened (what the issue shipped, and where the remaining gap now lives if"
  echo "there is one), then push again."
  echo ""
  echo "Read $doc_count doc file(s) this push carries and asked GitHub about $(( n_ids - capped )) issue(s) named in pending sentences."
  if [ "$pending_widened" -eq 1 ]; then
    echo "The git add in this command could not be read, so every doc in the working tree was"
    echo "read as part of the commit it is about to make."
  fi
  if [ "$n_unreach" -gt 0 ]; then
    echo "gh could not answer for $n_unreach other issue(s), so those claims were not judged either way."
  fi
  echo "OVERRIDE: if the sentence is not a claim that the issue is pending, or the claim is"
  echo "right despite the state, re-run with:"
  echo "    SKIP_DOC_REFS_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical language,"
  echo "WHY skipping is legitimate here, so they can judge whether it makes sense."
  echo "Never override silently."
} >&2
notes
exit 2
