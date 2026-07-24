#!/usr/bin/env python3
"""Push the field card into an Apple Note, with real tick boxes.

    python3 push_to_notes.py path/to/<event>-card.md --folder Reels

The markdown card stays the single source of truth. This regenerates the note
from it, so the two cannot drift.

Why it works the way it does. Apple Notes checkboxes are a proprietary format
that AppleScript cannot write: the checkbox state does not live in the note's
HTML at all. The only route is to create the note with plain content and then
have Notes convert it, via the Format menu's checklist command (Shift+Cmd+L),
which turns every block into a tick box. That last step needs the keyboard, so
this script refuses to send a keystroke unless Notes is frontmost with the
cursor in the note body, and says so rather than typing into whatever is there.

Verified against Notes on macOS, 2026-07-23: bold and font size survive the
conversion, so headings stay legible.
"""

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from render_card import notes_body  # noqa: E402


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


def apply_checklist(title: str) -> subprocess.CompletedProcess:
    """Convert every block to a tick box, refusing to type anywhere unsafe."""
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
    if (role of (value of attribute "AXFocusedUIElement")) is not "AXTextArea" then
      return "ABORTED: focus is not the note body. Nothing sent."
    end if
  end tell
  keystroke "a" using command down
  delay 0.4
  keystroke "l" using {{command down, shift down}}
  delay 1.0
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
    body = notes_body("\n".join(lines[1:]))

    r = create_note(title, body, args.folder)
    if r.returncode != 0:
        print(f"error creating note: {r.stderr.strip()}", file=sys.stderr)
        return 1

    r = apply_checklist(title)
    out = r.stdout.strip()
    if out.startswith("ABORTED"):
        print(f"note created, but tick boxes NOT applied.\n{out}\n"
              f"Open the note, select all, and press Shift+Cmd+L yourself.",
              file=sys.stderr)
        return 1

    print(f'wrote note "{title}" to folder "{args.folder}" with tick boxes')
    return 0


if __name__ == "__main__":
    sys.exit(main())
