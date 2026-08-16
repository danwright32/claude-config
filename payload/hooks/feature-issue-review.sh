#!/usr/bin/env bash
# Global Stop hook: periodically ask Claude to review the session for feature
# ideas / tech debt worth filing as GitHub issues. Repo-agnostic (auto-detects
# the current repo; falls back to listing ideas if there's no repo/gh).
# Throttled per-project, and guarded so the re-prompt can't loop on itself.
# Tune COOLDOWN_SECONDS, or remove the hooks.Stop entry in ~/.claude/settings.json
# to disable everywhere.

set -euo pipefail

input=$(cat)

# Detached-run guard: see session-reflection.sh. A headless `claude -p` launched by an app has no
# reader, so an issue-review re-prompt spends the run on ceremony and can never reach a person
# anyway. It would also file issues nobody asked for, from a run that was told to do one job.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

# Loop guard: if this stop was triggered by our own re-prompt, let it end.
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$stop_active" = "true" ] && exit 0

# Only after turns that actually changed something (Edit/Write/Bash/Agent/...):
# chat-only and read-only Q&A turns skip, and skips do NOT consume the cooldown
# stamp below (shared helper, also used by session-reflection.sh).
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Per-conversation kill switch: `touch <transcript>.skip-stop-hooks` silences
# this hook for that one conversation only; delete the file to re-enable.
[ -f "${transcript}.skip-stop-hooks" ] && exit 0
worked=$(python3 "$(dirname "${BASH_SOURCE[0]}")/turn-worked.py" "$transcript" 2>/dev/null)
[ "$worked" = "yes" ] || exit 0

# Findings harvested from subagents that finished for this project (see
# subagent-issue-harvest.sh). Fetched BEFORE the cooldown is judged, because a
# pending finding has to beat it: a batch of agents finishing together would
# otherwise get one review between them, and the rest of what they found would
# sit unread until the window reopened, by which point the session is usually
# over. Reading does not consume the spool; only filing does.
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
SPOOL_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/issue-spool.sh"
pending=""
[ -f "$SPOOL_LIB" ] && pending=$(bash "$SPOOL_LIB" pending "$proj" 2>/dev/null)

# Throttle: only re-prompt once per cooldown window, tracked per project.
COOLDOWN_SECONDS=1800  # 30 minutes
hash=$(printf '%s' "$proj" | shasum | cut -c1-12)
stamp="${TMPDIR:-/tmp}/claude-feature-issue-review-${hash}.stamp"

now=$(date +%s)
last=0
[ -f "$stamp" ] && last=$(cat "$stamp" 2>/dev/null || echo 0)
if [ -z "$pending" ] && [ $(( now - last )) -lt "$COOLDOWN_SECONDS" ]; then
  exit 0
fi

printf '%s' "$now" > "$stamp"

