#!/usr/bin/env bash
# Global Stop hook: periodically ask Claude to review the session for feature
# ideas / tech debt worth filing as GitHub issues. Repo-agnostic (auto-detects
# the current repo; falls back to listing ideas if there's no repo/gh).
# Throttled per-project, and guarded so the re-prompt can't loop on itself.
# Tune COOLDOWN_SECONDS, or remove the hooks.Stop entry in ~/.claude/settings.json
# to disable everywhere.

set -euo pipefail

input=$(cat)

# Loop guard: if this stop was triggered by our own re-prompt, let it end.
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$stop_active" = "true" ] && exit 0

# Throttle: only re-prompt once per cooldown window, tracked per project.
COOLDOWN_SECONDS=1800  # 30 minutes
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
hash=$(printf '%s' "$proj" | shasum | cut -c1-12)
stamp="${TMPDIR:-/tmp}/claude-feature-issue-review-${hash}.stamp"

now=$(date +%s)
last=0
[ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
[ $(( now - last )) -lt "$COOLDOWN_SECONDS" ] && exit 0

printf '%s' "$now" > "$stamp"

# decision:block feeds `reason` back to Claude as a continuation instruction.
cat <<'JSON'
{"decision":"block","reason":"FORMAT: open your reply with the ISSUE REVIEW banner — a 3-line heavy-line box (corners ┏┓┗┛, sides ┃, fill ━) labeled ISSUE REVIEW — then answer below it. Emit the box only in your reply; do NOT restate this FORMAT line.\n\nFIRST, as section 1 and BEFORE anything else in this reply, do a genuine forward-looking sweep: look over what we worked on this session and actively brainstorm NEW feature ideas, improvements, follow-ups, or tech debt that are worth tracking but are out of scope for the work just completed. Make a real attempt EVERY time — do not let this get crowded out by the reflection second pass below, and only conclude 'nothing worth filing' after you have actually looked. But apply a QUALITY BAR: only list ideas substantial enough that I would genuinely act on or want to track — never pad the list to look productive; zero ideas is a perfectly good outcome when nothing of real value surfaced. If you find any: present them to me as options in a SINGLE AskUserQuestion multi-select picker (one option per idea, each with a short plain-language description) so I can choose which to file in one step — my selection is your go-ahead; never file without it. Do NOT ask in prose. A picker holds at most 4 options, so if there are more ideas, put the 4 highest-value ones in the picker and note any remainder in one line. PREFIX each option's label with its number from the write-up above (e.g. '1.1 ...', '1.3 ...', '2.1 ...') so every option maps directly back to the numbered item I can read the detail for. On approval, file with `gh issue create` in the CURRENT repository (do not hardcode a repo): a concise imperative title and a 2-4 sentence body covering the problem, why it matters, a rough direction, and relevant `path:line` refs. Always label each issue with the best-fit category (`enhancement`, `tech-debt`, `bug`, or `documentation`). NEVER apply a `claude-suggested` label (or any label that attributes the issue to Claude/AI) — it is forbidden; do not create or apply it under any circumstances. Prefer reusing existing repo labels, but if a needed label is missing, CREATE it first with `gh label create <name> --color <hex> --description <desc>` (then apply it) rather than omitting it. You may also create a new, more descriptive label when none of the existing ones capture the issue well — keep new label names short, kebab-case, and reusable. If `gh` is not installed/authenticated or the current directory is not a GitHub repo, do NOT attempt to file or create labels — just list the ideas so they can be captured manually. If nothing is worth filing AND nothing else needs my action, do NOT show a picker and do NOT add any 'nothing needed' or 'nothing else surfaced' note — just continue silently. Never pad with filler. Do NOT reopen or redo work that is already complete. When you list or explain ideas to me in chat, use PLAIN LANGUAGE for a product manager, not an engineer: no jargon, and describe any technical thing by what it affects (the issue bodies you file may still keep their path:line refs). Number each idea you list to me as 1.1, 1.2, 1.3, and so on (this is section 1) so I can refer to them by number. NEVER use dashes or bullet points for any list anywhere in your reply — give EVERY item (including side notes, asides, or things you are only flagging and not filing) its own number in the 1.x sequence so I can reference any of them. ORDER: When BOTH this issue review and the SESSION REFLECTION fire on the same turn, the reflection is NOT printed as its own section — fold it in here instead. First FULLY COMPLETE the section 1 idea sweep above as a real, standalone attempt (not an afterthought) and list those items. Then, separately, do a SECOND PASS through the reflection's uncertainty point(s), applying the same three-way rule, and be SUCCINCT — only surface what needs me: (a) RESOLVE-NOW — settle it yourself with read-only / non-destructive tools; if it clears with nothing for me to do, do NOT write it up (at most one short 'checked and cleared' line), and only surface it as a point if you found a real problem; (b) DECIDE-NOW — if it is a quick decision I can make to unblock acting now, pose it as a multiple-choice question via the AskUserQuestion tool; (c) FLAG — otherwise flag it as mine with ACTIONABLE steps for how to check or do it (not just a description of the worry). FOLD every actionable item — ideas to file, DECIDE-NOW choices, and FLAG items needing my action — into the SAME single AskUserQuestion multi-select picker as the ideas above (up to 4 options total), so all my decisions live in one place; use the picker, not prose questions. Each option's label MUST begin with its section number (1.1, 1.3, 2.1, …) matching the numbered write-up so I can find the explanation for any option. If the reflection raised nothing that needs my action, add NOTHING about it. (On turns where only the reflection fires, it prints its own section instead.)"}
JSON
