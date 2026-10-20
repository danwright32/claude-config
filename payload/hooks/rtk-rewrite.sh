#!/usr/bin/env bash
# rtk-hook-version: 2
# RTK Claude Code hook: rewrites commands to use rtk for token savings.
# Requires: rtk >= 0.23.0, jq
#
# This is a thin delegating hook: all rewrite logic lives in `rtk rewrite`,
# which is the single source of truth (src/discover/registry.rs).
# To add or change rewrite rules, edit the Rust registry, not this file.

if ! command -v jq &>/dev/null; then
  echo "[rtk] WARNING: jq is not installed. Hook cannot rewrite commands. Install jq: https://jqlang.github.io/jq/download/" >&2
  exit 0
fi

if ! command -v rtk &>/dev/null; then
  echo "[rtk] WARNING: rtk is not installed or not in PATH. Hook cannot rewrite commands. Install: https://github.com/rtk-ai/rtk#installation" >&2
  exit 0
fi

# Version guard: rtk rewrite was added in 0.23.0.
# Older binaries: warn once and exit cleanly (no silent failure).
RTK_VERSION=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | awk 'NR <= 1')
if [ -n "$RTK_VERSION" ]; then
  MAJOR=$(echo "$RTK_VERSION" | cut -d. -f1)
  MINOR=$(echo "$RTK_VERSION" | cut -d. -f2)
  # Require >= 0.23.0
  if [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 23 ]; then
    echo "[rtk] WARNING: rtk $RTK_VERSION is too old (need >= 0.23.0). Upgrade: cargo install rtk" >&2
    exit 0
  fi
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Delegate all rewrite logic to the Rust binary.
# rtk rewrite exits 1 when there's no rewrite: hook passes through silently.
REWRITTEN=$(rtk rewrite "$CMD" 2>/dev/null) || exit 0

# Every refusal below is judged against EVERY rtk invocation in the rewritten command, never only
# its first word (claude-config#399).
#
# rtk rewrites each part of a compound command separately, so `cd x && diff a b` comes back as
# `cd x && rtk diff a b`. The refusals used to read the first word of the rewrite, which there is
# `cd`, so none of them ever saw the `rtk diff`. On 2026-09-17 exactly that shape, `cd ... && git
# show ... > f; diff <(sed ...) ~/.claude/CLAUDE.md | head -20; git log ...`, printed
# "[ok] Files are identical" for two files cmp said differ at line 99, with the diff refusal below
# already installed. The blind spot was shared by every refusal, the `rtk read` and test summariser
# ones included, so the fix is here where they are all applied and not in any one of them (L30).
#
# The scan errs toward refusing. Shell punctuation and quotes become word breaks and every word
# that is exactly `rtk` counts as an invocation, so a quoted argument spelling out `rtk diff` also
# refuses. That costs a token saving on a rare command and cannot cost a verdict. A refused
# destination anywhere refuses the WHOLE rewrite, and the command runs exactly as written: putting
# back just the one part would mean editing a shell command by matching text, which is its own
# way of running something nobody wrote (L266). Compound commands with no refused destination in
# them are still rewritten, so git, gh and the rest keep saving tokens.
rtk_help_text="$(rtk --help 2>/dev/null)"

