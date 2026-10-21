#!/usr/bin/env bash
# Tests for rtk-rewrite.sh, which rewrites a command before Claude Code runs it
# (claude-config#124).
#
# This is the hook with the least room for error in the whole set: whatever it emits is what
# actually EXECUTES. It had no test. The rewrite logic itself lives in the rtk binary and is not
# this repo's to check; what IS this repo's is the refusal, the pass through, and the JSON, and
# every one of those is checked here against a stubbed rtk so nothing depends on which version
# happens to be installed (L52 is the risk being accepted here, and it is accepted knowingly: the
# stub encodes the CONTRACT this hook relies on, and the contract is one line, "print the rewrite
# or exit 1").
#
# The refusal matters most. `rtk read` strips comment lines and renumbers what remains, so every
# line number taken from it is wrong AND plausible, which is worse than mangled output. Three
# planning passes cited wrong file:line pairs before anyone suspected the instrument
# (downbeat#254). The hook refuses by DESTINATION rather than by source command, and that
# distinction is what the checks below pin.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/rtk-rewrite.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v jq >/dev/null 2>&1 || { echo "test-rtk-rewrite: jq is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.rtk.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-rtk-rewrite: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"; mkdir -p "$BIN"
# A stub rtk whose whole behaviour is read from a file, so each scenario sets what the real binary
# would have said and nothing here depends on the version installed on this Mac.
cat > "$BIN/rtk" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version) cat "$RTK_STUB_DIR/version" 2>/dev/null || echo "rtk 0.31.0" ;;
  --help|help) cat "$RTK_STUB_DIR/help" 2>/dev/null || true ;;
  rewrite)
    if [ -s "$RTK_STUB_DIR/rewrite" ]; then cat "$RTK_STUB_DIR/rewrite"; exit 0; fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/rtk"
export RTK_STUB_DIR="$TMPROOT"
: > "$TMPROOT/rewrite"
# rtk's own subcommand list, which is where the set of test summarisers is derived from.
rtk_help_fixture() {
  cat > "$TMPROOT/help" <<'HELP'
Commands:
  git            Git commands with compact output
  test           Run tests and show only failures
  playwright     Playwright E2E tests with compact output
  pytest         Pytest test runner with compact output
  vitest         Vitest commands with compact output
  cargo          Cargo commands with compact output
  newrunner      Brand new test harness with compact output
  read           Read file with intelligent filtering
HELP
}
rtk_help_fixture

# The payload is written to a FILE and fed in with a redirect, never through a pipe. The hook
# exits before reading stdin in several of the cases below (no jq, no rtk, too old), and a python
# producer whose stdout closes underneath it fails to flush at exit and returns 120, which under
# `pipefail` becomes the exit code the check reads. The hook's own exit is what these are about.
payload() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1],"description":"d"}}))' "$1" > "$TMPROOT/payload.json"; }
hook() { # hook <command>  -> the hook's stdout, with the stub ahead of anything real on PATH
  payload "$1"
  PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null
}
rewritten_to() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("hookSpecificOutput") or {}).get("updatedInput") or {}).get("command",""))' 2>/dev/null; }

# ---------------------------------------------------------------------------
# The ordinary rewrite, which is the thing the hook is for.
# ---------------------------------------------------------------------------
printf 'rtk git status\n' > "$TMPROOT/rewrite"
out="$(hook 'git status')"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "a rewrite comes back as valid JSON" ok \
  || check "a rewrite comes back as valid JSON" "out=$out"
[ "$(printf '%s' "$out" | rewritten_to)" = "rtk git status" ] \
  && check "and carries the rewritten command" ok \
  || check "and carries the rewritten command" "out=$out"
# It decides NOTHING about permission (claude-config#1455). It used to answer every rewrite with
# "allow", which approved the command itself, skipping the prompt or the auto mode classifier for
# anything rtk filters, `git push` included. Measured 2026-10-21 on Claude Code 2.1.304: with no
# decision the rewrite still applies, and the permission rules judge the REWRITTEN command.
hook_decision() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("hookSpecificOutput" in d and "permissionDecision" in d["hookSpecificOutput"])' 2>/dev/null; }
[ "$(hook_decision "$out")" = False ] \
  && check "and decides nothing about permission, leaving it to Claude Code's rules" ok \
  || check "and decides nothing about permission, leaving it to Claude Code's rules" "out=$out"
grep -q '"hookEventName": *"PreToolUse"' <<< "$out" \
  && check "and still names its event, so the rewrite is read as a PreToolUse answer" ok \
  || check "and still names its event, so the rewrite is read as a PreToolUse answer" "out=$out"
printf 'rtk git push origin main\n' > "$TMPROOT/rewrite"
out1455="$(hook 'git push origin main')"
[ "$(printf '%s' "$out1455" | rewritten_to)" = "rtk git push origin main" ] && [ "$(hook_decision "$out1455")" = False ] \
  && check "#1455 a rewritten git push comes back rewritten and NOT approved" ok \
  || check "#1455 a rewritten git push comes back rewritten and NOT approved" "out=$out1455"
printf 'rtk git status\n' > "$TMPROOT/rewrite"
# The rest of the tool input has to survive: the hook replaces ONE field of it, and a rewrite that
# dropped the others would silently discard whatever else the caller set.
grep -q '"description"' <<< "$out" \
  && check "and keeps the rest of the tool input rather than replacing it" ok \
  || check "and keeps the rest of the tool input rather than replacing it" "out=$out"

# ---------------------------------------------------------------------------
# The refusal. Judged by DESTINATION, so it must hold whatever command produced it.
# ---------------------------------------------------------------------------
printf 'rtk read /repo/Thing.swift\n' > "$TMPROOT/rewrite"
for src in "cat /repo/Thing.swift" "head -50 /repo/Thing.swift" "tail -20 /repo/Thing.swift" "sed -n 1,5p /repo/Thing.swift"; do
  [ -z "$(hook "$src")" ] \
    && check "a rewrite into 'rtk read' is refused, whatever produced it: $src" ok \
    || check "a rewrite into 'rtk read' is refused, whatever produced it: $src" "it rewrote anyway"
done
# The control: with the destination changed and NOTHING else changed, the same source commands are
# rewritten. Without this, every refusal above is satisfied by a hook that rewrites nothing (L159).
printf 'rtk cat /repo/Thing.swift\n' > "$TMPROOT/rewrite"
[ -n "$(hook 'cat /repo/Thing.swift')" ] \
  && check "the control: the same command IS rewritten when the destination is not rtk read" ok \
  || check "the control: the same command IS rewritten when the destination is not rtk read" "it refused that too"

# ---------------------------------------------------------------------------
# Everything that must pass through untouched, saying nothing.
# ---------------------------------------------------------------------------
: > "$TMPROOT/rewrite"       # the stub now exits 1, which is rtk saying "no rewrite"
[ -z "$(hook 'git status')" ] \
  && check "no rewrite available means the command passes through silently" ok \
  || check "no rewrite available means the command passes through silently" "it said something"
printf 'git status\n' > "$TMPROOT/rewrite"
[ -z "$(hook 'git status')" ] \
  && check "a rewrite identical to the command passes through silently" ok \
  || check "a rewrite identical to the command passes through silently" "it emitted a no-op rewrite"
printf 'rtk git status\n' > "$TMPROOT/rewrite"
payload ''
[ -z "$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null)" ] \
  && check "a payload with an empty command passes through silently" ok \
  || check "a payload with an empty command passes through silently" "it rewrote nothing into something"
printf 'not json' > "$TMPROOT/payload.json"
[ -z "$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null)" ] \
  && check "a payload that does not parse passes through silently" ok \
  || check "a payload that does not parse passes through silently" "it emitted something"

# ---------------------------------------------------------------------------
# A version of rtk too old to have `rewrite` at all. It must WARN and pass through, never rewrite
# and never fail the command: an unusable tool has to be visible, and the person's command still
# has to run (L11).
# ---------------------------------------------------------------------------
printf 'rtk 0.22.0\n' > "$TMPROOT/version"
printf 'rtk git status\n' > "$TMPROOT/rewrite"
payload 'git status'
out_old="$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>"$TMPROOT/olderr")"; code_old=$?
[ -z "$out_old" ] && [ "$code_old" -eq 0 ] \
  && check "an rtk too old to rewrite passes the command through and exits cleanly" ok \
  || check "an rtk too old to rewrite passes the command through and exits cleanly" "out=$out_old exit=$code_old"
