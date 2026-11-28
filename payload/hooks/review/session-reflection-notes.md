# Session reflection: why each rule exists

Rationale for `review/session-reflection.md`, read by a person changing it, never at run time.

## Why it lives in a file
A Stop hook's `reason` is printed to Dan verbatim. The instruction is addressed to Claude, so the
reason is a short pointer and the instruction is here (claude-config#243).

## Why it is short now (hook trim proposal, 2026-10-15)
The reflection fires on every turn that did real work, and each fire read the whole file into the
transcript, where every later request re-read it. Together with the issue review file that was 0.93%
of every token read in Slate interactive sessions, Oct 1 to 15.

## The three ways to act
Listing worries without acting on them left Dan to do the checking. So a point Claude can settle with
read only tools is settled before printing, and only a real problem is reported; a quick choice
becomes a picker so it is settled this turn; anything only Dan can do comes with concrete steps.

## Always a picker
Dan answers by selecting. Open questions left in prose went unanswered, including ones asked earlier
in the same reply, so any open choice ends the turn as a picker.

## Side effects need a go ahead
The reflection may only run read only checks on its own. Writing, installing, deploying or pushing
from a reflection would act without the approval the main flow requires.

## Plain language, numbering, no dashes
Dan reads as a product manager; numbered points let him refer to any item; the dash rule is the
global writing rule, and a rule contradicted by the prose around it loses to the demonstration (L270).

## Folding into the issue review
When both Stop hooks fire on one turn, the reflection hands its points to the issue review's second
pass, so there is one banner and one picker.

## The Goal accomplished box, when there is no /goal
With no /goal, the box (mods/goal-box) shows only when the session calls its tool, and nothing
reminded it to: on 2026-10-26 a Slate session finished every part of a request, reported it, and
showed no box until Dan asked whether it was done (claude-config#1749). The reflection fires after
every turn that changed something, which is the turn requested work finishes on, so it carries the
reminder at no extra turn; a chat only turn finishes no work, so missing it costs nothing. The line
sits after the EXCEPTION so a reflection folded into the issue review still asks, but on 2026-11-09
a folded reflection's line was dropped all the same, because the session wrote that turn from the
issue review (claude-config#2523), so the issue review now carries the same request as its own
last step. The tool's own
checks (agents running, a merge or deploy unconfirmed, a pull request still open, one box per
request) stay the gate, so a call made too early is refused rather than shown.

## What does not hold the box
On 2026-11-27 a session finished what Dan asked for and showed no box until he asked "no goal box?"
(claude-config#3864). Three things were still open and it could do none of them: a Slack draft only
he can send, a check `/check-later` had put on the To Do list, and work he had just declined in a
picker. The line said only "every part of the work I asked for", so the session counted all three
as its own unfinished work. The line now names them as not holding the box, and the goal box's tool
description says the same with the rule for a step on the steps card: a step that is Dan's alone
holds nothing, and one with the session's own work waiting behind it does.

The line also ended "Not finished: say nothing of it", which hid the decision: a box held back on
purpose and a box forgotten looked the same to Dan. A session that holds the box now says in one
line what it waits on, on the turn it first holds it and again only when that changes, so the line
is not repeated every turn. `tests/test-goal-box-wording.sh` holds the reflection's EITHER WAY
line, the issue review's last step and the mod's own words to the one rule.

## Recording that the review was answered
The box could show before the review's picker, where more work gets chosen: on 2026-11-27 a session
showed it, then Dan picked follow ups in the review's picker, and they finished with no box
(claude-config#3843). His answers on the issue: hold the box "until the review is answered", and, of
how the box is to know, "The review says so itself". So `lib/review-reason.py` records that a review
was handed over, the line before the box request records that he answered it, by running
`lib/review-record.py answered`, and the box asks that record. The command is here and not in the
issue review's instruction as well because that file is at the size limit
`test-review-instructions.sh` holds it to, with no room for the line. Three things make one copy
enough: the reflection is
handed over in every turn the issue review is, since the issue review's conditions are the
reflection's plus a cooldown (`test-review-record.sh` checks it on one transcript); the line sits in
the part that holds whether or not the reflection is folded in; and a session that skips it is told
the command by the box's own refusal, so a dropped line costs one refused call, never a box held for
good.