rtk_refused_destination() { # rtk_refused_destination <subcommand> <first argument>  -> 0 to refuse
local rtk_dest_sub="$1" rtk_dest_verb="$2"

# NEVER rewrite a command into `rtk read` (downbeat#254).
#
# `rtk read` STRIPS COMMENT LINES and renumbers what remains from 1. Measured
# 2026-08-17 on rtk 0.31.0: a 51 line Swift file came back as 28 lines. So every
# line number taken from it is wrong AND plausible, which is worse than mangled
# output, because a wrong line number looks exactly like a line number. Three
# consecutive planning passes cited wrong file:line pairs for this reason and
# each one corrected the previous pass's numbers rather than suspecting the
# instrument.
#
# This refuses by the DESTINATION rather than by the source command. rtk's own
# `[hooks] exclude_commands` setting honours `cat` but is ignored for `head` and
# `tail` (measured on 0.31.0 with all three listed), so a source based list both
# misses those two and would miss the next command that starts mapping here.
# Whatever produced it, `rtk read` is the thing that corrupts the output.
#
# Everything else still goes through rtk, which is the point: git, gh and the
# rest keep saving tokens. Only file reads pass through untouched.
if [ "$rtk_dest_sub" = "read" ]; then return 0; fi

# NEVER rewrite a TEST RUN into an rtk summariser (claude-config#259).
#
# Twice on 2026-09-01 a full Playwright run came back as exactly 18 bytes, `PASS (0) FAIL (3)`, and
# nothing else. Both commands EXITED 0 and the true results were 4356 and 4359 passed with nothing
# failed, confirmed by re-running with a different reporter. Two properties compound: it invented
# three failures that did not exist, and it discarded the entire underlying output, so there was
# nothing left to cross-check against. The same parser failing the other way round reports PASS on
# a red suite by the same mechanism, and there would be no output left to contradict it either.
#
# It is size dependent, so the condensing engages exactly on the runs too long to eyeball, and
# intermittent, so a correct summary yesterday says nothing about today.
#
# A summary that can disagree with the exit code, while being the only thing printed, is not a
# summary a reader can rely on. A test verdict is the one output where being wrong is
# indistinguishable from being right, so these pass through unfiltered. Everything else still goes
# through rtk, which is the point: git, gh and the rest keep saving tokens.
#
# Refused by DESTINATION, like `rtk read` above, and for the same reason: whatever produced it,
# the summariser is the thing that corrupts the output.

# The `test` VERB, wherever it appears as the first argument. rtk's help describes `cargo`, `go`,
# `dotnet` and `npm` as compact output for those tools generally, so the subcommand alone cannot
# tell `cargo test` from `cargo build`, and only the verb makes it a verdict.
if [ "$rtk_dest_verb" = "test" ]; then return 0; fi

# The floor: summarisers whose whole job is a test verdict. Held in code AND checked by the
# derivation below, so neither is the only guard (L96).
case " test playwright pytest vitest " in
  *" $rtk_dest_sub "*) return 0 ;;
esac

# And derived from rtk's OWN subcommand list, so a summariser this hook has never heard of is
# refused because rtk says it runs tests, rather than because somebody remembered to add it (L41).
# A help output that cannot be read finds nothing and refuses nothing extra, which is why the floor
# above is not folded into it: the derivation going quiet must not take the known cases with it.
#
# It errs toward refusing, and the cost of that is measured rather than assumed. Against rtk 0.31.0
# it also catches `dotnet` (its description lists build/test/restore/format) and `verify` (it runs
# TOML filter inline tests), neither of which is purely a test verdict. Both simply run unfiltered,
# which loses some token saving and cannot lose a result, and neither is used by any project here.
if [ -n "$rtk_dest_sub" ] && printf '%s\n' "$rtk_help_text" | awk -v want="$rtk_dest_sub" '
     $1 == want && tolower($0) ~ /test/ { found = 1 }
     END { exit found ? 0 : 1 }
   '; then
  return 0
fi

