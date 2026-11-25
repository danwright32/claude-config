#!/bin/bash
# mods-harness.sh: the one world the suites of tools/check-mods.sh run in (claude-config#3622).
#
# tests/test-mods.sh held every check of the mods gate, 516 of them, until it read 498 to 777
# seconds in six runs on GitHub's runners (2026-11-24 and 25), past half of run-all-tests.sh's 1,200
# second wall limit, one slow runner from being stopped there with no failing check (L315). Its
# sections are now three suites, cut by what each section was measured to cost (on the work MacBook
# on 2026-11-25: the real tree 147 s, section 9 47 s, all the rest 33 s, of 227 s):
#
#   tests/test-mods.sh               case 8, the real tree with the real claude where there is one
#   tests/test-mods-shared-parts.sh  section 9, what every mod shares
#   tests/test-mods-fixtures.sh      sections 1 to 7c and 10 to 13, then 14, which holds the three
#                                    together
#
# Every one of them runs check-mods.sh in the same world, so that world is here, once, and no suite
# holds a copy of it (L613): the throwaway folder, the stub claude and the stub compiler, the records
# every fixture is kept out of, the pinned compiler, and the result line. It is the opening of
# test-mods.sh moved here unchanged, but for REAL_BIN, the claude the real tree is checked with,
# which test-mods.sh alone finds, so no other piece can reach it (L2).
#
# It sits in tests/, beside the suites, never in payload/hooks/lib: that folder is carried to every
# Mac by the sync and is read as hook code by the hook scans, and tests/ already holds a harness
# sourced the same way (area-check-named-reader.sh). run-all-tests.sh runs only test-*.sh, so this
# file is never taken for a suite.
#
# Sourced, never run, by a suite that has set DIR (the tests folder) and ROOT (the checkout) and
# armed its own deadline (lib/suite-deadline.sh). A suite holds its checks, then ends with
# mods_harness_result.
#
# USE, in a suite:
#
#   . "$DIR/mods-harness.sh" || { ...refuse to run, SUITE-RESULT failed=1... }
#   runit "$M1"; [ "$code" -eq 0 ] && check "good mods pass" ok || check "good mods pass" "$out"
#   mods_harness_result   # last: the totals and the SUITE-RESULT line, returning 1 on a failure
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "mods-harness.sh is sourced by the mods suites (tests/test-mods*.sh), never run on its own." >&2
  exit 2
fi
if [ -z "${DIR:-}" ] || [ -z "${ROOT:-}" ]; then
  echo "FAIL: mods-harness.sh needs DIR (the tests folder) and ROOT (the checkout) set by the suite sourcing it."
  return 1
fi
CHECK="$ROOT/tools/check-mods.sh"
pass=0; fail=0
# MODS_HARNESS_NAMES, when it names a file, gets each check's name as it is run, one a line, passed
# or not: how the split was proved to hold every check of the whole (#3622), and how section 14 of
# test-mods-fixtures.sh reads what the real tree piece recorded.
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  [ -z "${MODS_HARNESS_NAMES:-}" ] || printf '%s\n' "$1" >> "$MODS_HARNESS_NAMES"
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-mods.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
# A refused or failed mod's whole output is kept on disk (#1788), so every fixture here that fails a
# mod on purpose keeps its output in this run's own folder, never in this Mac's real record. Only the
# real tree (case 8) keeps its failures where the caller said, or in the default place.
REAL_KEPT_SET="${CHECK_MODS_FAILURE_OUTPUT+set}"; REAL_KEPT="${CHECK_MODS_FAILURE_OUTPUT-}"
export CHECK_MODS_FAILURE_OUTPUT="$TMPROOT/kept-output"
# The same for the record of the Claude Code build the mods last passed on (#3297): a fixture passing
# on the stub's build must never move this Mac's record, so it is off for every case but the real
# tree (case 8), and case 6d points it at a scratch file of its own.
REAL_LAST_SET="${CHECK_MODS_LAST_PASSED+set}"; REAL_LAST="${CHECK_MODS_LAST_PASSED-}"
export CHECK_MODS_LAST_PASSED=""
# The sections below that run the real pinned compiler look for it in this checkout, which in a new
# worktree has none until it is linked or installed (#1496), so that is done first, here, and why it
# could not be is carried on every line that says those sections were not measured. From the npm
# cache only, here and in every check this suite starts: a suite never asks the registry, so where
# the cache lacks it the sections say UNMEASURED with the reason and the npm ci command.
export PINNED_TS_OFFLINE=1
PINNED_WHY=""
# The library that installs it is found from this file's own place, not from the suite's ROOT: the
# Slack drafts gate reads what a sourced file sources from what that file sets itself, and refuses a
# run whose source path it cannot work out. A name of its own, never ROOT or DIR, since a name this
# file binds is unknown to the gate in the suite from then on, and the suites' own python3 runs place
# their imports by ROOT.
MODS_HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${CHECK_MODS_TS_DIR:-}" ]; then
  if . "$MODS_HARNESS_ROOT/tools/lib/pinned-compiler.sh"; then
    if pinned_compiler_ensure "$ROOT/tools/typescript"; then
      [ -z "$PINNED_TS_DID" ] || echo "test-mods: the pinned TypeScript compiler was $PINNED_TS_DID."
    else
      PINNED_WHY=" It could not be installed automatically: ${PINNED_TS_WHY%.}."
    fi
  else
    PINNED_WHY=" tools/lib/pinned-compiler.sh, which installs it, is missing."
  fi
