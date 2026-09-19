#!/usr/bin/env bash
# Tests for check-doc-issue-refs.sh and its scanner lib/doc-issue-refs.py (claude-config#431).
#
# Two layers, each driving the REAL code and never a re-implementation of the rule:
#   1. the scanner on text alone: which sentences are pending claims and which are citations;
#   2. the hook end to end, against fixture repos with a fake `gh` first on PATH that answers a
#      fixed state per issue number and records every call, so dedupe and the cap are measured
#      rather than assumed.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-doc-issue-refs.sh"
SCANNER="$DIR/lib/doc-issue-refs.py"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.docrefs.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------------------
# 1. The scanner, on text.
# ---------------------------------------------------------------------------------------
scan() { printf '%s\n' "$1" | python3 "$SCANNER" --stdin doc.md; }

want_row() {   # $1 desc, $2 text, $3 expected "<line>:<issue>" fragment
  local out; out="$(scan "$2")"
  case "$out" in *"doc.md:$3:"*) ok ;; *) bad "$1: expected a row at doc.md:$3, got: [${out:-nothing}]" ;; esac
}
want_none() {  # $1 desc, $2 text
  local out; out="$(scan "$2")"
  if [ -z "$out" ]; then ok; else bad "$1: expected no row, got: [$out]"; fi
}

# The real finding, verbatim from Slate's docs/pii.md line 101 to 103, wrapped as it is there.
want_row "the review's real case: '#1041 is the issue for' across a wrapped line" \
"being called\", Slate cannot; the answer has to come from the landing page's own
records. **#1041** is the issue for putting a privacy link and consent copy on the
booker itself." "2:1041"

want_none "the brief's false positive: a past claim about the same issue" \
"#1041 added the links to the booker."

want_none "a past tense verb after the reference, with a future word later in the sentence" \
"#730 added a guard that will fail the build on the next hand rolled copy."

want_none "a parenthetical citation beside a future tense verb" \
"The capped read guard (#730) will refuse a new capped read."

want_row "a pending phrase inside the parentheses is still a claim" \
"The rest is out of scope (tracked in #392)." "1:392"

want_row "the reference the phrase is about, not its neighbours" \
"Issue #246 tracks committing a repeatable benchmark (noted in #246 and #240)." "1:246"
out="$(scan "Issue #246 tracks committing a repeatable benchmark (noted in #246 and #240).")"
case "$out" in *":240:"*) bad "the cited #240 in the parentheses was reported as a claim" ;; *) ok ;; esac
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && ok || bad "one claim about #246 must produce exactly one row, got: [$out]"

want_row "once #N merges" "Rebase onto main once #256 merges." "1:256"
want_row "when #N lands" "This section is rewritten when #2031 lands." "1:2031"
want_row "#N will" "#239 will eventually automate the teardown." "1:239"
want_row "will ... in #N" "The schedule will be added in #2031." "1:2031"
want_row "tracked in issue #N" "- Implementation tracked in issue #305." "1:305"
want_row "#N covers" "It is a hand-run command, and #2031 covers putting it on a schedule." "1:2031"
want_row "#N is open" "#1367 is still open." "1:1367"
want_row "planned in #N" "The stamp is planned in #1753." "1:1753"
want_row "not yet ... (#N)" "The picker is not yet keyboard operable (#1299)." "1:1299"
want_row "see #N beside a future word" "See #2031, which will put it on a schedule." "1:2031"
want_none "see #N on its own is a pointer, not a claim" "See #2031 for the measurements."
want_none "until #N is how these docs cite finished work" "Until #1629 it saw only one shape."
want_none "a bare citation" "The guard was added in #730 and widened in #822."
want_none "a hex colour in inline code" "Close button colour: \`#666\` to graphite."
want_none "a closing keyword inside fenced code" "Commit as:

