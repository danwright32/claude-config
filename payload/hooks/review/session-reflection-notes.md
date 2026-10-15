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
