#!/usr/bin/env python3
"""Push the field card into an Apple Note, with real tick boxes.

    python3 push_to_notes.py path/to/<event>-card.md --folder Reels

The markdown card stays the single source of truth. This regenerates the note
from it, so the two cannot drift.

Why it works the way it does. Apple Notes checkboxes are a proprietary format
that AppleScript cannot write: the checkbox state does not live in the note's
HTML at all. The only route is to create the note with plain content and then
have Notes convert it, via the Format menu's checklist command (Shift+Cmd+L),
which turns every block into a tick box. That last step needs the keyboard.
The script activates Notes and focuses the note body itself (added 2026-07-28,
at Dan's request, so no manual click into Notes is needed), then verifies both
that Notes is frontmost and that focus really is a text area before sending
anything, and says so rather than typing into whatever is there.

Verified against Notes on macOS, 2026-07-23: bold and font size survive the
conversion, so headings stay legible.
"""

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from render_card import notes_blocks  # noqa: E402


def _osascript(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(["osascript", "-e", script],
                          capture_output=True, text=True)


def _applescript_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def create_note(title: str, body: str, folder: str) -> subprocess.CompletedProcess:
    return _osascript(f'''
tell application "Notes"
  try
    delete (every note of folder {_applescript_string(folder)} ¬
      whose name is {_applescript_string(title)})
  end try
  set fresh to make new note at folder {_applescript_string(folder)} ¬
    with properties {{name:{_applescript_string(title)}, body:{_applescript_string(body)}}}
  activate
  show fresh
end tell
''')


def runs_of(paragraphs: list) -> list:
    """Group sorted paragraph numbers into contiguous (start, length) runs."""
    runs = []
    for n in paragraphs:
        if runs and n == runs[-1][0] + runs[-1][1]:
            runs[-1] = (runs[-1][0], runs[-1][1] + 1)
        else:
            runs.append((n, 1))
    return runs


def apply_checklist(title: str, paragraphs: list) -> subprocess.CompletedProcess:
    """Tick-box only the given paragraphs, refusing to type anywhere unsafe.

    Selecting whole paragraphs, rather than Cmd+A, is the whole point: an
    earlier version ticked the headings and the camera settings too. Notes
    moves by paragraph on Option+Down, which is immune to how lines happen to
    wrap in the window.

    The anchor must land on the *start* of the first paragraph in a run. Moving
    down N paragraphs leaves the cursor at the end of paragraph N, and a
    selection that merely touches a paragraph formats the whole of it, so one
    Right arrow is needed to step over the boundary.
    """
    steps = []
    for start, length in runs_of(paragraphs):
        steps.append(f'''
  key code 126 using command down
  delay 0.25
  repeat {start - 1} times
    key code 125 using option down
    delay 0.06
  end repeat
  key code 124
  delay 0.15
  repeat {length} times
    key code 125 using {{option down, shift down}}
    delay 0.06
  end repeat
  keystroke "l" using {{command down, shift down}}
  delay 0.5''')

    return _osascript(f'''
tell application "Notes"
  activate
  show note {_applescript_string(title)}
end tell
delay 1.5
tell application "System Events"
  set frontApp to name of first application process whose frontmost is true
  if frontApp is not "Notes" then
    return "ABORTED: frontmost is " & frontApp & ". Nothing sent."
  end if
  tell application process "Notes"
    -- Focus the note body ourselves: after "show", focus sits on the notes
    -- list, not the body. The body is the one scroll area of the split view
    -- that contains a text area; the index shifts with the sidebar, so search.
    set noteBody to missing value
    repeat with sa in (scroll areas of splitter group 1 of window 1)
      try
        set noteBody to text area 1 of sa
        exit repeat
      end try
    end repeat
    if noteBody is missing value then
      return "ABORTED: could not find the note body. Nothing sent."
    end if
    set value of attribute "AXFocused" of noteBody to true
    delay 0.4
    -- Setting AXFocused is sometimes silently ignored (seen 2026-07-28). The
    -- fallback is one click inside the body, at coordinates read off the
    -- element itself. Safe at this point: the note is still plain text with
    -- no checkboxes to toggle, so a click can only place the cursor.
    set landed to false
    try
      if (role of (value of attribute "AXFocusedUIElement")) is "AXTextArea" then
        set landed to true
      end if
    end try
    if not landed then
      set p to position of noteBody
      set s to size of noteBody
      click at {{(item 1 of p) + ((item 1 of s) div 2), (item 2 of p) + 30}}
      delay 0.4
    end if
    -- The guard stays: verify focus actually landed before any keystroke.
    if (role of (value of attribute "AXFocusedUIElement")) is not "AXTextArea" then
      return "ABORTED: focus is not the note body. Nothing sent."
    end if
  end tell
{"".join(steps)}
end tell
return "applied"
''')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("card", type=Path)
    ap.add_argument("--folder", default="Reels")
    ap.add_argument("--title", default=None,
                    help="defaults to the card's first heading")
    args = ap.parse_args()

    if not args.card.is_file():
        print(f"error: no such card: {args.card}", file=sys.stderr)
        return 1

    lines = args.card.read_text().splitlines()
    title = args.title or lines[0].lstrip("# ").strip()
    # Notes takes the title from the name property. Repeating the card's own
    # first heading in the body shows it twice.
    blocks = notes_blocks("\n".join(lines[1:]))
    body = "".join(b.html for b in blocks)
    tickable = [b.paragraph for b in blocks if b.tickable]

    r = create_note(title, body, args.folder)
    if r.returncode != 0:
        print(f"error creating note: {r.stderr.strip()}", file=sys.stderr)
        return 1

    r = apply_checklist(title, tickable)
    out = r.stdout.strip()
    if out.startswith("ABORTED"):
        print(f"note created, but tick boxes NOT applied.\n{out}\n"
              f"Leave Notes frontmost and run this again.", file=sys.stderr)
        return 1

    print(f'wrote note "{title}" to "{args.folder}": '
          f'{len(tickable)} tick boxes, {len(blocks) - len(tickable)} plain lines')
    return 0


if __name__ == "__main__":
    sys.exit(main())
