# End of turn issue review: why each rule exists

This is the rationale for `review/issue-review.md`. The instruction itself is the short file; this one
is read by a person changing it, never by the review at run time. `test-feature-issue-review.sh` pins
the phrases the instruction is the only carrier of, so a rule cannot drop out by accident.

## Why the instruction lives in a file at all
A Stop hook's `reason` is printed to Dan verbatim, and the instruction is addressed to Claude. It moved
out of the payload in claude-config#243 ("showing this all is unnecessary and ugly", 2026-08-31).

## Why it is short now (hook trim proposal, 2026-10-15)
Every review fire made Claude `cat` the whole file into the transcript, where it was re-read by every
later request. Measured over Slate interactive sessions, Oct 1 to 15: the reads of this file and the
reflection file were 0.93% of every token read, and 8 of the 15 most expensive single outputs. So the
file carries only what a reader must do, and everything below carries why.

## The picker
One multi select picker of at most four options, because more than one picker per review lost answers,
and prose questions were never answered by selection. An option may cover several findings on one
subject (claude-config#241): that is how more than four things leave the spool in one review. Dropping
a group is a real answer for findings below the quality bar. Findings past the picker are archived by
the clear, never held over, which is why the review must say so.

## Priority, category, milestone shown in the picker
Every issue needs all three (one PreToolUse gate, `require-issue-fields.sh`). Showing them in the
picker lets Dan correct a choice before anything is filed, instead of opening GitHub to find out.
`sev-*` and `severity:*` were retired; priority is the only urgency scale.

## Milestones
A milestone is a feature, and its issues are what has to ship for it. The old rule that ad hoc filing
could never open a milestone was reversed on 2026-09-02 after Ungrouped held 98 issues in this repo,
157 in bidspoke and 102 in new-agent-onboarding, with obvious clusters inside them. A NEW milestone
needs two or more issues at once, because a one issue milestone is a label with extra steps, and
inventing one to satisfy the gate produced six essay titled milestones on 2026-07-30.
`ensure-milestone.sh` enforces the count (`--for-issues`, exit 10 on a count of 1) and the title shape.

## READ THE TITLES
The candidate score ranks a shortlist and rules on nothing. Word counting claimed a cluster that was
not there three times on the day it was written, and each fix excluded the words that exposed it
(claude-config#265). The reader decides which candidates are siblings.

## DUPLICATE-RISK and CLOSE-MATCH
On 2026-09-02 an idea was filed twice because the helper read only the holding pen while the same work
sat in a real milestone. On 2026-09-17 #421 was filed over #420 because their titles shared only
"send" while #420's body held the whole diagnosis. CLOSE-MATCH compares title and body, weighted by
word rarity. Neither line is a verdict or a sibling; each must be read. Exit 6 means the backlog could
not be read, which must never be reported as an empty backlog.

## Labels
An issue is routinely two categories at once, so categories are labels and never milestones. The area
list is a starting point: read the repo's labels first and prefer them. `claude-suggested`, or any
label attributing work to AI, is forbidden by the authorship rule.

## The clear line
The findings file ends with the exact command that files the findings away, written from the same
values the render read them with. A hand built clear keyed on a different spool file, both reported
truthfully, and 138 records sat unfiled while the same findings came back every review
(claude-config#287). Its last argument is the stamp of which records this review read, so findings
harvested while the picker was open are not filed unread (claude-config#381). A clear files only the
calling session's records; other sessions' findings are marked seen and stay pending for them
(claude-config#322), except one whose session has plainly gone, which is shown as yours to file
(claude-config#326). A clear that prints nothing is itself a fault (claude-config#1011).

## Folding in the reflection
When both Stop hooks fire on one turn, two banners and two pickers crowded each other, so the
reflection's points go into this review's second pass and one picker.

## The Open questions section
Every issue body ends with a "## Open questions" section (claude-config#1279, Dan 2026-10-17): one "- [ ]"
line for each decision only Dan can make, or None, so /sleep asks each before the night begins. The
filing gate refuses a create without it, and its refusal says what to write; NAMING.md has the rule.