# NEVER rewrite into a destination MEASURED to report a different verdict than the tool it
# replaces (claude-config#318, claude-config#319).
#
# Two measurements against rtk 0.31.0 on 2026-09-05. `rtk diff` on two one line files that differ
# prints the difference and EXITS 0, where the real diff exits 1, so anything judging by the exit
# code reads "different" as "same" (L184). And comparing a regenerated lessons index against the
# committed one, it printed "[ok] Files are identical" for two files that genuinely differ; cmp on
# the same pair reported "differ: char 44885, line 206", and a repeat of the same command a minute
# later reported the difference correctly. That half is intermittent, which is worse than always
# wrong: it was caught only because the line was read by hand afterwards.
#
# A comparison verdict has the same property as the test verdict above, that being wrong is
# indistinguishable from being right, and it is worse in one way: the two things a reader could
# cross-check against each other are the output and the exit code, and the exit code here carries
# no verdict at all.
#
# `rtk find` is the second, found by the check rather than by a person: `find ./no-such-dir` exits
# 1 and `rtk find ./no-such-dir` exits 0, so a search over a path that does not exist, a typo or
# something since moved, reads as a search that ran and found nothing (L100, L320).
#
# No derivation from rtk's help for these, unlike the summarisers above. The only thing a help line
# offers to match on is a word in a description, and the day `git`'s description mentions diffs
# that match refuses every git rewrite, which is the largest saving this hook exists for. What
# stops this list being the only guard is not a cleverer pattern, it is a MEASUREMENT:
# `check-rtk-exit-fidelity.sh` runs a genuinely failing case and a genuinely succeeding one through
# both the real tool and whatever this hook substitutes, and fails when a destination it ALLOWS
# disagrees. So the next liar is found by the check rather than by somebody remembering to add it
# here (L96), and a destination listed here is reported by that check as contained rather than as
# a finding.
#
# `rtk git diff` is a different destination and was measured to carry its exit code through (a
# dirty tree gave 1 through both the real git and rtk), so it is untouched here and
# `git diff --quiet` goes on answering. So do `rtk ls`, `rtk git status` and `rtk git log`, all
# measured to agree in both directions.
#
# `cmp` needs no refusal because rtk 0.31.0 does not rewrite it at all, so it always runs raw; the
# exit fidelity check probes it for the day that changes (claude-config#399).
case " diff find " in
  *" $rtk_dest_sub "*) return 0 ;;
esac

return 1
}

# Every word that is exactly `rtk`, with the two words after it, one invocation per line. Read
# through a here string rather than a pipe, so a refusal exits the hook and not a subshell.
rtk_invocations="$(printf '%s\n' "$REWRITTEN" | tr ';&|()`<>{}"'"'" '            ' | awk '
  { for (i = 1; i <= NF; i++) if ($i == "rtk") print $(i + 1) " " $(i + 2) }
')"
while read -r rtk_dest_sub rtk_dest_verb; do
  [ -n "$rtk_dest_sub" ] || continue
  if rtk_refused_destination "$rtk_dest_sub" "$rtk_dest_verb"; then exit 0; fi
done <<< "$rtk_invocations"