grep -qi 'too old' "$TMPROOT/olderr" \
  && check "and says so rather than going quiet" ok \
  || check "and says so rather than going quiet" "stderr=$(cat "$TMPROOT/olderr")"
printf 'rtk 0.31.0\n' > "$TMPROOT/version"

# ---------------------------------------------------------------------------
# rtk absent altogether. PATH here holds neither the stub nor anything else, so this is the state
# of a machine where rtk was never installed.
# ---------------------------------------------------------------------------
# The system directories only. rtk installs into ~/.local/bin or a package manager's directory,
# never into /usr/bin, so this is a PATH that has every tool the hook needs and no rtk. Asserted
# rather than assumed, because a PATH that happened to still hold rtk would make the checks below
# pass while testing the ordinary case again.
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$SYSPATH" command -v rtk >/dev/null 2>&1 \
  && check "the fixture PATH really has no rtk on it" "rtk is at $(PATH="$SYSPATH" command -v rtk)" \
  || check "the fixture PATH really has no rtk on it" ok
PATH="$SYSPATH" command -v jq >/dev/null 2>&1 \
  && check "and does have jq, so the hook gets past its first guard" ok \
  || check "and does have jq, so the hook gets past its first guard" "no jq on $SYSPATH"
payload 'git status'
out_none="$(PATH="$SYSPATH" bash "$H" < "$TMPROOT/payload.json" 2>"$TMPROOT/noneerr")"; code_none=$?
[ -z "$out_none" ] && [ "$code_none" -eq 0 ] \
  && check "with rtk not installed the command passes through and exits cleanly" ok \
  || check "with rtk not installed the command passes through and exits cleanly" "out=$out_none exit=$code_none"
grep -qi 'not installed' "$TMPROOT/noneerr" \
  && check "and says which tool is missing" ok \
  || check "and says which tool is missing" "stderr=$(cat "$TMPROOT/noneerr")"

# ---------------------------------------------------------------------------
# A TEST RUN is never rewritten into an rtk summariser (claude-config#259).
#
# Twice on 2026-09-01 a full Playwright run came back as exactly 18 bytes, `PASS (0) FAIL (3)`,
# and nothing else. Both commands EXITED 0 and the true results were 4356 and 4359 passed with
# nothing failed. Two properties compound: it invented three failures that did not exist, and it
# discarded the entire underlying output, so there was nothing left to cross-check against. The
# same parser failing the other way round reports PASS on a red suite, by the same mechanism, with
# no output left to contradict it.
#
# A summary that can disagree with the exit code, while being the only thing printed, is not a
# summary a reader can rely on, and a test verdict is the one output where being wrong is
# indistinguishable from being right. So test runs pass through unfiltered and everything else
# keeps saving tokens, which is the same shape as the `rtk read` refusal above: by DESTINATION,
# because whatever produced it is what corrupts the output.
refused_to_rewrite() { # refused_to_rewrite <destination>  -> "ok" when the hook passed through
  printf '%s\n' "$1" > "$TMPROOT/rewrite"
  local o; o="$(hook 'some command')"
  if [ -z "$o" ]; then echo ok; else echo "it rewrote to: $(printf '%s' "$o" | rewritten_to)"; fi
}
check "#259 a playwright run is not condensed into a verdict" \
  "$(refused_to_rewrite 'rtk playwright test --config playwright.node.config.js --reporter=dot')"
check "#259 nor a pytest run" "$(refused_to_rewrite 'rtk pytest -q')"
check "#259 nor a vitest run" "$(refused_to_rewrite 'rtk vitest run')"
check "#259 nor the generic test summariser" "$(refused_to_rewrite 'rtk test')"
# The test-ness of these lives in the ARGUMENT, not the subcommand: rtk's help calls `cargo` and
# `go` compact output for those tools generally, and only the `test` verb makes it a verdict.
check "#259 nor cargo test, where the verb is the argument" "$(refused_to_rewrite 'rtk cargo test')"
check "#259 nor go test" "$(refused_to_rewrite 'rtk go test ./...')"
# Derived, not listed: a summariser this hook has never heard of is refused because rtk's own help
# says it runs tests. A hand-written list checks only what it lists (L96).
check "#259 and a test summariser nobody hardcoded is refused too" "$(refused_to_rewrite 'rtk newrunner --all')"

# The controls, and they are the point: everything that is not a test verdict still saves tokens.
printf 'rtk git status\n' > "$TMPROOT/rewrite"
out_259a="$(hook 'git status')"
[ "$(printf '%s' "$out_259a" | rewritten_to)" = "rtk git status" ] \
  && check "#259 an ordinary command is still rewritten" ok \
  || check "#259 an ordinary command is still rewritten" "out=$out_259a"
printf 'rtk cargo build\n' > "$TMPROOT/rewrite"
out_259b="$(hook 'cargo build')"
[ "$(printf '%s' "$out_259b" | rewritten_to)" = "rtk cargo build" ] \
  && check "#259 and a cargo BUILD is not caught by the cargo test rule" ok \
  || check "#259 and a cargo BUILD is not caught by the cargo test rule" "out=$out_259b"

# Fail closed. If rtk stops answering with a subcommand list the derivation finds nothing, and a
# refusal that quietly stopped refusing would be the defect back with a green test beside it (L98).
: > "$TMPROOT/help"
check "#259 a floor destination is still refused when the derivation reads nothing" \
  "$(refused_to_rewrite 'rtk playwright test')"
rtk_help_fixture

# ---------------------------------------------------------------------------
# A FILE COMPARISON is never rewritten into `rtk diff` (claude-config#318).
#
# Two measurements against rtk 0.31.0 on 2026-09-05. `rtk diff` on two one line files that differ
# prints the difference and EXITS 0, where the real diff exits 1, so anything judging by the exit
# code reads "different" as "same" (L184: judge a command by its exit code, and here the exit code
# lies). And comparing a regenerated lessons index against the committed one, it printed
# "[ok] Files are identical" for two files that genuinely differ; cmp on the same pair reported
# "differ: char 44885, line 206", and a repeat of the same command a minute later reported the
# difference correctly. That half is intermittent, which is worse than always wrong: it was caught
# only because the line was read by hand afterwards.
#
# A comparison verdict has the same property as the test verdict above, that being wrong is
# indistinguishable from being right, and it is worse in one way: the two things a reader could
# cross-check against each other are the output and the exit code, and the exit code here carries
# no verdict at all. So file comparisons pass through unfiltered and everything else keeps saving
# tokens. Refused by DESTINATION, like the two refusals above.
#
# There is deliberately NO derivation from rtk's help for this one, unlike the test summarisers.
# The only thing a help line offers to match on is the word "diff" in a description, and the day
# `git`'s description mentions diffs that match refuses every git rewrite, which is the largest
# saving this hook exists for. The floor is the whole rule here, and what justifies it is the
# measured exit code rather than the name.
check "#318 a file comparison is not condensed into rtk diff" "$(refused_to_rewrite 'rtk diff a.txt b.txt')"
check "#318 nor one carrying flags through" "$(refused_to_rewrite 'rtk diff -u old/x.md new/x.md')"
check "#318 nor the bare subcommand" "$(refused_to_rewrite 'rtk diff')"

# And `rtk find`, measured the same way and found by the check rather than by a person
# (claude-config#319). `find ./no-such-dir` exits 1 and `rtk find ./no-such-dir` exits 0, so a
# search over a path that does not exist, a typo or something since moved, reads as a search that
# ran and found nothing (L100, L320). That is the same defect class as `rtk diff` above and it is
# refused for the same reason, but it is worth saying how it was found: check-rtk-exit-fidelity.sh
# compares both against the real tool, so the list below is no longer the only thing standing
# between a lying substitute and a session that believes it (L96).
check "#319 a find is not condensed into rtk find, whose exit code disagrees" \
  "$(refused_to_rewrite 'rtk find ./no-such-dir')"
check "#319 nor one with native find flags" \
  "$(refused_to_rewrite 'rtk find . -name Thing.swift -type f')"

