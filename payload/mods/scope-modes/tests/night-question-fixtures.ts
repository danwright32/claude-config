// The one committed set of cases both readers of an overnight question are held to (#3056, L83,
// L342): the morning pickers (notAQuestion and distinctQuestions in hooks/settled.ts, held to these
// in tests/settled.test.ts) and the night's report (not_a_question and distinct_questions in
// payload/hooks/lib/sleep-report.py, held to these in payload/hooks/test-sleep-report.sh). The two
// ask the same question of the same notes, which question is Dan's to answer and which notes are one
// question, but one is TypeScript and the other Python, so the rule cannot be one function: it is
// these cases, and a change to either reader that the other does not make fails a suite.
//
// Everything after each `=` below, to the `]` that closes it at the start of a line, is plain JSON,
// which is what lets the shell suite read it too: keep it JSON (double quotes, no trailing commas,
// no comments inside), or that suite fails.

// Whether a note is no question: it has no answers to pick from, asks nothing, and a part of it says,
// whole, that it asks nothing. A part that only mentions one (no decision needed on the rename) says
// nothing about the rest, and a note that asks anything is offered whatever else it says, so a doubt
// keeps a note offered: a note offered that asked nothing costs Dan a skip, one hidden that asked
// something is never answered (L648).
export const NOT_A_QUESTION_FIXTURES = [
  { "name": "the incident: a build order note saying it is not a question", "text": "Build order for tonight: the schema change lands before the importer. This is not a question, nothing to answer.", "options": [], "notAQuestion": true },
  { "name": "an FYI label and no answer needed", "text": "FYI: the importer waits on the schema change. No answer needed.", "options": [], "notAQuestion": true },
  { "name": "a closing sentence saying no decision is needed", "text": "The importer waits on the schema change. No decision needed.", "options": [], "notAQuestion": true },
  { "name": "fyi at the end, in lower case", "text": "The importer waits on the schema change, fyi", "options": [], "notAQuestion": true },
  { "name": "a web address with a query is no question mark", "text": "The run is at https://example.test/runs?page=2. Nothing to decide.", "options": [], "notAQuestion": true },
  { "name": "a real question", "text": "Round totals up or down?", "options": [], "notAQuestion": false },
  { "name": "a question beside a part that asks nothing about something else (#3056)", "text": "Merge #5 now? No decision needed on the rename.", "options": [], "notAQuestion": false },
  { "name": "no decision needed on one thing says nothing about the rest", "text": "Merge #5 now. No decision needed on the rename.", "options": [], "notAQuestion": false },
  { "name": "a question with no question mark is still asked", "text": "FYI: should the cache be per account", "options": [], "notAQuestion": false },
  { "name": "fyi inside a statement says nothing of the whole note", "text": "The fyi banner stays, it is two lines.", "options": [], "notAQuestion": false },
  { "name": "a note with answers to pick is a question whatever it says", "text": "Build order for tonight. This is not a question, nothing to answer.", "options": ["Yes", "No"], "notAQuestion": false },
  { "name": "one answer to pick is no choice", "text": "FYI: the importer waits. No answer needed.", "options": ["Fine"], "notAQuestion": true }
]

// Which notes are one question: the same words (spacing aside) about the same place. A repository or
// issue only one of them gives is no difference (one noting by repository, one by folder); two
// folders, neither naming its repository, are two places. Each case is the questions in the order
// noted and the questions offered, in the order first noted, each carrying what the other lacked.
export const DISTINCT_FIXTURES = [
  {
    "name": "the incident: once by repository, once by folder, is one carrying both",
    "questions": [
      { "repo": "exampleco/ledger", "issue": 41, "cwd": null, "text": "Apply the migration in PR #52?", "options": ["Apply it", "Leave it"] },
      { "repo": null, "issue": null, "cwd": "/w/ledger", "text": "Apply the  migration in PR #52?" }
    ],
    "distinct": [
      { "repo": "exampleco/ledger", "issue": 41, "cwd": "/w/ledger", "text": "Apply the migration in PR #52?", "options": ["Apply it", "Leave it"] }
    ]
  },
  {
    "name": "the second noting's choices fill the first's",
    "questions": [
      { "repo": null, "issue": null, "cwd": "/w/ledger", "text": "Keep the old flag?" },
      { "repo": "ExampleCo/Ledger", "issue": null, "cwd": null, "text": "Keep the old flag?", "options": ["Keep", "Drop"] }
    ],
    "distinct": [
      { "repo": "ExampleCo/Ledger", "issue": null, "cwd": "/w/ledger", "text": "Keep the old flag?", "options": ["Keep", "Drop"] }
    ]
  },
  {
    "name": "the same words about two repositories stay two",
    "questions": [
      { "repo": "exampleco/ledger", "issue": null, "cwd": null, "text": "Keep it?" },
      { "repo": "exampleco/atlas", "issue": null, "cwd": null, "text": "Keep it?" }
    ],
    "distinct": [
      { "repo": "exampleco/ledger", "issue": null, "cwd": null, "text": "Keep it?" },
      { "repo": "exampleco/atlas", "issue": null, "cwd": null, "text": "Keep it?" }
    ]
  },
  {
    "name": "the same words about two issues stay two",
    "questions": [
      { "repo": "exampleco/ledger", "issue": 3, "cwd": null, "text": "Keep it?" },
      { "repo": "exampleco/ledger", "issue": 4, "cwd": null, "text": "Keep it?" }
    ],
    "distinct": [
      { "repo": "exampleco/ledger", "issue": 3, "cwd": null, "text": "Keep it?" },
      { "repo": "exampleco/ledger", "issue": 4, "cwd": null, "text": "Keep it?" }
    ]
  },
  {
    "name": "two folders, neither naming its repository, stay two",
    "questions": [
      { "repo": null, "issue": null, "cwd": "/w/ledger", "text": "Keep it?" },
      { "repo": null, "issue": null, "cwd": "/w/atlas", "text": "Keep it?" }
    ],
    "distinct": [
      { "repo": null, "issue": null, "cwd": "/w/ledger", "text": "Keep it?" },
      { "repo": null, "issue": null, "cwd": "/w/atlas", "text": "Keep it?" }
    ]
  },
  {
    "name": "one repository noted from two folders, such as a worktree, is one",
    "questions": [
      { "repo": "exampleco/ledger", "issue": null, "cwd": "/w/ledger", "text": "Keep it?" },
      { "repo": "exampleco/ledger", "issue": null, "cwd": "/w/ledger-wt", "text": "Keep it?" }
    ],
    "distinct": [
      { "repo": "exampleco/ledger", "issue": null, "cwd": "/w/ledger", "text": "Keep it?" }
    ]
  }
]