fi

mkmod(){   # $1 = mods dir  $2 = name
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "x" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '{ "modules": ["./register.ts"] }\n' > "$1/$2/hooks/hooks.json"
  printf 'export const register = () => {}\n' > "$1/$2/hooks/register.ts"
  printf '{ "extends": "./.claude-plugin/types/tsconfig.json" }\n' > "$1/$2/tsconfig.json"
}
# The stub: validate refuses any mod whose folder name contains "broken"; test fails any mod whose
# folder name contains "redtest"; every call is logged so a case can assert what was asked.
FAKE="$TMPROOT/claude"; LOG="$TMPROOT/calls"
cat > "$FAKE" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
[ "$1" = --version ] && { echo "${FAKE_CC_VERSION:-2.1.291} (Claude Code)"; exit 0; }
case "$1 $2" in
  "plugin validate") case "$3" in *broken*) printf '  hooks: bad event\n\nValidation failed\n'; exit 1 ;;
      # Claude Code 2.1.328's own lines for a Pane hook (#3285): naming no owner and opening no pane
      # (mod-kit before the fix), naming no owner and opening its own, and naming every owner.
      *deafpane*) printf '  \342\235\257 ./register.tsx hooks: session.start, ui.render{component=AbovePrompt} (default matcher key: plugin), ui.render{component=Pane} (default matcher key: plugin), ui.render{component=ToolResult}\n  \342\235\257 ./register.tsx calls: $.state.get, $.ui.log, $.ui.resolve, $.ui.toast\n'; exit 0 ;;
      *ownpane*) printf '  \342\235\257 ./register.tsx hooks: ui.render{component=Pane, requestId=goals} (default matcher key: plugin)\n  \342\235\257 ./register.tsx calls: $.ui.close (via hide), $.ui.open (via openPane), $.ui.resolve\n'; exit 0 ;;
      *starpane*) printf '  \342\235\257 ./register.tsx hooks: ui.render{component=AbovePrompt} (default matcher key: plugin), ui.render{component=Pane, plugin=*}\n  \342\235\257 ./register.tsx calls: $.state.get, $.ui.resolve\n'; exit 0 ;;
    esac; echo 'Validation passed' ;;
  "plugin test") case "$3" in
      *redtest*) printf ' 0 pass\n 1 fail\n'; exit 1 ;;
      # Claude Code's own answer while its cached rollout switch is saved off (2.1.289, #740).
      *switchedoff*) printf 'hooks modules are turned off in this process: the rollout switch was saved off. Start `claude` once with network access, then run the tests again\n'; exit 1 ;;
      # A failure with no verdict line the reason filter keeps.
      *noverdict*) printf 'line one\nline two\nsomething odd happened\n'; exit 7 ;;
    esac; printf ' 1 pass\n 0 fail\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$FAKE"
# Every case not about types runs with a compiler stub that passes everything, so a fixture's
# placeholder code is never judged by the real compiler, which a checkout with the pinned one
# installed would otherwise find and run against the pinned types (#953).
TSC_PASS="$TMPROOT/tsc-pass"; printf '#!/bin/bash\nexit 0\n' > "$TSC_PASS"; chmod +x "$TSC_PASS"
runit(){   # $1 = mods dir -> sets out and code
  : > "$LOG"
  out="$(STUB_LOG="$LOG" CLAUDE_BIN="$FAKE" TSC_BIN="$TSC_PASS" bash "$CHECK" "$1" 2>&1)"; code=$?
}

# The shared parts check: section 9 (test-mods-shared-parts.sh) runs it and the last check of section
# 13 (test-mods-fixtures.sh) holds it executable, so it is named once, here.
SHARED="$ROOT/tools/check-mod-shared-parts.sh"

# The totals and the agreed result line run-all-tests.sh reads, returning 1 when anything failed,
# so a suite whose last command this is exits as it should.
mods_harness_result(){
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}