# The control, and it is what keeps the refusal from over-reaching: `rtk git diff` is a DIFFERENT
# destination and was measured to preserve its exit code (a dirty tree gave 1 through both the real
# git and rtk), so it must still be rewritten. A refusal that swallowed it would take
# `git diff --quiet` with it, which is how a script asks whether anything changed at all.
printf 'rtk git diff --quiet\n' > "$TMPROOT/rewrite"
out_318="$(hook 'git diff --quiet')"
[ "$(printf '%s' "$out_318" | rewritten_to)" = "rtk git diff --quiet" ] \
  && check "#318 and rtk git diff, which does carry its exit code, is still rewritten" ok \
  || check "#318 and rtk git diff, which does carry its exit code, is still rewritten" "out=$out_318"

# ---------------------------------------------------------------------------
# A rewrite that changes WHICH PROGRAM RUNS is never made (claude-config#1408).
#
# On 2026-10-20 a background `cd "<checkout>" && npx wrangler kv key list --namespace-id <id>
# --remote --config ...` printed "npm error Missing script: wrangler" instead of running wrangler.
# rtk 0.31.0 rewrites any `npx <tool>` it has no dedicated filter for into `rtk npx <tool>`, and
# `rtk npx` runs that as `npm <tool> <args>` (its own -vvv says "Running: npm wrangler ..."), an
# npm SCRIPT lookup. Measured the same day: `npx probe --version` against a local bin exiting 3
# became `npm probe --version`, which printed npm's own version and EXITED 0, and `rtk npx next dev`
# ran `npx next build`. So the destination itself runs a different program; refused by DESTINATION
# like the others, since every tool rtk does filter (tsc, eslint, prisma, prettier, next build,
# vitest) is rewritten to its own subcommand and never reaches `rtk npx`.
#
# `rtk lint` has the same fault in one shape: its first argument names the LINTER when it is a bare
# word, so `eslint src` became `rtk lint src`, which ran `npx src`, a registry package called src.
# `rtk lint .`, `rtk lint src/` and `rtk lint --fix src` were measured to run eslint and keep it.
# ---------------------------------------------------------------------------
check "#1408 an npx tool rtk has no filter for is not routed to an npm script" \
  "$(refused_to_rewrite 'rtk npx wrangler kv key list --namespace-id abc --remote --config workers/build-trigger/wrangler.toml')"
check "#1408 nor in the issue's own shape, after an until loop and cd &&" \
  "$(refused_to_rewrite 'until test -f /tmp/ready; do sleep 1; done; cd "/some dir" && rtk npx wrangler kv key list --remote')"
check "#1408 nor with npx's own flags in front" "$(refused_to_rewrite 'rtk npx --yes wrangler --version')"
check "#1408 nor a next subcommand rtk npx turns into next build" "$(refused_to_rewrite 'rtk npx next dev')"
check "#1408 eslint on a bare directory name is not run as a package of that name" "$(refused_to_rewrite 'rtk lint src')"
check "#1408 nor after cd &&" "$(refused_to_rewrite 'cd /repo && rtk lint src')"
# The controls: the npx tools rtk DOES filter keep their rewrite, and so does eslint wherever its
# first argument cannot be read as a linter name (L159).
for keep1408 in 'rtk prisma migrate status' 'rtk lint .' 'rtk lint src/' 'rtk lint --fix src' 'rtk lint' 'rtk npm run build'; do
  printf '%s\n' "$keep1408" > "$TMPROOT/rewrite"
  out1408="$(hook 'some command')"
  [ "$(printf '%s' "$out1408" | rewritten_to)" = "$keep1408" ] \
    && check "#1408 and $keep1408 is still rewritten" ok \
    || check "#1408 and $keep1408 is still rewritten" "out=$out1408"
done
# The same fault keyed on the SOURCE: a rewrite that drops the package RUNNER the command named.
# rtk 0.31.0 rewrites `pnpm tsc --noEmit` to `rtk tsc --noEmit`, which runs `npx tsc --noEmit`
# (its own -vvv says so), and `npx prisma ...` to `rtk prisma ...`, which runs a bare `prisma` from
# PATH. Which program and version runs is then rtk's choice, not the command's, and none of it is
# visible in the rewritten text. So every runner word in the command must survive into the rewrite.
runner_refused() { # runner_refused <source> <rewrite>  -> "ok" when the hook passed through
  printf '%s\n' "$2" > "$TMPROOT/rewrite"
  local o; o="$(hook "$1")"
  if [ -z "$o" ]; then echo ok; else echo "it rewrote to: $(printf '%s' "$o" | rewritten_to)"; fi
}
# These use destinations nothing else refuses, so only the runner rule can refuse them (L159);
# `rtk tsc` is refused on its own below, whatever the source.
check "#1408 pnpm prisma does not lose pnpm to rtk prisma" "$(runner_refused 'pnpm prisma migrate status' 'rtk prisma migrate status')"
check "#1408 nor npx prisma, which rtk runs as a bare prisma" "$(runner_refused 'npx prisma migrate status' 'rtk prisma migrate status')"
check "#1408 nor npx eslint" "$(runner_refused 'npx eslint src/' 'rtk lint src/')"
check "#1408 nor yarn" "$(runner_refused 'yarn prisma generate' 'rtk prisma generate')"
check "#1408 nor bunx" "$(runner_refused 'bunx prettier --check .' 'rtk prettier --check .')"
check "#1408 nor pnpm after cd &&" "$(runner_refused 'cd /repo && pnpm prisma generate' 'cd /repo && rtk prisma generate')"
# The controls: a rewrite that KEEPS the runner, or a command that named none, is still rewritten,
# and a runner word that is only an argument is carried through unchanged (L159).
for pair1408 in 'prisma migrate status|rtk prisma migrate status' 'npm run build|rtk npm run build' 'pnpm list|rtk pnpm list' 'echo npm && git status|echo npm && rtk git status'; do
  src1408="${pair1408%%|*}"; rw1408="${pair1408#*|}"
  printf '%s\n' "$rw1408" > "$TMPROOT/rewrite"
  out1408="$(hook "$src1408")"
  [ "$(printf '%s' "$out1408" | rewritten_to)" = "$rw1408" ] \
    && check "#1408 and [$src1408] is still rewritten to [$rw1408]" ok \
    || check "#1408 and [$src1408] is still rewritten to [$rw1408]" "out=$out1408"
done
# `rtk tsc` is refused whatever the source. It runs `npx tsc`, and where TypeScript is not a local
# dependency npx can fetch the unrelated registry package called tsc. Dan's decision on the
# finding, 2026-10-20: "Leave tsc unrewritten".
check "#1408 bare tsc is not rewritten to rtk tsc" "$(runner_refused 'tsc --noEmit' 'rtk tsc --noEmit')"
check "#1408 nor pnpm tsc" "$(runner_refused 'pnpm tsc --noEmit' 'rtk tsc --noEmit')"
check "#1408 nor tsc after cd &&" "$(runner_refused 'cd /repo && tsc -p tsconfig.json' 'cd /repo && rtk tsc -p tsconfig.json')"
# The issue said foreground and background differed. The hook reads only the command, so a payload
# asking for the background must get exactly the answer the same command gets in the foreground.
printf 'rtk npx wrangler --version\n' > "$TMPROOT/rewrite"
for bg1408 in true false; do
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"npx wrangler --version","description":"d","run_in_background":sys.argv[1]=="true"}}))' "$bg1408" > "$TMPROOT/payload.json"
  [ -z "$(PATH="$BIN:$PATH" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null)" ] \
    && check "#1408 the npx refusal holds with run_in_background=$bg1408" ok \
    || check "#1408 the npx refusal holds with run_in_background=$bg1408" "it rewrote"
done

# ---------------------------------------------------------------------------
# A refused destination ANYWHERE in the command, not only at its start (claude-config#399).
#
# On 2026-09-17, with every refusal above already shipped and installed, a diff still went through
# rtk and printed "[ok] Files are identical" for two files cmp said differ at line 99. The command
# was `cd ~/claude-config-sync && git show ... > f; diff <(sed ...) ~/.claude/CLAUDE.md | head -20;
# git log ...`, and rtk rewrote it to `cd ... && rtk git show ...; rtk diff <(sed ...) ... | head
# -20; rtk git log ...`. The refusals read only the FIRST word of the rewritten command, which was
# `cd`, so none of them ever saw the `rtk diff` in the middle. Every refusal had the same blind
# spot, so every shape below is checked for each of them, not only for diff (L30).
# ---------------------------------------------------------------------------
check "#399 an rtk diff after cd && is refused" \
  "$(refused_to_rewrite 'cd /repo && rtk git show origin/main:f > f.md; rtk diff <(sed "s#a#b#g" f.md) g | cat; rtk git log --oneline -3')"
