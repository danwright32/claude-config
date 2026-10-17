# End of turn issue review
Why each rule exists: review/issue-review-notes.md.
---
FORMAT: open with a 3 line heavy box (┏┓┗┛ ┃ ━) labeled ISSUE REVIEW.

1 SWEEP. Look over this session for ideas, follow ups or tech debt worth tracking beyond the work just done. Try every time; list only what I would act on; zero is fine; redo nothing. A findings file the pointer names is input you cannot rediscover: judge it the same way, say how many you dropped, never paste it. Say plainly what a HARVEST FAILED line means (nothing to do; it will not come back) and a REPLY COULD NOT BE READ line.

2 PICKER. One AskUserQuestion multi select, at most 4 options, each label starting with its number (1.1, 2.1). One option may group several findings on one subject, or DROP a group. Say how many did not fit (the clear archives them unread). End each description with [priority, categories, milestone], like [p2, tech-debt, NEW Backlog grouping, moves #241 #242]. File nothing unselected.

3 FILING: gh issue create here, imperative title, 2 to 4 sentences with path:line, ending "## Open questions" or None. Scripts: ~/.claude/skills/milestone/. MILESTONE AND PRIORITY required. Priority: priority-p0 broken now, p1 next, priority-p2 default, p3 nice, priority-p4 someday (ensure-priority-labels.sh); never sev-* or severity:*. Milestone: run milestone-candidates.sh "<owner>/<name>" --like "<title>" and READ THE TITLES; the score only ranks. CHECK THOSE BEFORE FILING: every DUPLICATE-RISK and CLOSE-MATCH line (same work: drop it, name the issue); neither is ever a sibling. Exit 6: unreadable, say so, use Ungrouped. Choose: an existing milestone; else a NEW one only when 2 OR MORE issues would go into it at once (feature name, 8 words max, no punctuation), made only once selected: ensure-milestone.sh "<owner>/<name>" "<title>" --create-approved --for-issues <n> --description "<why>" (exit 10: Ungrouped), then gh issue edit only siblings the picker named; else Ungrouped, made unasked by ensure-milestone.sh "<owner>/<name>" "Ungrouped". Exit 4: attach to it. Exit 3: ask. Planned features: plan-council, plan-lite, /milestone. Rules: NAMING.md. Labels: one type (bug, enhancement, tech-debt, documentation) and EVERY area label that applies (ui-ux, data-integrity...), a STARTING POINT, not a closed set: read gh label list, prefer those, else create. Never claude-suggested. No gh: just list.

4 SECOND PASS. If the reflection also fired, fold its points in after section 1 by its own rule, decisions in this picker.

5 CLEAR, after the picker, whatever I chose. The findings file ends with TO FILE THESE. Run that line, verbatim: no retyping, no $PWD, do NOT drop any of its arguments. No file, or THESE cannot be filed from this review: run nothing. LEFT records (other sessions, or harvested after the review was rendered): one line. Did NOT finish: quote why, no retry. Silent: report it.

Nothing for me: no picker, no note. Plain language. Number every item 1.x. No dashes or bullets.
