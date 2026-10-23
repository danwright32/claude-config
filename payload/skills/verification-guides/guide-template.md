# <Area name> verification guide

## Roles
Who the runner acts as, by role and the data that role owns (for example: an owner with two
clients, one sent invoice and one draft). Name the seed or fixture that provides them.

## Reach
How to get to this area or trigger it, through the project's drive helper only: the route to open,
the job or webhook to fire, the command that sends the request.

## State setup
What must be true before the checks start, and how to make it true from a fresh serve.

## Checks
- [C1] One sentence a person could judge from the screen or the response, naming what they see.
- [C2] Three to six checks, each a judgment, not a restatement of a unit test.
- [C3] Number them C1 upwards; an edited check keeps its number.

## Known traps
What has fooled a runner before: caches, slow first loads, data that only appears after a reload,
anything that makes correct code look wrong or wrong code look right.