# The shape above holds a redirect and a pipe on rtk invocations, which the #1419 rule refuses on
# its own, so it no longer proves the DIFF refusal reaches past `cd &&`. The same command with
# both taken out can be refused by nothing but the diff refusal (L159).
check "#399 and the same command with no pipe or redirect is still refused for its rtk diff" \
  "$(refused_to_rewrite 'cd /repo && rtk git show origin/main:f; rtk diff <(sed "s#a#b#g" f.md) g; rtk git log --oneline -3')"
check "#399 an rtk diff after a semicolon is refused" "$(refused_to_rewrite 'rtk ls; rtk diff a b')"
check "#399 an rtk diff behind an environment assignment is refused" "$(refused_to_rewrite 'LC_ALL=C rtk diff a b')"
check "#399 an rtk diff inside a subshell is refused" "$(refused_to_rewrite '(cd /repo && rtk diff a b)')"
# Since #1419 any rtk invocation captured by $(...) is refused whatever its destination, so this one
# no longer isolates the diff refusal; the subshell check above is the one that proves the diff
# refusal sees a nested invocation, and this stays as the shape that must be refused either way.
check "#399 an rtk diff inside a command substitution is refused" "$(refused_to_rewrite 'echo "$(rtk diff a b)"')"
check "#399 an rtk diff after || is refused" "$(refused_to_rewrite 'false || rtk diff a b')"
check "#399 an rtk read after && is refused" "$(refused_to_rewrite 'cd /repo && rtk read Thing.swift')"
check "#399 an rtk find after && is refused" "$(refused_to_rewrite 'cd /repo && rtk find ./no-such-dir')"
check "#399 a test summariser after && is refused" "$(refused_to_rewrite 'cd /repo && rtk pytest -q')"
check "#399 a test verb after && is refused" "$(refused_to_rewrite 'cd /repo && rtk cargo test')"
check "#399 a derived test summariser after && is refused" "$(refused_to_rewrite 'cd /repo && rtk newrunner --all')"
check "#399 a refused destination after a newline is refused" "$(refused_to_rewrite "$(printf 'rtk git status\nrtk diff a b')")"

# The control: the same compound shapes with no refused destination in them are still rewritten,
# or every refusal above is satisfied by a hook that stopped rewriting compound commands (L159).
# The pipe here belongs to a command rtk did NOT rewrite: until #1419 it hung off the `rtk git log`,
# and an rtk invocation whose output feeds a pipe is now refused (see #1419 below), which is a
# different rule from the one this control exists for.
printf 'cd /repo && rtk git status; rtk git log --oneline -3; echo done | cat\n' > "$TMPROOT/rewrite"
out_399="$(hook 'cd /repo && git status; git log --oneline -3; echo done | cat')"
[ "$(printf '%s' "$out_399" | rewritten_to)" = "cd /repo && rtk git status; rtk git log --oneline -3; echo done | cat" ] \
  && check "#399 a compound command with no refused destination is still rewritten" ok \
  || check "#399 a compound command with no refused destination is still rewritten" "out=$out_399"
# And a word merely CONTAINING rtk, or the text rtk diff inside a quoted argument that is not a
# command, does not make the scan refuse on a false match of the bare word.
printf 'rtk git commit -m artifact-diff\n' > "$TMPROOT/rewrite"
out_399b="$(hook 'git commit -m artifact-diff')"
[ -n "$out_399b" ] \
  && check "#399 a word that merely contains rtk is not read as an rtk invocation" ok \
  || check "#399 a word that merely contains rtk is not read as an rtk invocation" "it refused"

# ---------------------------------------------------------------------------
# An rtk invocation whose OUTPUT is read by another program is never rewritten (claude-config#1419).
#
# rtk's output is a summary for a person to read, and a pipe or a redirect hands it to a program
# instead. On 2026-10-20 `grep "|first|" nsf-sep.txt | awk ... | sort | head -60 | cut -f2` drew a
# 31 line "sample" built from rtk's header lines ("2 matches in 1F:", "[file] ... (2):", line
# number prefixes) with no error. Dan's decision on the issue, 2026-10-20: "Leave grep unrewritten
# when its output is piped or redirected." Measured against rtk 0.31.0 the same day, the defect is
# not grep's alone: `rtk git log | wc -l` counted 1 line where git gave 5, `rtk git diff > p`
# wrote a stat summary instead of a patch, and `rtk ls | cat` and `rtk git status | cat` both
# changed what the next command read. One predicate, so one rule for every destination (L30).
#
# Judged on the rewritten command, by where each rtk invocation's standard output GOES: a pipe
# (`|`, `|&`), a redirect of standard output (`>`, `>>`, `1>`, `&>`, `>&2`), or capture by the
# shell (`$(...)`, backticks, `<(...)`). A redirect of standard error alone changes nothing the
# next program reads, so it keeps the rewrite.
# ---------------------------------------------------------------------------
kept_as() { # kept_as <rewrite>  -> "ok" when the hook emitted exactly that rewrite
  printf '%s\n' "$1" > "$TMPROOT/rewrite"
  local o r; o="$(hook 'some command')"; r="$(printf '%s' "$o" | rewritten_to)"
  if [ "$r" = "$1" ]; then echo ok; else echo "expected the rewrite to be kept, got [${r:-nothing}]"; fi
}
# The issue's own reproduction, as rtk 0.31.0 rewrites it.
check "#1419 a grep piped into another command is not rewritten" "$(refused_to_rewrite 'rtk grep "|first|" f | cat')"
check "#1419 nor one redirected to a file" "$(refused_to_rewrite 'rtk grep x f > out')"
check "#1419 nor one appended to a file" "$(refused_to_rewrite 'rtk grep x f >> out')"
check "#1419 nor one whose stdout is named by number" "$(refused_to_rewrite 'rtk grep x f 1>out')"
check "#1419 nor one sending both streams to a file" "$(refused_to_rewrite 'rtk grep x f &>out')"
check "#1419 nor one sending stdout to stderr" "$(refused_to_rewrite 'rtk grep x f >&2')"
check "#1419 nor one with stderr merged and then piped" "$(refused_to_rewrite 'rtk grep x f 2>&1 | head')"
check "#1419 nor one piped with |&" "$(refused_to_rewrite 'rtk grep x f |& cat')"
check "#1419 nor one piped into tee" "$(refused_to_rewrite 'rtk grep x f | tee out')"
check "#1419 nor one with no space before the pipe" "$(refused_to_rewrite 'rtk grep x f|wc -l')"
check "#1419 nor one in a later stage whose output also feeds a pipe" "$(refused_to_rewrite 'cat f | rtk grep x | wc -l')"
check "#1419 nor one after cd &&" "$(refused_to_rewrite 'cd /repo && rtk grep x f | wc -l')"
check "#1419 nor the second of two commands" "$(refused_to_rewrite 'rtk grep x f; rtk grep y f | cat')"
check "#1419 nor one captured by \$(...)" "$(refused_to_rewrite 'echo $(rtk grep x f)')"
check "#1419 nor one captured into a variable" "$(refused_to_rewrite 'n=$(rtk grep -c x f)')"
check "#1419 nor one captured inside double quotes" "$(refused_to_rewrite 'echo "$(rtk grep x f)"')"
check "#1419 nor one captured by backticks" "$(refused_to_rewrite 'echo `rtk grep x f`')"
check "#1419 nor one read through process substitution" "$(refused_to_rewrite 'diff <(rtk grep x f) g')"
check "#1419 nor one inside a subshell that is piped" "$(refused_to_rewrite '(rtk grep x f) | cat')"
check "#1419 nor one inside a brace group that is redirected" "$(refused_to_rewrite '{ rtk grep x f; } > out')"
check "#1419 nor one inside a loop whose output is piped" "$(refused_to_rewrite 'for f in a b; do rtk grep x "$f"; done | cat')"
check "#1419 nor one inside a conditional that is redirected" "$(refused_to_rewrite 'if true; then rtk ls; fi > out')"
check "#1419 nor one in a case statement, whose patterns the scan does not parse" "$(refused_to_rewrite 'case x in a) rtk ls ;; esac')"
check "#1419 nor one captured inside an unquoted here document, which the shell expands" \
  "$(refused_to_rewrite "$(printf '%s\n' 'cat <<EOF' 'count: $(rtk grep -c x f)' 'EOF')")"