# decision:block feeds `reason` back to Claude as a continuation instruction.
# The instruction stays one static heredoc so it can go on being checked as a
# single literal block; any spooled subagent findings are appended to its reason
# afterwards rather than interpolated into it.
payload=$(cat <<'JSON'
{"decision":"block","reason":"FORMAT: open your reply with the ISSUE REVIEW banner: a 3-line heavy-line box (corners ┏┓┗┛, sides ┃, fill ━) labeled ISSUE REVIEW, then answer below it. Emit the box only in your reply; do NOT restate this FORMAT line.\n\nFIRST, as section 1 and BEFORE anything else in this reply, do a genuine forward-looking sweep: look over what we worked on this session and actively brainstorm NEW feature ideas, improvements, follow-ups, or tech debt that are worth tracking but are out of scope for the work just completed. Make a real attempt EVERY time, and do not let this get crowded out by the reflection second pass below, and only conclude 'nothing worth filing' after you have actually looked. But apply a QUALITY BAR: only list ideas substantial enough that I would genuinely act on or want to track. Never pad the list to look productive; zero ideas is a perfectly good outcome when nothing of real value surfaced. If you find any: present them to me as options in a SINGLE AskUserQuestion multi-select picker (one option per idea, each with a short plain-language description) so I can choose which to file in one step. My selection is your go-ahead; never file without it. Do NOT ask in prose. A picker holds at most 4 options, so if there are more ideas, put the 4 highest-value ones in the picker and note any remainder in one line. PREFIX each option's label with its number from the write-up above (e.g. '1.1 ...', '1.3 ...', '2.1 ...') so every option maps directly back to the numbered item I can read the detail for. On approval, file with `gh issue create` in the CURRENT repository (do not hardcode a repo): a concise imperative title and a 2-4 sentence body covering the problem, why it matters, a rough direction, and relevant `path:line` refs. MILESTONE AND PRIORITY, BOTH REQUIRED: every issue carries a milestone and exactly one priority label, and one PreToolUse gate blocks a create that is missing any of them. Work BOTH out for every idea BEFORE showing the picker, and SHOW THEM IN THE PICKER so I can see what you chose and correct it before anything is filed: end each option description with them in brackets, like `[p2, Queue windowing]` or `[p1, Ungrouped]`. I should never have to open GitHub to find out what level you gave something. PRIORITY: choose the level yourself, because these are your findings and I have not read them. `priority-p0` broken now, drop everything; `priority-p1` important, do next; `priority-p2` normal, the default for real work; `priority-p3` nice to have; `priority-p4` someday, maybe never. If those labels do not exist in the repo yet, create all five first: `bash ~/.claude/skills/milestone/ensure-priority-labels.sh \"<owner>/<name>\"`. NEVER apply a `sev-*` or `severity:*` label: they are retired and priority is the only urgency scale. MILESTONE: a milestone is an overarching FEATURE, and its issues are what has to be finished for that feature to ship. Read the repo's open milestones (`gh api \"repos/<owner>/<name>/milestones?state=open&per_page=100\" --jq '.[] | \"#\\(.number) \\(.title)\"'`) and work out which one each idea belongs to. If an open milestone fits, just add `--milestone \"<its exact title>\"` and file it, no extra question. Most of these ideas are standalone fixes that belong to no feature, and those go in the repo's catch-all milestone, `Ungrouped`, which the helper creates without needing approval: `bash ~/.claude/skills/milestone/ensure-milestone.sh \"<owner>/<name>\" \"Ungrouped\"`. NEVER create a new milestone here. A new milestone is a PLANNING decision, made when a feature is planned through /plan-council, /plan-lite or /milestone, and it never makes sense to open one for a one-off issue. This review files one-off issues, so every idea gets EITHER an existing open milestone OR `Ungrouped`, and there is no third option. If the resolver exits 5 (no match), that means you picked a title that does not exist: use `Ungrouped` rather than asking me to approve a new milestone. A category like accessibility or tech debt is a LABEL, never a milestone, because an issue is routinely two categories at once and can hold only one milestone. The full rule for all of this is in ~/.claude/skills/milestone/NAMING.md. LABELS, REQUIRED: the same gate blocks a create with no label other than its priority. Give each issue ONE type label plus EVERY area label that genuinely applies, because an issue is routinely about more than one thing (an accessibility fix that is also tech debt gets both). Type, pick one: `bug`, `enhancement`, `tech-debt`, `documentation`. Area, pick all that fit: `accessibility`, `ui-ux`, `performance`, `security`, `data-integrity`, `error-handling`, `monitoring`, `analytics`, `ci-hygiene`, `test-coverage`, `onboarding`, `deployment`. That area list is a STARTING POINT, not a closed set: read the repo's own labels first (`gh label list --limit 100`) and prefer an existing one over a near synonym of it (if the repo says `ux`, use `ux`, not `ui-ux`), and if nothing covers the issue, create a new short kebab-case label rather than forcing a bad fit or leaving the issue bare. The vocabulary is NOT restricted and the gate never checks which label you used, only that a category is there. Show the categories in the picker too, alongside the level and milestone, so I can correct any of the three before anything is filed: `[p2, tech-debt + accessibility, Ungrouped]`. NEVER apply a `claude-suggested` label (or any label that attributes the issue to Claude/AI): it is forbidden; do not create or apply it under any circumstances. Prefer reusing existing repo labels, but if a needed label is missing, CREATE it first with `gh label create <name> --color <hex> --description <desc>` (then apply it) rather than omitting it. You may also create a new, more descriptive label when none of the existing ones capture the issue well. Keep new label names short, kebab-case, and reusable. If `gh` is not installed/authenticated or the current directory is not a GitHub repo, do NOT attempt to file or create labels. Just list the ideas so they can be captured manually. If nothing is worth filing AND nothing else needs my action, do NOT show a picker and do NOT add any 'nothing needed' or 'nothing else surfaced' note. Just continue silently. Never pad with filler. Do NOT reopen or redo work that is already complete. When you list or explain ideas to me in chat, use PLAIN LANGUAGE for a product manager, not an engineer: no jargon, and describe any technical thing by what it affects (the issue bodies you file may still keep their path:line refs). Number each idea you list to me as 1.1, 1.2, 1.3, and so on (this is section 1) so I can refer to them by number. NEVER use dashes or bullet points for any list anywhere in your reply. Give EVERY item (including side notes, asides, or things you are only flagging and not filing) its own number in the 1.x sequence so I can reference any of them. ORDER: When BOTH this issue review and the SESSION REFLECTION fire on the same turn, the reflection is NOT printed as its own section. Fold it in here instead. First FULLY COMPLETE the section 1 idea sweep above as a real, standalone attempt (not an afterthought) and list those items. Then, separately, do a SECOND PASS through the reflection's uncertainty point(s), applying the same three-way rule, and be SUCCINCT. Only surface what needs me: (a) RESOLVE-NOW, settle it yourself with read-only / non-destructive tools; if it clears with nothing for me to do, do NOT write it up (at most one short 'checked and cleared' line), and only surface it as a point if you found a real problem; (b) DECIDE-NOW, if it is a quick decision I can make to unblock acting now, pose it as a multiple-choice question via the AskUserQuestion tool; (c) FLAG, otherwise flag it as mine with ACTIONABLE steps for how to check or do it (not just a description of the worry). FOLD every actionable item (ideas to file, DECIDE-NOW choices, and FLAG items needing my action) into the SAME single AskUserQuestion multi-select picker as the ideas above (up to 4 options total), so all my decisions live in one place; use the picker, not prose questions. Each option's label MUST begin with its section number (1.1, 1.3, 2.1, …) matching the numbered write-up so I can find the explanation for any option. If the reflection raised nothing that needs my action, add NOTHING about it. (On turns where only the reflection fires, it prints its own section instead.)"}
JSON
