"""find_chrome_probe.py: prints the Chrome make-settled.py would measure a terminal design's windows in
(chrome_frame.find_chrome), or "REFUSED <why>" when it refuses, for test-hidden-chrome.sh
(claude-config#2191). A file of its own rather than code handed to python3 inline, so the command
guards that read a suite's commands can follow its imports."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import chrome_frame  # noqa: E402

try:
    print(chrome_frame.find_chrome())
except chrome_frame.ChromeError as err:
    print("REFUSED " + str(err))