# The class: the same predicate over every other destination, each measured to change piped output.
check "#1419 the class: git log piped into wc" "$(refused_to_rewrite 'rtk git log | wc -l')"
check "#1419 the class: git diff saved as a patch" "$(refused_to_rewrite 'rtk git diff > out.patch')"
check "#1419 the class: ls piped" "$(refused_to_rewrite 'rtk ls -la | cat')"
check "#1419 the class: git status piped" "$(refused_to_rewrite 'rtk git status | cat')"
# Fail closed: a command the scan cannot balance is not rewritten, because a quote it lost track of
# could be hiding a pipe (L98).
check "#1419 a command with an unbalanced quote is not rewritten" "$(refused_to_rewrite "rtk grep 'x f | cat")"

# The controls. Output only a person reads keeps the rewrite, or every refusal above is satisfied
# by a hook that stopped rewriting grep altogether (L159).
check "#1419 a grep standing alone is still rewritten" "$(kept_as 'rtk grep x f')"
check "#1419 a pipe character inside double quotes is not a pipe" "$(kept_as 'rtk grep "a|b" f')"
check "#1419 nor inside single quotes" "$(kept_as "rtk grep 'a|b>c' f")"
check "#1419 nor escaped with a backslash" "$(kept_as 'rtk grep a\|b f')"
check "#1419 && after a grep is not a pipe" "$(kept_as 'rtk grep x f && echo ok')"
check "#1419 nor is ||" "$(kept_as 'rtk grep x f || true')"
check "#1419 a redirect of stderr alone keeps the rewrite" "$(kept_as 'rtk grep x f 2>/dev/null')"
check "#1419 and so does stderr to a file" "$(kept_as 'rtk grep x f 2>err')"
check "#1419 and stderr merged into stdout that is not piped" "$(kept_as 'rtk git status 2>&1')"
check "#1419 an input redirect keeps the rewrite" "$(kept_as 'rtk grep x f < in')"
check "#1419 the last stage of a pipe is read by the person, so keeps it" "$(kept_as 'cat f | rtk grep x')"
check "#1419 a pipe on a different command keeps it" "$(kept_as 'rtk grep x f; echo done | cat')"
check "#1419 a quoted \$(...) that is only text in single quotes keeps it" "$(kept_as "rtk grep '\$(x)' f")"
check "#1419 a shift inside arithmetic is not a here document that hides a later pipe" \
  "$(refused_to_rewrite "$(printf '%s\n' 'echo $((1<<2))' 'rtk grep x f | cat')")"
check "#1419 nor is a shift in a bare (( )) command" \
  "$(refused_to_rewrite "$(printf '%s\n' '(( x = 1<<2 ))' 'rtk grep x f | cat')")"
check "#1419 nor is a shift in arithmetic inside double quotes" \
  "$(refused_to_rewrite "$(printf '%s\n' 'echo "$((1<<2))"' 'rtk grep x f | cat')")"
check "#1419 an rtk invocation captured inside arithmetic is refused" \
  "$(refused_to_rewrite 'echo $(( $(rtk grep -c x f) + 1 ))')"
check "#1419 and inside a bare (( )) command" "$(refused_to_rewrite '(( n = $(rtk grep -c x f) ))')"
check "#1419 nested subshells opening with (( are not mistaken for arithmetic" \
  "$(refused_to_rewrite '((cd d && rtk grep x f) | cat)')"
check "#1419 arithmetic with no rtk in it keeps the rewrite beside it" "$(kept_as 'echo $((1<<2)); rtk grep x f')"
check "#1419 a loop whose output is not piped keeps it" "$(kept_as 'for f in a b; do rtk ls "$f"; done')"
check "#1419 a word like done as an argument is not read as closing anything" "$(kept_as 'rtk git commit -m done')"
check "#1419 a pipe character inside a format string keeps it" "$(kept_as 'rtk git log --format="%h|%s" -3')"
check "#1419 a comment holding a pipe keeps it" "$(kept_as 'rtk ls ~/x # a | b')"
check "#1419 a here document inside \$(...) inside quotes is not scanned as commands" \
  "$(kept_as "$(printf '%s\n' 'rtk git commit -m "$(cat <<'"'"'EOF'"'"'' "it's a | b > c" 'EOF' ')"')")"
check "#1419 a here document body is not scanned as commands" \
  "$(kept_as "$(printf '%s\n' "rtk git commit -F - <<'EOF'" "it's a | b > c" "EOF")")"

# ---------------------------------------------------------------------------
# Output a person reads DIRECTLY is never swapped for a summary that drops what they act on
# (claude-config#1428).
#
# Measured 2026-10-20 against rtk 0.31.0 with HOME emptied, each command run plain and through rtk
# and the bytes compared. `rtk curl` replaces a JSON body with its SHAPE: a 200 item array came back
# as `[{ number: int, ... }] (200)` and an issue body as `body: string[7210]`, every value gone and
# nothing left that parses, down to a 50 byte array; HTML and text bodies were cut to a tenth. rtk's
# own help calls it "auto-JSON detection and schema output". `rtk gh` outside `api` reformats: issue
# and pr views drop labels, milestone, assignees and reviewers (it asks gh for
# number,title,state,author,body,url and nothing else), the lists drop the labels column, priority
# included, and cut titles, run list drops branch and title, repo view drops the README, pr diff is
# no longer a patch, and pr status EXITS 1 on "Unknown JSON field" where gh exits 0. `rtk gh api`
# was byte for byte identical, a 6MB paginated array and a 4,219 character body included, and
# `gh ... --json` is not rewritten by rtk at all.
# ---------------------------------------------------------------------------
check "#1428 a curl is not replaced by rtk's JSON schema" "$(refused_to_rewrite 'rtk curl -s https://api.example.com/x.json')"
check "#1428 nor a curl after cd &&" "$(refused_to_rewrite 'cd /repo && rtk curl -s http://127.0.0.1:8000/a.json')"
check "#1428 an issue view is not reformatted without its labels and milestone" "$(refused_to_rewrite 'rtk gh issue view 1428')"
check "#1428 nor a pr view" "$(refused_to_rewrite 'rtk gh pr view 1432')"
check "#1428 nor an issue list, which drops the labels column" "$(refused_to_rewrite 'rtk gh issue list')"
check "#1428 nor a pr list" "$(refused_to_rewrite 'rtk gh pr list --state merged')"
check "#1428 nor a run list, which drops branch and title" "$(refused_to_rewrite 'rtk gh run list --limit 10')"
check "#1428 nor pr status, which exits 1 under rtk where gh exits 0" "$(refused_to_rewrite 'rtk gh pr status')"
check "#1428 nor a pr diff, which is no longer a patch" "$(refused_to_rewrite 'rtk gh pr diff 1432')"
check "#1428 nor repo view, which drops the README" "$(refused_to_rewrite 'rtk gh repo view o/r')"
check "#1428 nor an rtk gh shape nobody measured" "$(refused_to_rewrite 'rtk gh issue create --title t --body b')"
check "#1428 nor after cd &&" "$(refused_to_rewrite 'cd /repo && rtk gh issue list')"
# The controls: gh api was measured identical, so it keeps its rewrite and its place in the hook
# (L159). Its bytes are pinned against the real rtk in the end to end check below.
check "#1428 gh api keeps its rewrite" "$(kept_as 'rtk gh api repos/o/r/issues/1369')"
check "#1428 and with --paginate and --jq" "$(kept_as "rtk gh api --paginate repos/o/r/issues --jq '.[].title'")"
# Which gh subcommand runs is read by the one reading every gate shares (lib/push-scope.sh,
# claude-config#1188), never by word position: gh takes flags in front of its subcommand, so the
# third word is not always the subcommand. Each direction is held (L497).
check "#1428 gh api with a flag in front of it is still gh api and keeps its rewrite" "$(kept_as 'rtk gh -R o/x api repos/o/x')"
check "#1428 and an issue list with a flag in front of it is still refused" "$(refused_to_rewrite 'rtk gh --repo o/x issue list')"
check "#1428 and so is one with rtk's own flag in front of gh" "$(refused_to_rewrite 'rtk -v gh issue list')"
# Only what rtk runs is judged: a gh it left as written beside another rewrite costs that one nothing.
check "#1428 a plain gh beside an rtk rewrite keeps that rewrite" "$(kept_as 'gh pr list --json number && rtk git status')"
# Fail closed: with the shared reader gone, nothing can tell gh api from the rest, so an rtk gh is
# not rewritten at all, while a rewrite with no gh in it still is (L42).
NOLIB="$TMPROOT/nolib"; mkdir -p "$NOLIB"; cp "$H" "$NOLIB/rtk-rewrite.sh"
printf 'rtk gh api repos/o/r\n' > "$TMPROOT/rewrite"; payload 'gh api repos/o/r'
out1428nl="$(PATH="$BIN:$PATH" bash "$NOLIB/rtk-rewrite.sh" < "$TMPROOT/payload.json" 2>/dev/null)"
[ -z "$out1428nl" ] \
  && check "#1428 with no shared reader to ask, an rtk gh is not rewritten" ok \
  || check "#1428 with no shared reader to ask, an rtk gh is not rewritten" "it rewrote to: $(printf '%s' "$out1428nl" | rewritten_to)"
