# Must always be true

A test checks the cases somebody thought of. A rule such as "a customer is never charged twice for
one purchase" can be checked against every case a tool can generate, but only when it was written
down before the build. So every plan and every build issue carries the feature's rules as a list,
and every rule names what keeps it true (claude-config#3457).

This file is the one home of that list. The feature interview, `/plan-lite`, `/plan-council`,
`/milestone` and a builder's brief point here and spell none of it out again.

## The list

    ## Must always be true

    - R1. A customer is never charged twice for one purchase.
      - Still possible: A customer can pay for a purchase.
      - Kept true by: database constraint `payments_one_per_purchase`
    - R2. A refund is never larger than the payment it refunds.
      - Still possible: A customer can be refunded in full.
      - Kept true by: nothing yet, phase 2 adds a property test
    - R3. A payment notice that arrives twice marks its purchase paid once.
      - Still possible: A purchase is marked paid when its notice arrives late.
      - Kept true by: nothing yet, a rule about order that suits a model check

    Not covered: a charge made outside the app, and a refund in another currency.

- **The rule.** One sentence, in the words a user of the feature would use, never the code's. It
  keeps its number (R1, R2) in every copy, and a number is never used again for another rule.
- **Still possible.** One sentence naming the good outcome the rule must not prevent. A rule can
  mislead two ways: it can be wrong, and it can pass because what it guards never happens. This line
  is the answer to the second: without it a rule passes when the feature does nothing.
- **Kept true by.** Starts with the kind and then the name of something that exists today:
  `database constraint`, `type`, `test`, `property test`, `model check` or `guard`. Anything planned,
  or absent, is `nothing yet`, then a comma and what is planned or why nothing will. A rule about
  every input to a calculation suits a property test; a rule about the order things happen in (a
  retry, a timeout, two requests at once) suits a model check. A model check is named by its
  guide's path; the verification-guides skill's "Model check guides" says how one is written, and
  for a rule about order that is still `nothing yet` the session offers one, never requires it
  (claude-config#3471). `nothing yet` is an honest answer.
  A blank, or "careful code", is not.
- **Not covered.** One line naming what the rules leave out. Dan reads the rules and this line, and
  that is his review: ask him to approve both with AskUserQuestion before anything is built on them.
- **No such rule.** Work that stores, sends and decides nothing still carries the section, as
  `None: <why>`, so a list nobody wrote is never read as one that was considered.

## Who writes what

1. **The interview** writes the rules, what is still possible and what is not covered, in Dan's
   words. What keeps each rule true is whatever exists today, most often `nothing yet`.
2. **The plan** says after each `nothing yet` which phase builds its holder, or why none will.
3. **Each phase's issue** carries the rules that phase must keep true, numbers unchanged, and the
   `Not covered` line.
4. **The builder** builds each holder the issue names and proves it (L1): take it out, or break the
   rule where the holder is itself a test, watch the rule's check fail, and put it back. The pull
   request repeats the list with the real names, and under each rule that has a holder a third line,
   `Seen to fail:`, quoting what failed. A rule still at `nothing yet` is said so in the pull
   request, never left to be inferred.

## Check it

    bash ~/.claude/skills/milestone/must-hold.sh check <file>           # a plan or an issue body
    bash ~/.claude/skills/milestone/must-hold.sh check --built <file>   # a pull request body
    bash ~/.claude/skills/milestone/must-hold.sh list <file>            # one line per rule

Exit 0 is a sound list, 1 names each fault, 3 means the file has no list. No gate refuses an issue
without one: exit 3 is the prompt to write it.
