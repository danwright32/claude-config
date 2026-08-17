---
name: grill-me
description: A relentless interview to sharpen a plan or design.
disable-model-invocation: true
---

Run a `/grilling` session.

There are deliberately three of these, and this is the note saying why (#48). `grilling` holds the
actual interview and is the only one the model may invoke on its own. `grill-me` and
`grill-with-docs` are typing shortcuts, both marked `disable-model-invocation`, so `/grill-me` and
`/grill-with-docs` are two ways to start the same interview: plain, or alongside `/domain-modeling`
so the decisions land in an ADR and a glossary as they are made. Collapsing them would mean
remembering which flags to pass to one command instead of typing the one you want.
