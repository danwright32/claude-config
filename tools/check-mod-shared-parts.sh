#!/bin/bash
# check-mod-shared-parts.sh <mods dir>: what every mod shares lives once, in mod-kit, and no other
# mod keeps a copy (L613: the shared component plus the scan that fails on the next hand rolled
# copy). Before batch 2 of the mods milestone three guards each read shell commands their own way,
# and every review found a different hole in a different copy.
#
# The shared parts, each named by the code a copy cannot be written without:
#   reader    splitting a command on shell separators          use $.modkit.commands({ command })
#   quotes    tracking quote characters one by one              use $.modkit.commands({ command })
#   heredoc   reading a heredoc's opening                       use $.modkit.commands({ command })
#   card      drawing a tool result row (the boxed card)        use $.modkit.card({ toolUseId, title, lines }),
#             or $.modkit.blocked({ ... }) for a guard's refusal, which is one use of it (#663)
#   git       listing git's global options to find a subcommand use $.modkit.git({ words })
#   band      drawing the band above the prompt (AbovePrompt)   use $.modkit.bandRow({ ... })
#             Claude Code gives the band ONE drawing, so two mods hooking it fight over it (#610).
#             The band and a result row are each named by the component's name as a string, in
#             any quotes: the engine takes a filter however it is spelled (a spaced or quoted key,
#             a shorthand from a constant, the value on the next line) and an unfiltered ui.render
#             hook that tests e.component, and every one of them names it (#698: a probe of 11
#             hand rolled forms caught 3 when the scan matched `component: 'X'` on one line).
#   pane      drawing a card's parts (a run's strikethrough      use $.modkit.pane({ mod, id, lines, frame }),
#             from its data) or its left rule mark, as the      the band's row drawing in a pane, so the two
#             band does, in a mod's own pane                    cannot drift (#690). A pane drawn its own way,
#                                                               not as a card (the goals pane), is not a copy.
#   send      trying a refused message to another session again a plain $.session.send: mod-kit's
#             (a loop that stops once delivered, or the        session.send hook tries every mod's refused
#             || 'no reason given' fallback)                    send once more and tidies the reason (#688)
#   write-reader                                                use $.modkit.writes({ command, cwd, home }),
#             reading which files a shell command writes (a    the one reader (#705: three copies disagreed)
#             list naming tee, which every copy has)
#   working-tree                                                use $.modkit.workingTree({ path }), the one
#             finding the checkout a path sits in by walking   walk (#726: ask before saving needed the
#             up for its .git entry (.git standing as a        collision guard's, which no mod can import)
#             whole path part: '.git', /.git, /.git/HEAD;
#             never .gitignore or .github, #732)
#   program-reader                                              use the language, program and verdict on each
#             reading what a shell or interpreter runs, or     command $.modkit.pipeline({ command }) gives,
#             judging inline code by what it can do (naming    read and judged once (#712: no build kept the
#             nodejs, child_process or subprocess)             only copy, which mod-kit's writes then lacked)
#   press     a hooks file with a ui.press hook that names      on('modkit.press', ...): a click and a typed
#             mod-kit anywhere (any line, or a constant)        /press both raise it, so a button drawn as
#                                                               "type: /press <mod> <button>" where a click
#                                                               cannot land (#939) is never answered by a
#                                                               click alone
#
# And one a mod drawing its own Button must ASK (#939):
#   button    a hooks file drawing `<Button` must ask           draw the Button only where it answers true,
#             $.modkit.clickable in that file                   and say what to do instead elsewhere: the
#                                                               terminal reports clicks only fullscreen, and
#                                                               Apple Terminal only while a per tab switch
#                                                               no mod can read is on
#
# A known exception is a mod still holding its own copy until a named issue moves it. It is printed
# on every run, with that issue, rather than failing the run or passing in silence (L129, L523). None
# stands today: #712 moved the last (the collision guard's and no build's write readers, and the
# collision guard's walk for a checkout).
#
# A mod's tests may read with mod-kit's own readers rather than a stand-in (#730: a stand-in split
# inside quotes): a test cannot import another mod's files, so each such file is a copy under the
# mod's tests/mod-kit, at the path it has in mod-kit. Every copy must match mod-kit's byte for byte,
# or its tests read with a reader mod-kit no longer has (L422); one that differs, or copies nothing,
# fails the run, naming the cp that brings it back.
#
# And one shared part every mod must USE rather than must not copy (#707):
#   screen    a mod that answers a tool call itself (returns     ask $.modkit.screen(e) first, and answer with
#             a result rather than calling next) keeps the      its refusal: mod-kit asks the secret guard
#             call from every guard beneath it, the secret      wherever its folder sorts
#             guard among them
# Each tool.call hook is read on its own (#732, L135): one that answers with a `result:` must ask
# $.modkit.screen in its own body, since a screen in the hook beside it covers nothing, and a hook
# whose body is a named function is read where that function is defined (one that cannot be found
# fails, never passes). A mod that shows a call's input and then refuses without a result is held by
# its own tests (ask before saving asks from classic.PreToolUse instead).
#
# Only each mod's hooks/ is read: its tests may stand in for mod-kit, since a mod cannot import
# another mod's files. Comments are taken out first, by tools/lib/ts_source.py, the one reader of
# source every mod scan shares, and what is left on each line is read (#732): a comment is code for
# nothing, so it is never taken for a copy or a screen, and code beside a comment is still read.
#
# Exit codes, each distinct (L11): 0 none found (the count is printed, L98), 1 a copy found, each
# named with its file and line, 2 the mods folder does not exist, 3 no python3 to read the source
# with (L490: never a pass over nothing read).
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-shared-parts: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-shared-parts: python3 is not installed, so no mod's source was read." >&2
  exit 3
