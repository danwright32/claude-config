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
#
# A known exception is a mod still holding its own copy until a named issue moves it. It is printed
# on every run, with that issue, rather than failing the run or passing in silence (L129, L523).
#
# And one shared part every mod must USE rather than must not copy (#707):
#   screen    a mod that answers a tool call itself (returns     ask $.modkit.screen(e) first, and answer with
#             a result rather than calling next) keeps the      its refusal: mod-kit asks the secret guard
#             call from every guard beneath it, the secret      wherever its folder sorts
#             guard among them
# What it reads is the whole hooks folder: a mod with a tool.call hook and a `result:` answer must
# call $.modkit.screen somewhere. So it catches a new answering mod that never asks; one that asks in
# one hook and not another is held by that mod's own tests (L135), and so is a mod that shows a call's
# input and then refuses without a result (ask before saving asks from classic.PreToolUse instead).
#
# Only each mod's hooks/ is read: its tests may stand in for mod-kit, since a mod cannot import
# another mod's files.
#
# Exit codes, each distinct (L11): 0 none found (the count is printed, L98), 1 a copy found, each
# named with its file and line, 2 the mods folder does not exist.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-shared-parts: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"

# name|pattern|remedy. Patterns are extended regular expressions over each source line.
PARTS=(
  "reader|split\(/[^/]*&&|\$.modkit.commands({ command })"
  "quotes|=== '\"' \|\| [a-z]+ === \"'\"|\$.modkit.commands({ command })"
  "heredoc|<<\(\?!<\)|\$.modkit.commands({ command })"
  "card|component: *['\"]ToolResult['\"]|\$.modkit.card({ toolUseId, title, lines }) (a guard's refusal: \$.modkit.blocked({ ... }))"
  "git|'--work-tree'|\$.modkit.git({ words })"
  "band|component: *['\"]AbovePrompt['\"]|\$.modkit.bandRow({ ... })"
  "pane|strikethrough=\{[^}]*\.strikethrough\}|'\\\\u2502'|'│'|\$.modkit.pane({ mod, id, lines, frame }) (the band: \$.modkit.bandRow)"
  "send|\|\| *['\"]no reason given['\"]|\.isDelivered\) *return|a plain \$.session.send (mod-kit tries every mod's refused send once more)"
  "write-reader|['\"]tee['\"]|\$.modkit.writes({ command, cwd, home })"
)

# $1 = mod  $2 = part -> the issue that ends that mod's known exception for that part, or nothing.
exception(){
  case "$1:$2" in
    # The collision guard's shellWrites and no build's file readers predate mod-kit's (#705).
    collision-guard:write-reader|scope-modes:write-reader) echo '#712' ;;
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
  for part in "${PARTS[@]}"; do
    label="${part%%|*}"; rest="${part#*|}"; pattern="${rest%|*}"; remedy="${rest##*|}"
    hits="$(grep -rnE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' -- "$pattern" "$d/hooks" 2>/dev/null)"
    [ -n "$hits" ] || continue
    until_issue="$(exception "$name" "$label")"
    if [ -n "$until_issue" ]; then
      echo "check-mod-shared-parts: $name keeps its own $label, a known exception until $until_issue moves it onto $remedy."
      continue
    fi
    failed=1
    while IFS= read -r h; do
      echo "check-mod-shared-parts: $name keeps its own $label at ${h#"$d"}: use $remedy from mod-kit instead."
    done <<< "$hits"
  done
  # screen (#707): answering a tool call with a result, never asking mod-kit's screen.
  src=(--include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs')
  if grep -rqE "${src[@]}" -- "on\(['\"]tool\.call['\"]" "$d/hooks" 2>/dev/null \
    && grep -rqE "${src[@]}" -- '\{ *result:|^[[:space:]]*result:' "$d/hooks" 2>/dev/null \
    && ! grep -rqF "${src[@]}" -- '$.modkit.screen(' "$d/hooks" 2>/dev/null; then
    failed=1
    echo "check-mod-shared-parts: $name answers a tool call itself but never asks \$.modkit.screen(e) first, so the guards beneath it (the secret guard) never see that call: ask it before acting on the call, and answer with its refusal."
  fi
done
echo "check-mod-shared-parts: $n mods checked in $dir"
exit "$failed"
