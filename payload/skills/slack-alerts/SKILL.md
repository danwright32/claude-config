---
name: slack-alerts
description: Use when writing, changing or reviewing any message that code posts to Slack by itself, such as an alert, a failure or error notice, a recovery or all clear, a reminder, a daily or weekly digest or report, a request for someone to approve something, a webhook or Block Kit payload, or the name and description of a monitor in a vendor's tool. Also use when an existing alert reads too long, too wordy, or unlike the other alerts.
---

# Slack alerts

One standard for every message code posts to Slack, in every project, so they all read as if one
person wrote them. The reader is not an engineer but is technical: they know what a sync job, a
webhook and an HTTP 503 are, and they have never seen your code.

## Three decisions before any wording

1. **Does it post?** A message posts when the reader has something to look into. When every finding
   is a normal outcome the code posts nothing, and a missed run alert covers the silence.
2. **Which kind?** `alert`, `recovery`, `reminder`, `digest` or `request`.
3. **Urgent or internal?** Urgent means it is costing money or stopping customers now. Everything
   else is internal.

## The message is five slots, in this order

| Slot | What goes in it |
|---|---|
| 1. First line | One bold sentence that says what happened and names the thing, with its numbers. On an urgent message the mention of the one person who must act comes first, on the same line. |
| 2. One sentence | The one fact that neither the first line nor the error block carries: a cause, or a next step that is specific. Empty on most alerts. Slots 1 and 2 together come to 200 characters at most. |
| 3. List | The affected things, one per line, up to 5 lines, then `and N more`. |
| 4. Error block | What the other system answered, as it sent it, in one code block of up to 500 characters cut on a word boundary. |
| 5. Link | The last line: one link straight to the failed thing, labelled with a verb and the thing it opens (`View run`, `Open sync page`). |

A brief usually holds more facts than the message has slots. Fill the slots, and the message is
finished: every other fact (what it means for customers, how the check decides, when it posts
again, the retry schedule, the runbook) already has a home in the code and the runbook.

## What each kind fills

| Kind | First line | Slot 2 | Mention | Link |
|---|---|---|---|---|
| `alert` | what happened | 0 or 1 sentence | urgent only | always |
| `reminder` | `Still open after 2 hours: ` then the alert's first line, shortened | empty | the same person | always |
| `recovery` | `Recovered: ` then what works again | 0 or 1 sentence: how long it lasted and what it cost | none | when there is something to open |
| `digest` | the count that makes it worth opening | 0 or 1 sentence | none | always |
| `request` | who asks the person for what | up to 2: the asker's note in quotes, and the one fact needed to decide | the person asked | always |

- An internal alert posts once, and again only when it changes. An urgent alert gets reminders.
- A recovery is a new message in the channel.
- A request carries buttons when pressing one does the thing (Approve, Decline).
- A thread reply exists to add a diagnosis the message lacks, in projects that opted in.

## Wording

- Counts are digits, and the noun matches the count (1 account, 2 accounts).
- Things are named the way the reader's screen names them (an advisor's name, pull request 641).
- A time appears when it differs from the time of the post, written `3:05 PM ET`, or
  `3:05 PM ET, Nov 14` when it is not today.
- Sentence case, plain words, and commas, colons and full stops for punctuation.
- A credential inside the other system's answer (a token, a key, a password) is cut out of the
  error block. A cleaner the project already runs on error text stays in place.

## Examples

Internal `alert`, the usual size:

    *The nightly warehouse export has not run since 3:05 AM ET, Nov 14*
    <https://shop.example.com/admin/jobs/nightly-export|Open export job>

Urgent `alert` with a list and an error block, which already says why:

    <@U012ABCDEF> *3 of 40 invoices were not sent this morning*
    • Invoice 1042, Ridgeway Dental
    • Invoice 1043, Corner Bakery
    • Invoice 1047, Elm Street Books
    ```HTTP 413 {"message":"Attachment exceeds 10 MB"}```
    <https://shop.example.com/admin/invoices?status=failed|View failed invoices>

`reminder`:

    <@U012ABCDEF> *Still open after 2 hours: 3 invoices have not been sent*
    <https://shop.example.com/admin/invoices?status=failed|View failed invoices>

`recovery`:

    *Recovered: all 40 invoices have been sent*
    3 were held from 8:05 AM to 11:20 AM ET.

`digest`:

    *4 imports were skipped last week, 1 of them for a missing column*
    • Orders, 2:46 PM ET, Nov 13: no column named "total"
    • Customers, 10:12 AM ET, Nov 14: the file was empty
    • Refunds, 4:03 PM ET, Nov 12: the file was empty
    • Stock, 9:30 AM ET, Nov 11: the file was empty
    <https://shop.example.com/admin/imports|Open import log>

`request`:

    <@U045GHIJKL> *Priya asks you to approve a refund of $240 on order 1038*
    "The parcel arrived damaged." It is over the $200 she can approve herself.
    <https://shop.example.com/admin/refunds/77|Open refund>

## Check it

Render the message with the longest values the code can produce, save it as the text Slack
receives, and run the checker beside this file:

    python3 ~/.claude/skills/slack-alerts/check_alert.py --kind alert --urgent --app "Shop Admin" message.txt

`--kind` is required. `--urgent` goes on an urgent alert and its reminder. `--app` is the name of
the bot that posts, which already tells the reader which app is speaking. Exit 0 is a pass. Each
`FAIL` line names the rule and what it measured, so fix that and run it again. The checker cannot
tell whether the first line is true, whether the link opens the failed thing, or whether the
problem is urgent: read the rendered message once for those.

## Around the message

- **The project's CLAUDE.md** records the bot and channel, which alerts are urgent, who is
  mentioned, and any alert that keeps its own layout, named with the date it was approved. An
  alert recorded there is left exactly as it posts.
- **The project's tests** run the checker over every message the code can render. CI has no
  Claude config folder, so the project keeps its own copy of `check_alert.py`, with a test that
  runs where this one exists and fails when the two differ (Dan, 2026-11-17).
- **The route has to render formatting.** Read one posted message in Slack. If the asterisks and
  angle brackets show as typed, which is what a workflow builder variable does, move the alert to
  an app webhook.
- **A monitor in a vendor's tool** is drawn by the vendor. Write its name as a first line and its
  description as slot 2.
- **Rewriting a repo's existing alerts** ends with one page showing each alert before and after,
  for Dan to read before the change merges.