\`\`\`
fix: tidy the picker

Closes #12, which will land later.
\`\`\`"
want_none "a six digit hex colour is not an issue" "Graphite is #343434 and will stay so."

want_row "a full issue URL carries its own repository" \
"https://github.com/Try-Pennie/slate/issues/1041 is the issue for the booker side." "1:Try-Pennie/slate#1041"

want_row "a table cell is its own sentence" \
"| GET /x | Drains jobs (#973). | #55 tracks the rest. |" "1:55"
out="$(scan "| GET /x | Drains jobs (#973). | #55 tracks the rest. |")"
case "$out" in *":973:"*) bad "the cited #973 in the neighbouring cell was reported" ;; *) ok ;; esac

want_none "list items are separate sentences: a pending word in the next item does not reach back" \
"- **#277** an availability read returned empty.
- the header's pending-approvals badge vanished."

out="$(printf '%s\n' "**#1041** is the issue for the booker." | python3 "$SCANNER" --explain --stdin d.md)"
case "$out" in *$'\t['*']') ok ;; *) bad "--explain appends the reason: got [$out]" ;; esac

# The scanner must never be the one asking GitHub (the hook owns the lookups): no process
# spawning and no network module anywhere in it. Its docstring may SAY "gh"; its code may not
# reach one.
if grep -Eq 'subprocess|urllib|socket|os\.system|os\.popen|http\.client' "$SCANNER"; then
  bad "the scanner must stay pure: it imports or calls something that could spawn gh or reach the network"
else ok; fi

# ---------------------------------------------------------------------------------------
# 2. The hook, end to end.
# ---------------------------------------------------------------------------------------

# A fake gh that answers a fixed state per issue number, records every call, and can be put
# into a failure mode. It lives with its own state files so each case gets a fresh one.
mk_bin() {  # prints the bin dir
  local bin; bin="$(mktemp -d "$WORKDIR/bin.XXXXXX")"
  : > "$bin/calls"; : > "$bin/states"; : > "$bin/mode"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$d/calls"
mode="$(cat "$d/mode" 2>/dev/null)"
case "$mode" in
  auth)    echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1 ;;
  network) echo "error connecting to api.github.com" >&2; exit 1 ;;
esac
num=""; repo=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --repo) i=$((i+1)); repo="${args[$i]}" ;;
    --json) i=$((i+1)) ;;
    issue|view) ;;
    *) [ -z "$num" ] && num="${args[$i]}" ;;
  esac
  i=$((i+1))
done
line="$(awk -v n="$num" '$1 == n { print; exit }' "$d/states")"
if [ -z "$line" ]; then
  echo "GraphQL: Could not resolve to an issue or pull request with the number of $num. (repository.issue)" >&2
  exit 1
fi
state="$(printf '%s' "$line" | awk '{print $2}')"
title="$(printf '%s' "$line" | cut -d' ' -f3-)"
printf '{"state":"%s","title":"%s"}\n' "$state" "$title"
EOF
  chmod +x "$bin/gh"
  printf '%s' "$bin"
}
set_state() { printf '%s %s %s\n' "$2" "$3" "$4" >> "$1/states"; }   # bin, number, STATE, title

# A fixture repo with a pushed baseline and an origin URL of the caller's choosing.
mk_repo() {  # $1 = origin url to record ; prints the work dir
  local root; root="$(mktemp -d "$WORKDIR/repo.XXXXXX")"
  (
    git init -q --bare "$root/origin.git"
    git init -q -b main "$root/work"
    cd "$root/work" || exit 1
    git config user.email t@t.t; git config user.name t
    mkdir -p docs src
    echo "# Widgets" > README.md
    echo "Baseline doc." > docs/notes.md
    echo "export const a = 1;" > src/a.ts
    git add -A; git commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin main
    git remote set-url origin "$1"
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}
GH_URL="https://github.com/acme/widgets.git"

commit_file() {  # $1 repo, $2 path, $3 content
  ( cd "$1" && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" > "$2" && git add "$2" && git -c user.name=t -c user.email=t@t commit -qm "edit $2" ) >/dev/null 2>&1
}

CODE=0; MSG=""
run_hook() {  # $1 bin dir (or "" for PATH untouched), $2 cwd, $3 command, [$4 = PATH to use verbatim]
  local p path
  p="$(HK_CMD="$3" HK_CWD="$2" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  if [ -n "${4:-}" ]; then path="$4"; elif [ -n "$1" ]; then path="$1:$PATH"; else path="$PATH"; fi
  MSG="$(printf '%s' "$p" | PATH="$path" bash "$HOOK" 2>&1 >/dev/null)"; CODE=$?
}
want_code() { if [ "$CODE" = "$1" ]; then ok; else bad "$2: expected exit $1, got $CODE; said: $MSG"; fi; }
want_says() { case "$MSG" in *"$1"*) ok ;; *) bad "$2: message did not say [$1], said: [$MSG]" ;; esac; }
want_quiet() { if [ -z "$MSG" ]; then ok; else bad "$1: expected no output, said: [$MSG]"; fi; }
calls() { sed '/^$/d' "$1/calls" | wc -l | tr -d ' '; }

PENDING_DOC='Slate cannot prove consent; the answer has to come from the landing page.
**#1041** is the issue for putting a privacy link and consent copy on the
booker itself.'
PAST_DOC='#1041 added the privacy link and consent copy to the booker.'

# --- the positive control: a closed issue named as pending is refused (L1) -------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "Add privacy policy links to the booker"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "git push"
want_code 2 "a closed issue in a pending sentence blocks the push"
want_says "PUSH BLOCKED" "the refusal is a refusal"
want_says "docs/pii.md:2" "the refusal names the file and line"
want_says "#1041 is closed" "the refusal names the issue and its state"
want_says "Add privacy policy links to the booker" "the refusal carries the issue title"
want_says "SKIP_DOC_REFS_CHECK=1" "the refusal names the override"
want_says "explain to the user" "the refusal says to explain before overriding"
[ "$(calls "$BIN")" = "1" ] && ok || bad "one candidate means one gh call, got $(calls "$BIN")"
case "$(cat "$BIN/calls")" in *"--repo acme/widgets"*) ok ;; *) bad "the repo must come from the origin URL, called: $(cat "$BIN/calls")" ;; esac

# --- the same sentence about an OPEN issue passes (both directions, L1) ----------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 OPEN "Add privacy policy links to the booker"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "git push"
want_code 0 "an open issue in a pending sentence passes"
want_quiet "an open issue passes quietly"
[ "$(calls "$BIN")" = "1" ] && ok || bad "the open case still asked gh once, got $(calls "$BIN")"

# --- a merged pull request is stale in the same way -------------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 256 MERGED "Precompute availability"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/plan.md "Rebase onto main once #256 merges."
run_hook "$BIN" "$R" "git push"
want_code 2 "a merged pull named as pending blocks the push"
want_says "#256 is merged" "the refusal says merged, not closed"

# --- a past claim is not a candidate, so gh is never asked --------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "Add privacy policy links to the booker"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PAST_DOC"
run_hook "$BIN" "$R" "git push"
want_code 0 "a past tense sentence about a closed issue passes"
want_quiet "a past tense sentence passes quietly"
[ "$(calls "$BIN")" = "0" ] && ok || bad "a past claim must not cost a lookup, got $(calls "$BIN") call(s)"

# --- a push touching no doc prints nothing and asks nothing -------------------------------
BIN="$(mk_bin)"
R="$(mk_repo "$GH_URL")"; commit_file "$R" src/b.ts "// #1041 is the issue for this"
run_hook "$BIN" "$R" "git push"
want_code 0 "a push with no doc file passes"
want_quiet "a push with no doc file is silent"
[ "$(calls "$BIN")" = "0" ] && ok || bad "no doc means no lookup, got $(calls "$BIN")"

# --- a doc with no pending claim is read and passes quietly -------------------------------
BIN="$(mk_bin)"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/notes.md "The guard was added in #730 and widened in #822."
run_hook "$BIN" "$R" "git push"
want_code 0 "a doc with citations only passes"
want_quiet "a doc with citations only is silent"

# --- gh missing: FAIL OPEN, out loud ------------------------------------------------------
# A PATH holding every tool the hook needs and no gh, so `command -v gh` really fails.
NOGH="$WORKDIR/nogh"; mkdir -p "$NOGH"
for t in bash sh git python3 sed awk grep sort uniq head tail cat mktemp xargs wc tr cut dirname basename env rm mkdir ls jq; do
  src="$(command -v "$t" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$NOGH/$t"
done
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "" "$R" "git push" "$NOGH"
want_code 0 "gh missing fails open"
want_says "gh not found" "gh missing says why"
want_says "not checked" "gh missing says nothing was checked, so it cannot read as a pass"
want_says "1 pending claim" "gh missing says how many claims went unchecked"

# --- gh present but unauthenticated: the same fail open, its own words -------------------
BIN="$(mk_bin)"; echo auth > "$BIN/mode"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "git push"
want_code 0 "an unauthenticated gh fails open"
want_says "could not answer" "an unauthenticated gh says it could not answer"
want_says "401" "the fail open line carries gh's own reason"
want_says "nothing verified" "the fail open line says nothing was verified"

# --- gh cannot reach GitHub: fail open too ------------------------------------------------
BIN="$(mk_bin)"; echo network > "$BIN/mode"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "git push"
want_code 0 "a network failure fails open"
want_says "error connecting" "the network failure is quoted"

# --- an unreachable answer beside a real closed finding: still refused ------------------
# The fake cannot fail per issue, so this uses a missing issue as the second answer: the
# refusal must stand on the measured closed one and note the other rather than go quiet.
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "Add privacy policy links to the booker"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC
Retention is tracked in #99999."
run_hook "$BIN" "$R" "git push"
want_code 2 "a closed finding is refused even when another id could not be resolved"
want_says "#99999 does not exist" "a dangling reference is noted by number"

# --- the escape hatch, one command only -----------------------------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "Add privacy policy links to the booker"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "SKIP_DOC_REFS_CHECK=1 git push"
want_code 0 "SKIP_DOC_REFS_CHECK=1 lets the push through"
want_says "not checked" "the skip says out loud that nothing was checked"
[ "$(calls "$BIN")" = "0" ] && ok || bad "the skip must not cost a lookup"
# The override is read by the shared helper the other push gates use (an inline VAR=1 anywhere
# in the one Bash command), and this suite does not re-decide its reach. What it does assert is
# that a look-alike is not the override.
run_hook "$BIN" "$R" "SKIP_DOC_REFS_CHECK=0 git push"
want_code 2 "SKIP_DOC_REFS_CHECK=0 is not the override"
run_hook "$BIN" "$R" "SKIP_DOC_REFS_CHECKS=1 git push"
want_code 2 "a misspelt override variable is not the override"

# --- a repo whose origin is not on GitHub: one skip line -----------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "git@gitlab.com:acme/widgets.git")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "git push"
want_code 0 "a non-GitHub origin passes"
want_says "not a GitHub remote" "a non-GitHub origin says why it skipped"
[ "$(calls "$BIN")" = "0" ] && ok || bad "a non-GitHub origin must not ask gh"

# --- the origin URL in each shape GitHub hands out ------------------------------------------
for url in "git@github.com:acme/widgets.git" "ssh://git@github.com/acme/widgets.git" "https://github.com/acme/widgets"; do
  BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
  R="$(mk_repo "$url")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
  run_hook "$BIN" "$R" "git push"
  want_code 2 "origin $url resolves to acme/widgets and blocks"
  case "$(cat "$BIN/calls")" in *"--repo acme/widgets"*) ok ;; *) bad "origin $url: wrong repo passed: $(cat "$BIN/calls")" ;; esac
done

# --- a full URL in the doc asks THAT repository ---------------------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 77 CLOSED "Elsewhere"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/x.md "https://github.com/other/place/issues/77 is the issue for the upstream half."
run_hook "$BIN" "$R" "git push"
want_code 2 "a full URL to a closed issue blocks"
case "$(cat "$BIN/calls")" in *"--repo other/place"*) ok ;; *) bad "a URL reference must ask its own repo: $(cat "$BIN/calls")" ;; esac
want_says "other/place#77 is closed" "the refusal names the foreign issue in full"

# --- dedupe and the cap ------------------------------------------------------------------------
BIN="$(mk_bin)"
body=""
for n in $(seq 100 144); do set_state "$BIN" "$n" OPEN "Issue $n"; body="$body
Part $n is tracked in #$n. Again, #$n is the issue for part $n."; done
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/big.md "$body"
run_hook "$BIN" "$R" "git push"
want_code 0 "45 open issues pass"
[ "$(calls "$BIN")" = "40" ] && ok || bad "45 ids named twice each must cost exactly 40 lookups (dedupe, then cap), got $(calls "$BIN")"
want_says "only the first 40" "the cap is said when it bites"
want_says "5 of them were NOT checked" "the cap says how many went unchecked"

BIN="$(mk_bin)"; set_state "$BIN" 5 OPEN "a"; set_state "$BIN" 6 OPEN "b"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/two.md "#5 tracks x. #6 tracks y. #5 is the issue for z."
run_hook "$BIN" "$R" "git push"
[ "$(calls "$BIN")" = "2" ] && ok || bad "two distinct ids named three times cost two lookups, got $(calls "$BIN")"
want_quiet "under the cap nothing is said"

# --- the push judged is the pushed RANGE, not the whole tree ----------------------------------
# The stale claim sits in a doc already on the base; this push touches a different file.
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "$GH_URL")"
# The origin URL is the fake GitHub one, so the push to the base goes through the bare repo's
# real path and the tracking ref is put back afterwards.
( cd "$R" && printf '%s\n' "$PENDING_DOC" > docs/pii.md && git add docs/pii.md \
  && git -c user.name=t -c user.email=t@t commit -qm stale \
  && git remote set-url origin "$(dirname "$R")/origin.git" && git push -q origin main \
  && git remote set-url origin "$GH_URL" ) >/dev/null 2>&1
commit_file "$R" docs/other.md "Nothing to see."
run_hook "$BIN" "$R" "git push"
want_code 0 "a stale claim in a doc this push does not touch is left alone"
[ "$(calls "$BIN")" = "0" ] && ok || bad "an untouched doc must not be read"
# ... and touching it is what brings it under judgement.
commit_file "$R" docs/pii.md "$PENDING_DOC
An unrelated edit."
run_hook "$BIN" "$R" "git push"
want_code 2 "touching the doc re-verifies the whole file, including the old claim"

# --- the whole file is read, not only the added lines ---------------------------------------
# (asserted above: the claim was on an untouched line of a touched file and still blocked)

# --- a commit chained before the push: the working tree is what the commit takes -----------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "$GH_URL")"
( cd "$R" && printf '%s\n' "$PENDING_DOC" > docs/pii.md ) >/dev/null 2>&1
run_hook "$BIN" "$R" "git add docs/pii.md && git commit -qm pii && git push"
want_code 2 "a pending doc that this command is about to commit is judged"
run_hook "$BIN" "$R" "git push"
want_code 0 "a push on its own judges the commits only, never the working tree"
# Only what the commit will carry (claude-config#457). Any add made this hook read EVERY untracked
# file, so another session's untracked doc was judged as this commit's.
( cd "$R" && printf '%s\n' "Unrelated." > docs/mine.md ) >/dev/null 2>&1
run_hook "$BIN" "$R" "git add docs/mine.md && git commit -qm mine && git push"
want_code 0 "an untracked doc the add does not name is not judged"
# And a commit then push on a branch level with its upstream answers for its own commit, not for
# the last one already on the remote (the plain push range re-read it).
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
( cd "$R" && git remote set-url origin "$(dirname "$R")/origin.git" && git push -q origin main \
    && git remote set-url origin "$GH_URL" && printf '%s\n' "Unrelated." > docs/mine.md ) >/dev/null 2>&1
run_hook "$BIN" "$R" "git add docs/mine.md && git commit -qm mine && git push"
want_code 0 "a commit then push does not answer for a doc already on the remote"

# --- the session's cwd is not the repo -------------------------------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$WORKDIR" "cd $R && git push"
want_code 2 "cd-then-push from a non-repo cwd is still checked"
run_hook "$BIN" "$WORKDIR" "git -C $R push"
want_code 2 "git -C push from a non-repo cwd is still checked"

# --- not a push at all -------------------------------------------------------------------------
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "$GH_URL")"; commit_file "$R" docs/pii.md "$PENDING_DOC"
run_hook "$BIN" "$R" "git status"
want_code 0 "a non-push command is not judged"
want_quiet "a non-push command is silent"
run_hook "$BIN" "$R" "echo 'git push'"
want_code 0 "a command that merely mentions a push is not judged"

# --- README, CLAUDE.md and AGENTS.md count as docs; build output does not -----------------------
for f in README.md CLAUDE.md AGENTS.md notes.mdx; do
  BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
  R="$(mk_repo "$GH_URL")"; commit_file "$R" "$f" "$PENDING_DOC"
  run_hook "$BIN" "$R" "git push"
  want_code 2 "$f is a doc file"
done
BIN="$(mk_bin)"; set_state "$BIN" 1041 CLOSED "x"
R="$(mk_repo "$GH_URL")"; commit_file "$R" node_modules/pkg/README.md "$PENDING_DOC"
( cd "$R" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m noop ) >/dev/null 2>&1
run_hook "$BIN" "$R" "git push"
want_code 0 "a README under node_modules is not a doc of this repo"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
