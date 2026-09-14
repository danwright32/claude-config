---
name: coffee-profile
description: Use when Dan asks to redo, refresh or update his coffee taste profile, wants new coffee or roaster recommendations, or has added coffees to the Coffee Tracker sheet. Trigger /coffee-profile.
trigger: /coffee-profile
---

# /coffee-profile

Rebuild Dan's coffee taste profile from the tracker export, publish it as a
fresh page, and recommend five or six coffees he has not tried.

Files in this folder:

| File | Role |
|---|---|
| `analyze.py` | The numbers. Run it; never recompute by hand. |
| `template.html` | The page. Fill every double-brace slot; keep the CSS. |
| `recommended.json` | Every coffee ever recommended. Read before recommending, append after. |
| `runs/last-run.json` | What "since last time" is measured against. Written ONLY by `analyze.py --record`; every other invocation leaves it alone. |
| `test-coffee-profile.sh` | The suite. Run it after any change to `analyze.py`. |

## 1. Get the numbers

```
python3 ~/.claude/skills/coffee-profile/analyze.py --record
```

Run that ONCE per profile. It reads the newest `Coffee Tracker*.csv` in
`~/Downloads` and records this run as the baseline the next profile
compares against. To look at the numbers again during the same run (for
example `--json`), leave `--record` off: a second recorded run would make the
next profile compare against today instead of the run before it.

Three refusals,
each with its own exit code and message, and each one stops the run:

| Exit | Meaning | What to tell Dan |
|---|---|---|
| 2 | No export in Downloads | Export the sheet as CSV (File, Download, CSV) into Downloads, then run again. |
| 3 | A column was renamed | Name the column from the message. Do not guess a mapping; ask what it means now. |
| 4 | `runs/last-run.json` is corrupt | Show the message. Do not proceed as if there were no previous run. |

The output is the whole evidence base for the page. Read all of it. The
`Confounds` block lists every group difference that one roaster carries.
**A flagged group is reported as that roaster, never as the group.** The
first profile (2026-09-14) called "fully washed" and "medium-light" a
preference when both were one roaster, and Dan caught it. That is why the
block exists and why it is not optional.

Two more rules the script cannot enforce:

- The sweetness column is not ordered low to high (1 too sweet, 3 balanced,
  4 dry, 5 subtle). Report sweetness by its per-level means, never by its
  correlation alone.
- The attribute findings are Dan's own description of each cup, so they are
  the part of the page to trust. Every category cut (roast, grind, type,
  process, origin, roaster) overlaps with the others at this sample size.
  Say so in the caveats, every time.

## 2. Write the page

Copy `template.html` to the scratchpad and fill every slot. The slots and
what goes in them:

| Slot | Content |
|---|---|
| `N`, `MEAN`, `YES`, `NO`, `RUN_DATE` | From the first two lines of the output. `MEAN` to one decimal. |
| `LEDE` | Three or four sentences: the palate in plain words. Body, bitterness, finish, sweetness, then the roast lean if there is one, then the one consistent miss. |
| `SHIFT` | One or two sentences on what changed since the previous run: new coffees, and any correlation or average that moved by 0.1 or more. First run: "First profile; nothing to compare against yet." Same data as last time: say so plainly, with the previous run's date. |
| `CORR_ROWS` | One `div.bar` per attribute, strongest first by the unrounded value in `--json` (two can round to the same two decimals), bar width = correlation as a percentage. Copy the markup shape below. |
| `DRIVER_FINDINGS` | Four or five `li` findings, each `<b>bold claim.</b> evidence`. Body floor, finish, sweetness by level, bitterness, aroma. Use the per-level means, and the per-level `max` for any ceiling claim ("nothing scored weak went above 6"). |
| `ROAST_ROWS` | One `tr` per roast level, best average first, blanks excluded. |
| `ROAST_PROSE` | One or two `p`. If a roast level is in the Confounds block, say which roaster carries it and what the others average. |
| `ORIGIN_ROASTER_FINDINGS` | Two or three `li`. Roasters with a Yes, roasters with none, and origins that repeat, from the `Origin` block of the output (note its blank count). Any group in Confounds is named by roaster. |
| `TOP_ITEMS`, `BOTTOM_ITEMS` | Five `li` each from the Top and Bottom blocks: `<span class="score">9</span>Name, Roaster<span class="sub">roast, notes</span>`. A blank roast is written "roast not recorded". Notes are transcribed as a lowercase comma list: the sheet's own text carries bullets and dashes that must not reach the page. |
| `WORDS_YES`, `WORDS_NO` | `li` chips from the `Label words` block: `yes` phrases and `no` phrases. Leave out the `both` list (a chip cannot be green and struck through), leave out Dan's own verdicts that live in the notes column ("far too sweet", "very sweet" are his remarks, not label copy), and shorten a long phrase to its label word ("subtle undertones of dark chocolate" is "dark chocolate"). Words only, no claim about cause. |
| `RECOMMENDATIONS` | The six items from step 3, filled in last. |
| `CAVEATS` | Three `p`: sample size and category overlap; the sweetness scale; scores are Overall Enjoyment out of 10, not the sheet's computed rating. |