fi
TS_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ts_source.py"
# Each mod's hooks/ with its comments blanked, line for line, so every match names the real line.
stripped="$(mktemp -d "${TMPDIR:-/tmp}/check-mod-shared-parts.XXXXXX")" || exit 1
trap 'rm -rf "$stripped"' EXIT
if ! python3 "$TS_SOURCE" strip-hooks "$dir" "$stripped"; then
  echo "check-mod-shared-parts: a mod's source above could not be read, so it was not checked."
  exit 1
fi

# name|pattern|remedy. Patterns are extended regular expressions over each source line.
PARTS=(
  "reader|split\(/[^/]*&&|\$.modkit.commands({ command })"
  "quotes|=== '\"' \|\| [a-z]+ === \"'\"|\$.modkit.commands({ command })"
  "heredoc|<<\(\?!<\)|\$.modkit.commands({ command })"
  "card|[\"'\`]ToolResult[\"'\`]|\$.modkit.card({ toolUseId, title, lines }) (a guard's refusal: \$.modkit.blocked({ ... }))"
  "git|'--work-tree'|\$.modkit.git({ words })"
  "band|[\"'\`]AbovePrompt[\"'\`]|\$.modkit.bandRow({ ... })"
  "pane|strikethrough=\{[^}]*\.strikethrough\}|'\\\\u2502'|'│'|\$.modkit.pane({ mod, id, lines, frame }) (the band: \$.modkit.bandRow)"
  "send|\|\| *['\"]no reason given['\"]|\.isDelivered\) *return|a plain \$.session.send (mod-kit tries every mod's refused send once more)"
  "write-reader|['\"]tee['\"]|\$.modkit.writes({ command, cwd, home })"
  "working-tree|[\"'\`/]\\.git([\"'\`/]|\$)|\$.modkit.workingTree({ path })"
  "program-reader|child_process|subprocess|nodejs|the language, program and verdict on each command \$.modkit.pipeline({ command }) gives"
)

# $1 = mod  $2 = part -> the issue that ends that mod's known exception for that part, or nothing.
# None today: #712 moved the last, so this answers nothing until a new one is named here.
exception(){
  case "$1:$2" in
    *) ;;
  esac
}

