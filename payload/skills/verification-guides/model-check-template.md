# <Area name> model check guide

## Rules
- [R1] One sentence about the order things happen in, in the words Dan approved, numbered as in the plan's list when there is one.
  - Good outcome: One sentence naming what must still be able to happen beside the rule.
  - Approved by Dan: YYYY-MM-DD

## Not covered
One line naming what the rules leave out, as Dan saw it when he approved them.

## Model
The model's files in this repository, and for each step in the model the file and function of the
code it was written from. Every bound the model sets (how many retries, how many requests at once)
beside the value the code allows.

## Last checked
- Commit: never
- Result: One line: every rule held over how many states, or the shortest failing path in plain words.

## Checks
- [C1] Each rule holds in the model of the code at this commit: the checker finds no path that breaks it.
- [C2] Each rule's good outcome can happen in the model, so no rule passes because nothing happens.
- [C3] Every step of the model names the code it was written from, and that code still does what the step says.

## Known traps
What has fooled a model check before: a bound smaller than the code allows, a step the model merges
that the code splits, a slow reply the model never lets happen.
