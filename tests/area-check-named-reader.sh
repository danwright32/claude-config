#!/bin/bash
# area-check-named-reader.sh: what the suites proving a script the area check lets through by name
# share (payload/mods/area-check/hooks/named.ts): tests/test-area-check-check-mods-read-only.sh and
# tests/test-area-check-shared-parts-read-only.sh. Sourced, never run. Each of those suites runs the
# real script from a throwaway checkout and is red when the run leaves the checkout changed, so what
# they must agree on lives here once: where the checkout is made, how it is listed before and after,
# and how the list of texts and the rule itself are asked.
#
# The suite sets ROOT (this checkout) and defines check (name, "ok" or the evidence) before sourcing.

# named_tmp <name>: the suite's temporary folder, as TMP, removed when the suite ends. Resolved,
# since git names a checkout by where it really is and macOS's temporary folder is a link.
# A failed mktemp must stop the suite: `cd ""` stays where it is, so TMP would be the folder the
# suite ran from and the EXIT trap would delete it. So the trap is set only once the folder is seen
# to be made and to resolve inside the temporary area; before that nothing has run.
named_tmp(){   # $1 = the name the folder starts with
  local made
  made="$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")" && [ -d "$made" ] || {
    echo "FAIL: $(basename "$0"): no temporary folder could be made, so nothing was run"
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  }
  TMP="$(cd "$made" && pwd -P)"
  case "$TMP" in "${TMPDIR:-/tmp}"*|/private/*|/tmp/*|/var/folders/*) ;; *)
    echo "FAIL: $(basename "$0"): the temporary folder resolved to $TMP, outside the temporary area, so nothing was run"
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
  esac
  trap 'rm -rf "$TMP"' EXIT
}

# Every path in a checkout outside its git folder, with what it holds: a file's hash, a link's target.
# The files are hashed in one run of shasum, never one a file: a suite lists a checkout a dozen times,
# and one process a file was a third of its wall clock (measured 2026-11-16, #3082).
whole(){   # $1 = checkout
  (cd "$1" && {
    find . -path ./.git -prune -o -type d -print | sed 's/^/dir /'
    find . -path ./.git -prune -o -type l -print | while IFS= read -r f; do printf 'link %s -> %s\n' "$f" "$(readlink "$f")"; done
    find . -path ./.git -prune -o -type f -print0 | xargs -0 shasum | sed 's/^\([0-9a-f]\{40\}\)  /\1 /'
  } | LC_ALL=C sort -k2)
}
# Every file git tracks or would track there, with its hash, or `gone` where it is no longer a file.
tracked(){   # $1 = checkout
  (cd "$1" && git ls-files -co --exclude-standard -z | tr '\0' '\n' > "$TMP/listing.names" && {
    while IFS= read -r f; do [ -f "$f" ] || printf 'gone %s\n' "$f"; done < "$TMP/listing.names"
    tr '\n' '\0' < "$TMP/listing.names" | xargs -0 shasum 2>/dev/null | sed 's/^\([0-9a-f]\{40\}\)  /\1 /'
  } | LC_ALL=C sort -k2)
}
status(){ git -C "$1" status --porcelain --untracked-files=all 2>&1; }
# Every line that differs between two listings. Through files, and read to its end, since a reader
# that stops early or a process substitution inside a captured function can lose lines on bash 3.2,
# and a lost line here would read as nothing having changed.
differing(){   # $1 = listing before  $2 = listing after
  printf '%s\n' "$1" > "$TMP/listing.before"; printf '%s\n' "$2" > "$TMP/listing.after"
  diff "$TMP/listing.before" "$TMP/listing.after" | grep '^[<>]'
}
# What changed between two listings, the first few lines of it on one line.
changed(){ differing "$1" "$2" | sed -n '1,6p' | paste -sd';' -; }

# named_texts <NAME>: the list named.ts keeps for the script, read by tests/area-check-named-texts.mjs
# -> sets listed (every line it printed), SCRIPT and TEXTS. Returns 1, having failed a check, when
# the list could not be read at all.
named_texts(){   # $1 = what named.ts exports the script by
  listed="$(node --experimental-strip-types --no-warnings "$ROOT/tests/area-check-named-texts.mjs" "$ROOT/payload/mods/area-check/hooks/named.ts" "$ROOT" "$1" \
    "$ROOT/payload/mods/mod-kit/hooks/commands.ts" 2>&1)" || {
    check "named.ts's $1 is read" "$listed"
    return 1
  }
  TEXTS="$(printf '%s\n' "$listed" | sed -n 's/^TEXT	//p')"
  SCRIPT="$(printf '%s\n' "$listed" | sed -n 's/^SCRIPT	//p')"
}
# One fact of that reading: LINES, RUNS, RAN, BYVALUE, or every PROBLEM.
named_fact(){ printf '%s\n' "$listed" | sed -n "s/^$1	//p"; }

# named_rule <NAME> <checkout> <file> <count>: the rule itself for that script, on mod-kit's real
# reader and real git (tests/area-check-named-rule.mjs), each of its checks one check here, and the
# number that ran held to the number the suite states (L288). It leaves the checkout changed.
named_rule(){   # $1 = what named.ts exports the script by  $2 = checkout  $3 = a file under its payload/mods  $4 = how many checks there are
  local ruled ran=0 verdict name evidence
  ruled="$(node --experimental-strip-types --no-warnings "$ROOT/tests/area-check-named-rule.mjs" "$ROOT/payload/mods/area-check/hooks/named.ts" \
    "$ROOT/payload/mods/mod-kit/hooks/writes.ts" "$ROOT/payload/mods/area-check/hooks/rules.ts" "$2" "$1" "$3" 2>&1)" || {
    check "the rule runs on the real reader" "$ruled"
    return 1
  }
  while IFS=$'\t' read -r verdict name evidence; do
    case "$verdict" in
      PASS) ran=$((ran + 1)); check "$name" ok ;;
      FAIL) ran=$((ran + 1)); check "$name" "$evidence" ;;
      *) [ -z "$verdict" ] || check "the rule's output is read" "an unexpected line: $verdict $name" ;;
    esac
  done <<< "$ruled"
  [ "$ran" -eq "$4" ] && check "all $4 checks of the rule ran" ok || check "all $4 checks of the rule ran" "$ran ran"
}