n=0
failed=0
for d in "$dir"/*/; do
  [ -f "$d.claude-plugin/plugin.json" ] || continue
  n=$((n + 1))
  name="$(basename "$d")"
  [ "$name" = mod-kit ] && continue
  [ -d "$d/hooks" ] || continue
  sd="$stripped/$name/"
  for part in "${PARTS[@]}"; do
    label="${part%%|*}"; rest="${part#*|}"; pattern="${rest%|*}"; remedy="${rest##*|}"
    hits="$(grep -rnE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' -- "$pattern" "$sd/hooks" 2>/dev/null)"
    [ -n "$hits" ] || continue
    until_issue="$(exception "$name" "$label")"
    if [ -n "$until_issue" ]; then
      echo "check-mod-shared-parts: $name keeps its own $label, a known exception until $until_issue moves it onto $remedy."
      continue
    fi
    failed=1
    while IFS= read -r h; do
      echo "check-mod-shared-parts: $name keeps its own $label at ${h#"$sd"}: use $remedy from mod-kit instead."
    done <<< "$hits"
  done
  # copies (#712, #730): each file under the mod's tests/mod-kit is a copy of mod-kit's own, byte for
  # byte, so its tests read with the reader every mod uses.
  if [ -d "$d/tests/mod-kit" ]; then
    copied="$(cd "$d/tests/mod-kit" && find . -type f | sed 's#^\./##' | sort)"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ ! -f "$dir/mod-kit/$rel" ]; then
        failed=1
        echo "check-mod-shared-parts: $name's tests/mod-kit/$rel copies no file of mod-kit's, so it stands in for nothing: delete it."
      elif ! cmp -s "$d/tests/mod-kit/$rel" "$dir/mod-kit/$rel"; then
        failed=1
        echo "check-mod-shared-parts: $name's tests/mod-kit/$rel differs from mod-kit's own, so its tests read with a reader mod-kit no longer has: cp \"$dir/mod-kit/$rel\" \"${d%/}/tests/mod-kit/$rel\""
      fi
    done <<< "$copied"
  fi
  # press (#939): a file naming the ui.press event and mod-kit anywhere in its code, however the hook
  # is laid out: its call or its filter across lines, or the filter held in a constant (lessons review
  # of #957). A click alone reaches such a hook; mod-kit's typed /press raises modkit.press, which it
  # never sees. Comments are already taken out, so only code names them.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE "[\"'\`]mod-kit[\"'\`]" "$f" || continue
    failed=1
    while IFS= read -r h; do
      echo "check-mod-shared-parts: $name hooks ui.press for mod-kit's buttons at ${f#"$sd"}:${h%%:*}, which a click alone reaches: answer the press in on('modkit.press', ...) instead, which a typed /press reaches too."
    done <<< "$(grep -nE "[\"'\`]ui\.press[\"'\`]" "$f")"
  done <<< "$(grep -rlE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' "[\"'\`]ui\.press[\"'\`]" "$sd/hooks" 2>/dev/null)"
  # button (#939): a file drawing its own Button that never asks whether a click reaches it there.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE '\.modkit\.clickable\(' "$f" && continue
    failed=1
    while IFS= read -r h; do
      echo "check-mod-shared-parts: $name draws its own Button at ${f#"$sd"}:${h%%:*} but never asks \$.modkit.clickable(e) in that file, so it shows a button a click may not reach (Apple Terminal, the main screen): draw it only where that answers true, and say what to do instead elsewhere."
    done <<< "$(grep -nE '<Button\b' "$f")"
  done <<< "$(grep -rlE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' '<Button\b' "$sd/hooks" 2>/dev/null)"
  # screen (#707, per hook since #732): a tool.call hook answering with a result that never asks
  # mod-kit's screen in its own body.
  if ! found="$(python3 "$TS_SOURCE" unscreened "$d/hooks")"; then
    failed=1
    echo "check-mod-shared-parts: $name's tool.call hooks could not be read, so whether each asks \$.modkit.screen(e) first is not known."
    continue
  fi
  while IFS= read -r at; do
    [ -n "$at" ] || continue
    failed=1
    case "$at" in
      '?'*) echo "check-mod-shared-parts: $name's tool.call hook at /hooks/${at#?} answers through a named function that cannot be found in its file, so whether it asks \$.modkit.screen(e) first is not known: define it in the file that registers it." ;;
      *) echo "check-mod-shared-parts: $name answers a tool call itself in its tool.call hook at /hooks/$at but never asks \$.modkit.screen(e) first there, so the guards beneath it (the secret guard) never see that call: ask it before acting on the call, and answer with its refusal." ;;
    esac
  done <<< "$found"
done
echo "check-mod-shared-parts: $n mods checked in $dir"
exit "$failed"