printf 'rtk git status\n' > "$TMPROOT/rewrite"; payload 'git status'
out1428nl="$(PATH="$BIN:$PATH" bash "$NOLIB/rtk-rewrite.sh" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
[ "$out1428nl" = 'rtk git status' ] \
  && check "#1428 and a rewrite with no gh in it still goes through" ok \
  || check "#1428 and a rewrite with no gh in it still goes through" "got [$out1428nl]"

# ---------------------------------------------------------------------------
# End to end against the REAL rtk (claude-config#399). Everything above uses a stub, which proves
# the hook's logic and nothing about what actually runs. So this drives the exact shape that fooled
# a session through the real hook and the real rtk, RUNS whatever the hook lets through, and asserts
# the verdict: diff's exit code 1, and no claim that the files are identical.
#
# The fixture is two files differing only in whitespace. Measured against rtk 0.31.0 on 2026-09-17,
# deterministic across repeats: `rtk diff` printed "[ok] Files are identical" and exited 0 for a
# whitespace only difference, for a trailing space, for a single replaced line, and for the real
# case of one long markdown line cut in half, while cmp reported each pair different. The earlier
# report (#318) called the false "identical" intermittent; on these fixtures it is not.
#
# The control comes first: the fixture is shown to fool rtk directly, so a green below means the
# hook kept the comparison away from rtk and not that this rtk happens to get this pair right
# (L159). CI has no rtk, so there this says so and measures nothing, the same way
# test-check-rtk-exit-fidelity.sh does (L11).
# ---------------------------------------------------------------------------
if ! command -v rtk >/dev/null 2>&1; then
  echo "note: rtk is not installed on this Mac, so the #399 end to end comparison did not run. Everything above used stubs."
else
  FX399="$TMPROOT/fx399"; mkdir -p "$FX399"
  printf 'first line\nsecond  line with two spaces\nthird line\n' > "$FX399/a.md"
  printf 'first line\nsecond line with two spaces\nthird line\n' > "$FX399/b.md"
  if cmp -s "$FX399/a.md" "$FX399/b.md"; then
    check "#399 the fixture pair really differs" "cmp reads them as identical"
  else
    rtk_direct="$(cd "$FX399" && rtk diff a.md b.md 2>&1)"
    if ! grep -q 'Files are identical' <<< "$rtk_direct"; then
      echo "note: this rtk ($(rtk --version 2>/dev/null)) no longer calls the #399 fixture identical, so the end to end check below proves less than it did. Output was: $rtk_direct"
    fi
    cmd399="cd '$FX399' && diff <(sed -n '1,\$p' a.md) b.md"
    payload "$cmd399"
    sub399="$(bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
    ran399="${sub399:-$cmd399}"
    out399="$(bash -c "$ran399" 2>&1)"; rc399=$?
    [ "$rc399" -eq 1 ] \
      && check "#399 the diff that actually runs keeps diff's exit code 1 for differing files" ok \
      || check "#399 the diff that actually runs keeps diff's exit code 1 for differing files" "ran [$ran399], exited $rc399: $out399"
    grep -q 'Files are identical' <<< "$out399" \
      && check "#399 and does not report the differing files as identical" "ran [$ran399]: $out399" \
      || check "#399 and does not report the differing files as identical" ok
  fi
fi

# ---------------------------------------------------------------------------
# End to end against the REAL rtk for #1419: the issue's reproduction, through the real hook and
# the real rtk, RUN, with the downstream command required to see the raw matching lines.
#
# HOME points at an empty throwaway directory, so rtk reads no config.toml. That matters: a Mac
# whose rtk config lists grep under [hooks] exclude_commands never rewrites grep at all, and there
# this check would pass while measuring nothing. The control below proves rtk under this HOME does
# rewrite the piped grep and does mangle its output, so a green means the hook stopped it (L159).
# ---------------------------------------------------------------------------
if ! command -v rtk >/dev/null 2>&1; then
  echo "note: rtk is not installed on this Mac, so the #1419 end to end check did not run. Everything above used stubs."
else
  FX1419="$TMPROOT/fx1419"; mkdir -p "$FX1419/home"
  printf 'a|first|x\nb|later|y\nc|first|z\n' > "$FX1419/f"
  want1419="$(printf 'a|first|x\nc|first|z')"
  cmd1419='grep "|first|" f | cat'
  ctl1419="$(HOME="$FX1419/home" rtk rewrite "$cmd1419" 2>/dev/null)"
  ctl1419_out="$(cd "$FX1419" && HOME="$FX1419/home" bash -c "$ctl1419" 2>&1)"
  if [ -z "$ctl1419" ] || [ "$ctl1419_out" = "$want1419" ]; then
    echo "note: this rtk ($(rtk --version 2>/dev/null)) no longer rewrites or mangles the #1419 piped grep (rewrite was [$ctl1419]), so the end to end check below proves less than it did."
  fi
  payload "$cmd1419"
  sub1419="$(HOME="$FX1419/home" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
  ran1419="${sub1419:-$cmd1419}"
  out1419="$(cd "$FX1419" && HOME="$FX1419/home" bash -c "$ran1419" 2>&1)"
  [ "$out1419" = "$want1419" ] \
    && check "#1419 a piped grep that actually runs hands the next command the raw matching lines" ok \
    || check "#1419 a piped grep that actually runs hands the next command the raw matching lines" "ran [$ran1419]: $out1419"
  # The control on the hook side: the same grep standing alone IS rewritten by the real rtk through
  # the real hook, so the green above is not a hook that has stopped talking to rtk.
  payload 'grep "|first|" f'
  sub1419b="$(HOME="$FX1419/home" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
  [ "$sub1419b" = 'rtk grep "|first|" f' ] \
    && check "#1419 and the same grep standing alone is still rewritten by the real rtk" ok \
    || check "#1419 and the same grep standing alone is still rewritten by the real rtk" "got [$sub1419b]"
fi

# ---------------------------------------------------------------------------
# End to end against the REAL rtk for #1408: the issue's shape, through the real hook, RUN, against
# a local bin that FAILS with exit 3. The program named must be the one that runs, and its failure
# must reach the caller. `--version` is the argument because npm swallows it: through `rtk npx` it
# printed npm's version and exited 0, the failure reading as a success.
#
# Same empty HOME as #1419, so no rtk config.toml can exclude npx and leave this measuring nothing.
# npm is held offline with its cache and logs in the throwaway directory: nothing here may reach
# the registry or write outside it (L2).
# ---------------------------------------------------------------------------
if ! command -v rtk >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
  echo "note: rtk or npx is not installed on this Mac, so the #1408 end to end check did not run."
