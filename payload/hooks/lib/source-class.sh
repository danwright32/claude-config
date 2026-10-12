#!/usr/bin/env bash
#
# source-class.sh: is this changed file a TEST, or shipped SOURCE?
#
# Sourced, never executed. The classification two push gates share:
#   require-tests-before-push.sh  counts a change as needing a test (source) or being one (test)
#   simplify-before-push.sh       judges the source files in a push for simplification
#
# It lived inline in require-tests-before-push.sh until a second gate needed the same predicate.
# Copying it would have made two same-named classifiers either side of a boundary, which drift, and
# the drift is silent in the worst direction: one gate calling a file source while the other calls
# it a test (L263, L370, L613). So it moved here, and both gates source it.
#
# The path is handed to grep as a HERE-STRING (`grep ... <<< "$f"`), never piped from printf, the
# same shape lib/push-scope.sh uses and for the same reason (claude-config#403, L183): `printf | grep -q`
# under pipefail reports the SIGPIPE from grep leaving on its first match as the pipeline's status.
# The inputs here are short paths, well under the size where that bites, but the canonical shared
# classifier should carry no hazard at all, so test-pipefail-shortcircuit.sh stays clean of it.
#
# Each function is defined exactly once; test-source-class.sh fails on a second definition, because
# bash keeps the last one without a word (the push-scope.sh precedent, claude-config#440). Both are
# pure: they read the one path argument and return, touching no globals.

# A path that is a TEST file, by the conventions across every project here. The long tail of
# branches each carries the issue and the failure that added it; they are kept because a convention
# written as one project's directory is absent the moment the next project adopts it, and would read
# as coverage while covering nothing (L362).
is_test() {
  local f="$1"
  grep -Eiq '(^|/)(tests?|spec|__tests__|__mocks__)/' <<< "$f" && return 0
  # Xcode test target folders (claude-config#930). Xcode names a test target's folder after the
  # target, `<Name>Tests` (OvertureTests, OvertureHostedTests, OvertureUITests), and a shared
  # helpers target is commonly `TestSupport`. A suite file in one whose own name does not end in
  # Tests read as SOURCE, so an Overture push that only added cases to
  # mac/OvertureTests/EngineDivergenceGate.swift was refused as untested and overridden.
  #
  # Deliberately CASE SENSITIVE and on a DIRECTORY segment that ENDS in the word, unlike the line
  # above: matched case blind, every folder whose name ends in the letters "tests" (contests/)
  # would count as a test directory, and a source file there could ride through the gate.
  grep -Eq '(^|/)[^/]*(Tests|TestSupport)/' <<< "$f"         && return 0
  grep -Eiq '\.(test|spec)\.[a-z0-9]+$' <<< "$f"            && return 0
  # `test-foo.ts` / `test_foo.js` runnable test scripts (common in a scripts/
  # dir), but NOT test-only helpers like test-utils / test-setup / test-mocks.
  if grep -Eiq '(^|/)test[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs)$' <<< "$f" \
     && ! grep -Eiq '(^|/)test[-_](utils?|helpers?|setup|fixtures?|mocks?|data|config)\.' <<< "$f"; then
    return 0
  fi
  grep -Eiq '(^|/)test_[^/]+\.py$' <<< "$f"                 && return 0
  grep -Eiq '_test\.(py|go|rb|dart|exs?)$' <<< "$f"         && return 0
  # Deno names its tests `foo_test.ts`, which is the convention Supabase edge
  # function tests follow. Without this they read as untested source code.
  grep -Eiq '_test\.(ts|tsx|js|jsx|mjs|cjs)$' <<< "$f"       && return 0
  grep -Eiq '_spec\.rb$' <<< "$f"                           && return 0
  # `<rule>.cases.js` beside `<rule>.js` (ovation#130). Ovation's design rules ship as executable
  # functions with their cases in a sibling file, run by the ordinary suite. The classifier saw the
  # rule as source and the cases as nothing, so a push adding two cases, one of which failed on the
  # code as it stood, was blocked as untested and overridden. Those cases change every time a rule
  # does, and an override that becomes routine stops being a decision, which is how a gate is worn
  # down to nothing (L36).
  #
  # Matched by CONVENTION, not by that project's directory, for the reason every other branch here
  # is: a rule written as one repository's path is absent the moment the next project adopts the
  # convention, and it reads as coverage while covering nothing (L362).
  grep -Eiq '\.cases\.(ts|tsx|js|jsx|mjs|cjs)$' <<< "$f"      && return 0
  # Test or Tests as a WORD before the extension: capitalised (FooTests.swift, FooTest.kt), or lower
  # case after a separator or as the whole name (foo_test.scala, test.swift). Deliberately CASE
  # SENSITIVE: matched case blind it took the last letters of ordinary names, so Latest.swift and
  # Contests.swift counted as tests and could satisfy the zero test floor for a source change.
  grep -Eq '(Tests?|(^|[/_-])tests?)\.(java|kt|cs|swift|scala)$' <<< "$f" && return 0
  grep -Eiq '(^|/)conftest\.py$' <<< "$f"                   && return 0
  # Shell suites (claude-config#95). A whole language of tests was invisible here, and the config
  # repo's suite is entirely shell: a push carrying a one line Python change and the assertion
  # covering it, in the same commit, was blocked as untested and the change was dropped rather
  # than overridden. A gate that refuses correct work teaches the override habit, and once that is
  # habit it stops blocking the pushes it should.
  #
  # Same helper exclusion as the JavaScript branch above, for the same reason: a file of shared
  # fixtures is not a test of anything, and counting one would let a real change ride in beside it.
  #
  # Deliberately NOT paired with adding .sh to is_source. That would start gating every shell edit
  # in every project at once, which is a separate decision with a much wider blast radius, and one
  # nobody has asked for. The consequence of leaving it is stated rather than hidden: a change to a
  # shell script still needs no test of its own here.
  if grep -Eiq '(^|/)(test[-_][^/]+|[^/]+[-_]test)\.(sh|bash|zsh)$' <<< "$f" \
     && ! grep -Eiq '(^|/)test[-_](utils?|helpers?|setup|fixtures?|mocks?|data|config)\.' <<< "$f"; then
    return 0
  fi
  return 1
}