Markup shapes, copied from the first page:

```html
<div class="bar"><span class="l">Boldness</span><div class="track"><div class="fill" style="width:72%"></div></div><span class="n">+0.72</span></div>
<li><div><b>Body is a hard floor.</b> Fourteen coffees you scored as weak or mild. None went above 6.</div></li>
<tr><td>Dark</td><td class="num">8</td><td class="num">5.8</td><td class="num">4</td><td class="num">1</td></tr>
<li><span class="score">10</span>Valhalla Java Odinforce, Death Wish<span class="sub">Medium-dark blend. Nutty, semi-sweet chocolate.</span></li>
<li>full-bodied</li>
<li><b>Partners Coffee, Manhattan</b><span class="tag">new company</span><br>Dark, full-bodied, baker's chocolate and caramel. 12 oz for $20.<br><a href="https://www.partnerscoffee.com/products/manhattan">partnerscoffee.com/products/manhattan</a></li>
```

Before publishing, this must print `0` (grep also exits 1 on zero matches,
which is the pass here; judge by the printed count, not the exit code):

```
grep -c '{{' <the filled page>
```

Then publish with the Artifact tool as a **new** artifact (Dan keeps no old
pages; do not reuse an earlier URL), favicon a coffee cup, and open it:

```
open -a "Google Chrome" <artifact url>
```

Tell Dan focus is moving to Chrome in the same message.

## 3. Recommend five or six coffees

Read `recommended.json` first. Then the exclusion rules, from the script's
last two lines and the log:

- **Excluded as a new company:** every roaster in the tracker, and every
  roaster in `recommended.json`.
- **Eligible for an untried bag:** a roaster listed as "with a Yes" in the
  output. Its bag must not be in the tracker and must not be in the log.
- Mix the two kinds, and tag each item `new company` or `untried bag from a
  roaster you like`.

For each candidate: match it to the profile from step 1 (body, roast, low
acidity, the label words), then **fetch the product page** with WebFetch and
confirm it is live and shows the bag, roast, notes and price. A page that
does not load, or shows sold out, is not recommended; say sold out in the
chat if the coffee was otherwise the best fit. Recommend nothing whose page
you did not fetch.

Present them in the chat as a numbered list, one line of why it fits, price
and size, then the link on its own line. Say which one to buy if he buys
only one. Then fill `RECOMMENDATIONS` on the page and republish.

Append each one to `recommended.json` with today's date, roaster, coffee,
URL and kind. Never remove or edit an existing entry.

## 4. Finish

Run the suite if `analyze.py` was touched:

```
bash ~/.claude/skills/coffee-profile/test-coffee-profile.sh
```

End with the artifact link, the six recommendations, and the one-line
"what shifted since last time" from `SHIFT`.

## Common mistakes

| Mistake | Instead |
|---|---|
| Reporting a group in the Confounds block as a preference | Name the roaster. "Medium-light is your danger zone" was wrong; "three of those six are Tandem" was right. |
| Treating "washed" or "natural" as a finding | Check the blank count. On 2026-09-14 only four roasters recorded process at all. |
| Recommending from memory | Every link fetched, every run. Sold out and dead pages are the norm a year on. |
| Reusing the last page's URL | New artifact each run. |
| Recomputing a number by hand | `analyze.py --json` has every number, every coffee with its notes and origin, and the label words. Reading the CSV directly means something is missing from the script: add it there, test first. |
| Running `--record` twice in one profile | The second run makes the next profile compare against today. Record once, look as often as you like. |