else
  FX1408="$TMPROOT/fx1408"; mkdir -p "$FX1408/home" "$FX1408/node_modules/.bin"
  printf '{"name":"fx1408","version":"1.0.0"}\n' > "$FX1408/package.json"
  printf '#!/bin/sh\necho "probe1408 ran with: $*"\nexit 3\n' > "$FX1408/node_modules/.bin/probe1408"
  chmod +x "$FX1408/node_modules/.bin/probe1408"
  npm1408() { # npm1408 <command>  -> runs it in the fixture, offline, with HOME emptied
    ( cd "$FX1408" && HOME="$FX1408/home" NPM_CONFIG_OFFLINE=true NPM_CONFIG_UPDATE_NOTIFIER=false \
        NPM_CONFIG_CACHE="$FX1408/npm-cache" bash -c "$1" ) 2>&1
  }
  cmd1408="until test -d .; do sleep 1; done; cd '$FX1408' && npx probe1408 --version"
  # The control: under this HOME rtk really does make the bad rewrite, and running it really does
  # lose the program and its exit code, so a green below means the hook stopped it (L159).
  ctl1408="$(HOME="$FX1408/home" rtk rewrite "$cmd1408" 2>/dev/null)"
  ctl1408_out="$(npm1408 "$ctl1408")"; ctl1408_rc=$?
  if [ -z "$ctl1408" ] || grep -q 'probe1408 ran' <<< "$ctl1408_out"; then
    echo "note: this rtk ($(rtk --version 2>/dev/null)) no longer routes the #1408 npx elsewhere (rewrite was [$ctl1408], exit $ctl1408_rc), so the end to end check below proves less than it did."
  fi
  payload "$cmd1408"
  sub1408="$(HOME="$FX1408/home" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
  ran1408="${sub1408:-$cmd1408}"
  out1408e="$(npm1408 "$ran1408")"; rc1408=$?
  grep -q 'probe1408 ran with: --version' <<< "$out1408e" \
    && check "#1408 the npx that actually runs is the program the command named" ok \
    || check "#1408 the npx that actually runs is the program the command named" "ran [$ran1408]: $out1408e"
  [ "$rc1408" -eq 3 ] \
    && check "#1408 and its failure keeps its own non zero exit code" ok \
    || check "#1408 and its failure keeps its own non zero exit code" "ran [$ran1408], exited $rc1408: $out1408e"
  # The runner rule and the tsc refusal against the real rtk: each source IS rewritten by it to the
  # destination named (the control), and the hook passes it through.
  for pair1408e in 'npx prisma migrate status|rtk prisma migrate status' 'tsc --noEmit|rtk tsc --noEmit' 'pnpm tsc --noEmit|rtk tsc --noEmit'; do
    src1408e="${pair1408e%%|*}"; want1408e="${pair1408e#*|}"
    ctl1408e="$(HOME="$FX1408/home" rtk rewrite "$src1408e" 2>/dev/null)"
    [ "$ctl1408e" = "$want1408e" ] \
      || echo "note: this rtk now rewrites [$src1408e] to [$ctl1408e], so its check below proves less than it did."
    payload "$src1408e"
    sub1408e="$(HOME="$FX1408/home" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
    [ -z "$sub1408e" ] \
      && check "#1408 the real rtk's rewrite of [$src1408e] is refused" ok \
      || check "#1408 the real rtk's rewrite of [$src1408e] is refused" "got [$sub1408e]"
  done
  # The hook side control: prisma named with no runner is still rewritten by the real rtk.
  payload 'prisma migrate status'
  sub1408b="$(HOME="$FX1408/home" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to)"
  [ "$sub1408b" = 'rtk prisma migrate status' ] \
    && check "#1408 and prisma with no runner is still rewritten by the real rtk" ok \
    || check "#1408 and prisma with no runner is still rewritten by the real rtk" "got [$sub1408b]"
fi

# ---------------------------------------------------------------------------
# End to end against the REAL rtk for #1428: JSON and issue fields read directly, through the real
# hook, RUN, with the bytes that reach the reader compared against the source.
#
# Offline by construction. curl reads a file:// URL, which rtk 0.31.0 rewrites and condenses exactly
# as it does an http one (measured), and gh is a stub first on PATH that prints a fixed response,
# so `rtk gh` runs its real filter over known bytes and nothing reaches GitHub. The array holds 200
# items and its first carries a body over 2,000 characters, the two sizes the issue asked about.
# Same empty HOME as #1419, so no rtk config.toml can exclude curl or gh and leave this measuring
# nothing.
# ---------------------------------------------------------------------------
if ! command -v rtk >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "note: rtk or curl is not installed on this Mac, so the #1428 end to end check did not run."
else
  FX1428="$TMPROOT/fx1428"; mkdir -p "$FX1428/home" "$FX1428/bin"
  python3 - "$FX1428" <<'PY'
import json, sys
w = sys.argv[1]
body = "".join("line %d of a long issue body, with `code` | pipes and \"quotes\"\n" % i for i in range(60))
json.dump([{"number": i, "title": "item %d" % i, "body": body if i == 0 else "b"} for i in range(200)],
          open(w + "/arr.json", "w"))
json.dump({"number": 1, "title": "T", "body": body, "state": "OPEN", "author": {"login": "a"},
           "labels": [{"name": "priority-p1"}], "milestone": {"title": "Fixture milestone 1428"},
           "url": "https://example.invalid/1"}, open(w + "/issue.json", "w"))
PY
  printf '#!/bin/sh\ncase "$1" in api) cat "%s/arr.json" ;; issue) cat "%s/issue.json" ;; *) exit 1 ;; esac\n' \
    "$FX1428" "$FX1428" > "$FX1428/bin/gh"
  chmod +x "$FX1428/bin/gh"
  run1428() { # run1428 <command>  -> runs it in the fixture with the stub gh first and HOME emptied
    ( cd "$FX1428" && HOME="$FX1428/home" PATH="$FX1428/bin:$PATH" bash -c "$1" ) 2>/dev/null
  }
  hook1428() { # hook1428 <command>  -> what the real hook rewrote it to, empty when it passed through
    payload "$1"
    HOME="$FX1428/home" bash "$H" < "$TMPROOT/payload.json" 2>/dev/null | rewritten_to
  }

  # curl. The control: under this HOME rtk really does rewrite it and really does lose the JSON, so
  # a green means the hook stopped it (L159).
  cmd1428c="curl -s file://$FX1428/arr.json"
  ctl1428c="$(HOME="$FX1428/home" rtk rewrite "$cmd1428c" 2>/dev/null)"
  run1428 "$ctl1428c" > "$FX1428/ctl-curl.out"
  if [ -z "$ctl1428c" ] || cmp -s "$FX1428/ctl-curl.out" "$FX1428/arr.json"; then
    echo "note: this rtk ($(rtk --version 2>/dev/null)) no longer condenses the #1428 curl (rewrite was [$ctl1428c]), so the end to end check below proves less than it did."
  fi
  sub1428c="$(hook1428 "$cmd1428c")"
  run1428 "${sub1428c:-$cmd1428c}" > "$FX1428/curl.out"
  cmp -s "$FX1428/curl.out" "$FX1428/arr.json" \
    && check "#1428 a curl that actually runs hands the reader the JSON byte for byte" ok \
    || check "#1428 a curl that actually runs hands the reader the JSON byte for byte" \
         "ran [${sub1428c:-$cmd1428c}]: $(head -c 200 "$FX1428/curl.out")"

  # gh api is KEPT, so this is the pin: the real rtk's filter, run over 200 items and a long body,
  # must give back exactly the bytes gh printed. A future rtk that starts condensing gh api fails
  # here rather than in a session that acts on the fields it dropped.
  sub1428a="$(hook1428 'gh api repos/o/r/issues')"
  [ "$sub1428a" = 'rtk gh api repos/o/r/issues' ] \
    && check "#1428 gh api is still rewritten by the real rtk" ok \
    || check "#1428 gh api is still rewritten by the real rtk" "got [$sub1428a]"
  run1428 "${sub1428a:-gh api repos/o/r/issues}" > "$FX1428/api.out"
  cmp -s "$FX1428/api.out" "$FX1428/arr.json" \
    && check "#1428 and the real rtk gh api hands back gh's JSON byte for byte" ok \
    || check "#1428 and the real rtk gh api hands back gh's JSON byte for byte" \
         "ran [$sub1428a]: $(head -c 200 "$FX1428/api.out")"

  # gh with --json is not rewritten by rtk at all today, and would be refused if it ever were.
  sub1428j="$(hook1428 'gh issue view 1 --json title,body,labels,milestone')"
  [ -z "$sub1428j" ] \
    && check "#1428 gh issue view --json runs as gh itself" ok \
    || check "#1428 gh issue view --json runs as gh itself" "got [$sub1428j]"

  # The human issue view. The control: rtk rewrites it and the milestone does not survive, because
  # rtk never asks gh for it. Through the hook the reader gets gh's own output, milestone included.
  ctl1428v="$(HOME="$FX1428/home" rtk rewrite 'gh issue view 1' 2>/dev/null)"
  if [ -z "$ctl1428v" ] || grep -q 'Fixture milestone 1428' <<< "$(run1428 "$ctl1428v")"; then
    echo "note: this rtk ($(rtk --version 2>/dev/null)) no longer drops the #1428 milestone (rewrite was [$ctl1428v]), so the check below proves less than it did."
  fi
  sub1428v="$(hook1428 'gh issue view 1')"
  [ -z "$sub1428v" ] \
    && check "#1428 a human gh issue view is not rewritten by the real rtk through the hook" ok \
    || check "#1428 a human gh issue view is not rewritten by the real rtk through the hook" "got [$sub1428v]"