# NEVER rewrite a command in which an rtk invocation's OUTPUT is read by another program
# (claude-config#1419).
#
# rtk's output is a summary written for a person, and a pipe or a redirect hands it to a program
# instead, which then works on the summary as if it were the data. On 2026-10-20
# `grep "|first|" nsf-sep.txt | awk ... | sort | head -60 | cut -f2` drew a 31 line "sample" built
# from rtk grep's header lines ("2 matches in 1F:", "[file] ... (2):", line number prefixes) with
# no error, caught only because the counts looked wrong. Dan's decision on the issue, 2026-10-20:
# "Leave grep unrewritten when its output is piped or redirected."
#
# The rule is about where the output GOES, so it holds for every destination, not grep alone.
# Measured against rtk 0.31.0 the same day: `rtk git log | wc -l` counted 1 line where git gave 5,
# `rtk git diff > p` wrote a stat summary in place of a patch, and `rtk ls | cat` and
# `rtk git status | cat` both changed what the next command read. One predicate, one rule (L30).
# A command whose output only the person reads keeps its rewrite and its token saving.
#
# The scan reads the rewritten command as the shell would, closely enough to tell a real pipe from
# a quoted one (`grep "a|b" f` has no pipe), and treats as "read by a program": a pipe (`|`, `|&`),
# any redirect of standard output (`>`, `>>`, `>|`, `1>`, `&>`, `>&2`), and capture by the shell
# (`$(...)`, backticks, `<(...)`, `>(...)`). A group, subshell, loop or `if` holding an rtk
# invocation counts as one command for its own pipe or redirect. Standard error alone (`2>/dev/null`) changes nothing
# the next program reads, so it keeps the rewrite, and so do input redirects and here documents,
# whose bodies are skipped rather than read as commands, except that an unquoted delimiter's body
# holding a substitution with the word rtk in it is refused, since the shell expands it. A command it cannot balance, an unclosed
# quote, a stray `)` or a case pattern, is refused rather than guessed at, which costs a token saving and cannot
# cost the data (L98).
rtk_output_read_by_program() { # rtk_output_read_by_program <command>  -> 0 to refuse
  printf '%s' "$1" | awk '
    { s = (NR > 1) ? s "\n" $0 : $0 }
    function push(t) {
      depth++; ctx[depth] = t; rtk[depth] = 0; out[depth] = 0; grp[depth] = 0
      # A nested command starts its own words; a double quote only continues the current one.
      if (t != "dq") { word = ""; inword = 0; wordq = 0; atcmd = 1 }
    }
    function endcmd() { if (rtk[depth] && out[depth]) bad = 1; rtk[depth] = 0; out[depth] = 0; atcmd = 1 }
    function flushword(   k) {
      if (inword && !wordq && word == "rtk") {
        rtk[depth] = 1; grp[depth] = 1
        for (k = 1; k <= depth; k++)
          if (ctx[k] == "cmdsub" || ctx[k] == "procsub" || ctx[k] == "bt") bad = 1
      }
      # A loop or conditional is ONE command to the pipe or redirect after its closing word, so
      # `for ...; do rtk ls; done | cat` is judged like a group.
      if (inword && atcmd) {
        if (!wordq && word ~ /^(for|while|until|if|case|select)$/) push("kw")
        else if (!wordq && word ~ /^(done|fi|esac)$/ && ctx[depth] == "kw") { popgroup(); atcmd = 0 }
        else if (!wordq && word ~ /^(do|then|else|elif|!|time|[A-Za-z_][A-Za-z0-9_]*=.*)$/) atcmd = 1
        else atcmd = 0
      } else if (inword) atcmd = 0
      word = ""; inword = 0; wordq = 0
    }
    function popgroup(   inner) {
      inner = grp[depth]; endcmd(); depth--
      if (inner) { rtk[depth] = 1; grp[depth] = 1 }
    }
    END {
      n = length(s); i = 1; depth = 0; ctx[0] = "top"; bad = 0; hd_n = 0; atcmd = 1
      while (i <= n && !bad) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1)
        if (ctx[depth] == "dq") {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { depth--; inword = 1; wordq = 1; i++; continue }
          if (c == "$" && nx == "(") { push("cmdsub"); i += 2; continue }
          if (c == "`") { push("bt"); i++; continue }
          i++; continue
        }
        if (c == "'"'"'") {
          j = index(substr(s, i + 1), "'"'"'")
          if (j == 0) { bad = 1; break }
          i += j + 1; inword = 1; wordq = 1; continue
        }
        if (c == "\\") { inword = 1; wordq = 1; i += 2; continue }
        if (c == "\"") { inword = 1; wordq = 1; push("dq"); i++; continue }
        if (c == "$" && nx == "(") { flushword(); push("cmdsub"); i += 2; continue }
        if (c == "$" && nx == "{") {
          j = index(substr(s, i + 2), "}")
          if (j == 0) { bad = 1; break }
          inword = 1; wordq = 1; i += j + 2; continue
        }
        if (c == "`") {
          flushword()
          if (ctx[depth] == "bt") popgroup(); else push("bt")
          i++; continue
        }
        if (c == "#" && !inword) {
          while (i <= n && substr(s, i, 1) != "\n") i++
          continue
        }
        if (c == " " || c == "\t") { flushword(); i++; continue }
        if (c == "\n") {
          flushword(); endcmd(); i++
          # Here document bodies are data, not commands: skip each one to its delimiter line. With
          # an UNQUOTED delimiter the shell still expands $(...) and backticks in the body, so a
          # body line holding a substitution and the word rtk is a captured invocation, refused.
          for (k = 1; k <= hd_n; k++) {
            while (i <= n) {
              rest = substr(s, i); j = index(rest, "\n")
              line = j ? substr(rest, 1, j - 1) : rest
              if (hd_dash[k]) sub(/^\t+/, "", line)
              i = j ? i + j : n + 1
              if (line == hd[k]) break
              if (!hd_quoted[k] && line ~ /(\$\(|`)/ && line ~ /(^|[^A-Za-z0-9_-])rtk([^A-Za-z0-9_-]|$)/) bad = 1
            }
          }
          hd_n = 0
          continue
        }
        if (c == ";") { flushword(); endcmd(); i++; continue }
        if (c == "&") {
          flushword()
          if (nx == "&") { endcmd(); i += 2; continue }
          if (nx == ">") { out[depth] = 1; i += 2; if (substr(s, i, 1) == ">") i++; continue }
          endcmd(); i++; continue
        }
        if (c == "|") {
          flushword()
          if (nx == "|") { endcmd(); i += 2; continue }
          if (rtk[depth]) { bad = 1; break }
          endcmd(); i++; if (substr(s, i, 1) == "&") i++
          continue
        }
        if (c == ">") {
          if (nx == "(") { flushword(); push("procsub"); i += 2; continue }
          fd = 1
          if (inword && !wordq && word ~ /^[0-9]+$/) { fd = word + 0; word = ""; inword = 0 } else flushword()
          if (fd == 1) out[depth] = 1
          i++; c2 = substr(s, i, 1)
          if (c2 == ">" || c2 == "|" || c2 == "&") i++
          continue
        }
        if (c == "<") {
          if (nx == "(") { flushword(); push("procsub"); i += 2; continue }
          flushword()
          if (nx == "<" && substr(s, i + 2, 1) == "<") { i += 3; continue }
          if (nx == "<") {
            i += 2; dash = 0
            if (substr(s, i, 1) == "-") { dash = 1; i++ }
            while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
            delim = ""; quoted = 0
            while (i <= n) {
              d = substr(s, i, 1)
              if (d ~ /[ \t\n;|&<>()]/) break
              if (d != "\"" && d != "'"'"'" && d != "\\") delim = delim d; else quoted = 1
              i++
            }
            hd[++hd_n] = delim; hd_dash[hd_n] = dash; hd_quoted[hd_n] = quoted
            continue
          }
          i++; c2 = substr(s, i, 1); if (c2 == "&" || c2 == ">") i++
          continue
        }
        if (c == "(") { flushword(); push("paren"); i++; continue }
        if (c == ")") {
          flushword()
          # A `)` that closes nothing it can name (a case pattern, a stray) is not guessed at.
          if (depth == 0 || ctx[depth] == "brace" || ctx[depth] == "bt" || ctx[depth] == "kw") { bad = 1; break }
          popgroup(); i++; continue
        }
        if (c == "{" && !inword && (nx == " " || nx == "\t" || nx == "\n")) { push("brace"); i++; continue }
        if (c == "}" && !inword && ctx[depth] == "brace") { popgroup(); i++; continue }
        word = word c; inword = 1; i++
      }
      if (!bad) { flushword(); if (depth != 0) bad = 1; else endcmd() }
      exit (bad ? 0 : 1)
    }
  '
}
if rtk_output_read_by_program "$REWRITTEN"; then exit 0; fi

# No change: nothing to do.
if [ "$CMD" = "$REWRITTEN" ]; then
  exit 0
fi

ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

jq -n \
  --argjson updated "$UPDATED_INPUT" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "RTK auto-rewrite",
      "updatedInput": $updated
    }
  }'