is_source() {
  local f="$1"
  grep -Eiq '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|rb|java|kt|kts|swift|scala|c|cc|cpp|h|hpp|cs|php|ex|exs|dart|m|mm)$' <<< "$f" || return 1
  grep -Eiq '(^|/)(node_modules|vendor|dist|build|out|coverage|\.next|__generated__|generated|migrations?)/' <<< "$f" && return 1
  grep -Eiq '\.d\.ts$' <<< "$f" && return 1
  grep -Eiq '(^|/)[^/]*\.(config|setup|conf)\.[a-z0-9]+$' <<< "$f" && return 1
  # One-off analysis scripts (scripts/check-*.js etc.) are throwaway
  # investigation tools, not shipped behavior -> exempt from the gate.
  grep -Eiq '(^|/)scripts/check[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs|py)$' <<< "$f" && return 1
  # Production smoke scripts (scripts/smoke-*.ts) are hand-run verification tools
  # that hit the live system, so they cannot carry their own CI unit test ->
  # exempt them too, else every new smoke script needs a SKIP_TEST_CHECK
  # override (Slate #529, hit adding scripts/smoke-523-stickiness.ts in PR #528).
  grep -Eiq '(^|/)scripts/smoke[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs|py)$' <<< "$f" && return 1
  # Hand-run diagnostics (scripts/diag-*.mjs, e.g. the live Google/SF credential
  # probes) are the same class as check-*/smoke-*: not shipped behavior and not
  # CI-testable -> exempt from the gate.
  grep -Eiq '(^|/)scripts/diag[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs|py)$' <<< "$f" && return 1
  return 0
}
