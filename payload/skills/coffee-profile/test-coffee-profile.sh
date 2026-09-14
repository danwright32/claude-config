#!/usr/bin/env bash
# Suite for the coffee-profile skill. Named test-*.sh so run-all-tests.sh
# discovers it from disk; the tests themselves are Python (stdlib unittest).
set -euo pipefail
cd "$(dirname "$0")"
python3 -m unittest discover -s tests -p 'test_*.py' -v