fi

# ---- rtk's integrity baseline still describes the hook beside it (claude-config#259 follow-up) ----
# rtk keeps a sha256 of this hook in .rtk-hook.sha256 and REFUSES TO RUN AT ALL when the two
# disagree: no rewriting, no token saving, and a tamper banner on every command. #259 edited the
# hook deliberately, to stop test runs being routed through a summariser that reported
# "PASS (0) FAIL (3)" for a run with 4356 passes, and the baseline was left describing the version
# before that edit. Nothing here noticed; the first sign was the banner.
#
# So the pair is checked HERE, on every run, rather than only when rtk happens to be invoked. That
# is what makes re-baselining safe: the baseline is not a thing somebody remembers to update, it
# is a thing that goes red in the same suite as the hook it describes (L225: the invariant between
# two stored values is checked by something that reads the VALUES).
RTK_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rtk-rewrite.sh"
RTK_BASELINE="$(dirname "$RTK_HOOK")/.rtk-hook.sha256"
# The command that re-records the baseline, held ONCE because both the failure message above and
# the check below that RUNS it read this one string. Two independent spellings of the same command
# is exactly what shipped the defect covered below.
RTK_REBASELINE_CMD="shasum -a 256 rtk-rewrite.sh | awk '{print \$1 \"  rtk-rewrite.sh\"}' > .rtk-hook.sha256"
if [ ! -f "$RTK_BASELINE" ]; then
  # Absent is its own answer, not agreement. Without a baseline rtk warns and establishes one, so
  # this is a state worth naming rather than passing over (L98).
  check "the rtk integrity baseline is present" "no .rtk-hook.sha256 beside the hook, so nothing records what rtk expects"
else
  rtk_recorded="$(awk 'NR==1{print $1}' "$RTK_BASELINE" 2>/dev/null)"
  rtk_actual="$(shasum -a 256 "$RTK_HOOK" 2>/dev/null | awk '{print $1}')"
  # Both halves read, and both required to be non-empty: two empty strings agree perfectly, and a
  # comparison that passes by reading nothing is the failure this exists to catch (L98, L178).
  if [ -z "$rtk_recorded" ] || [ -z "$rtk_actual" ]; then
    check "the rtk integrity baseline and the hook can both be read" \
      "recorded=[$rtk_recorded] actual=[$rtk_actual]"
  elif [ "$rtk_recorded" = "$rtk_actual" ]; then
    check "the rtk integrity baseline matches the hook beside it" ok
  else
    check "the rtk integrity baseline matches the hook beside it" \
      "recorded $rtk_recorded but the hook hashes to $rtk_actual, so rtk will refuse to run at all and print a tampering banner on every command. If the hook change was deliberate, re-record it: $RTK_REBASELINE_CMD"
  fi
fi
# The comparison is watched saying NO before it is believed, against a hash built here, or a check
# that has only ever agreed is not yet a check (L1).
rtk_probe_bad="0000000000000000000000000000000000000000000000000000000000000000"
[ "$rtk_probe_bad" = "${rtk_actual:-x}" ] \
  && check "the baseline comparison would notice a hash that does not match" "it read a deliberately wrong hash as matching" \
  || check "the baseline comparison would notice a hash that does not match" ok

# ---- and the baseline is in the FORMAT rtk will actually accept (claude-config#319) ----
# rtk parses this file and refuses the whole run with "Invalid hash format in ... (expected
# 'hash  filename')" unless the hash and the name are separated by TWO spaces, which is what
# shasum itself emits. The check above reads only the FIRST FIELD with awk, so it agreed with a
# file rtk would not read at all: on 2026-09-05 the baseline was re-recorded from the remedy this
# very message names, that remedy wrote ONE space, the suite went green, and every real rtk
# command on the machine started answering "Invalid hash format" and exiting 1 (L63: a guard must
# assert the quantity it exists to protect, never a proxy for it).
#
# Two things are checked, and the second is the one that would have caught it. The committed file
# has to match the format, and the REMEDY this suite tells you to run has to PRODUCE that format,
# proved by running it. A worked example is how a rule actually travels, so an example that
# contradicts the rule teaches the inverse and is then defended with the rule's authority (L562).
rtk_baseline_ok() { # rtk_baseline_ok <line>  -> 0 when rtk would accept it
  # Matched in the shell rather than through `printf ... | grep -q`, because a short circuiting
  # consumer can SIGPIPE its producer under `pipefail` and report a failure that never happened
  # (L183). test-pipefail-shortcircuit.sh caught exactly that here, in this function, on the run
  # that added it.
  [[ "$1" =~ ^[0-9a-f]{64}\ \ rtk-rewrite\.sh$ ]]
}
# The predicate is watched REFUSING the exact malformation that shipped, or it is not yet a check
# (L1). One space is a valid shasum-looking line and the awk reader above accepts it happily.
rtk_bad_line="$(printf '%s rtk-rewrite.sh' "${rtk_actual:-0000000000000000000000000000000000000000000000000000000000000000}")"
rtk_baseline_ok "$rtk_bad_line" \
  && check "the format check refuses the single space form rtk rejects" "it accepted it" \
  || check "the format check refuses the single space form rtk rejects" ok
rtk_baseline_line="$(awk 'NR==1{print}' "$RTK_BASELINE" 2>/dev/null)"
rtk_baseline_ok "$rtk_baseline_line" \
  && check "the committed baseline is in the format rtk accepts" ok \
  || check "the committed baseline is in the format rtk accepts" \
     "rtk needs '<hash>  rtk-rewrite.sh' with two spaces and the file holds [$rtk_baseline_line], so rtk refuses to run at all. Re-record it: $RTK_REBASELINE_CMD"

# The loop closer: run the remedy, in a throwaway directory, against a copy of this same hook, and
# require what it writes to be BYTE FOR BYTE the committed baseline. That proves the remedy is
# correct and that the committed file is what the remedy would produce, from ONE derivation rather
# than two that have to stay in step (L70).
RTK_SANDBOX="$TMPROOT/rebaseline"
mkdir -p "$RTK_SANDBOX"
cp "$RTK_HOOK" "$RTK_SANDBOX/rtk-rewrite.sh"
( cd "$RTK_SANDBOX" && eval "$RTK_REBASELINE_CMD" ) >/dev/null 2>&1
rtk_remedy_line="$(awk 'NR==1{print}' "$RTK_SANDBOX/.rtk-hook.sha256" 2>/dev/null)"
rtk_baseline_ok "$rtk_remedy_line" \
  && check "the remedy this suite names writes a file rtk would accept" ok \
  || check "the remedy this suite names writes a file rtk would accept" \
     "running it produced [$rtk_remedy_line]"
[ -n "$rtk_remedy_line" ] && [ "$rtk_remedy_line" = "$rtk_baseline_line" ] \
  && check "and reproduces the committed baseline exactly" ok \
  || check "and reproduces the committed baseline exactly" \
     "remedy wrote [$rtk_remedy_line] but the file holds [$rtk_baseline_line]"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
