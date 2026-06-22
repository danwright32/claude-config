#!/bin/bash
# Re-inject project CLAUDE.md after context compaction via hookSpecificOutput
INPUT=$(cat)
CWD=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null)
[ -z "$CWD" ] && exit 0

PROJECT=$(basename "$CWD")
CLAUDE_MD="$CWD/CLAUDE.md"

if [ -f "$CLAUDE_MD" ]; then
  CONTENT=$(cat "$CLAUDE_MD")
  python3 -c "
import json, sys
content = sys.stdin.read()
project = '$PROJECT'
output = {
  'hookSpecificOutput': {
    'additionalContext': f'Context was compacted. Project: {project}. CLAUDE.md contents:\\n{content}'
  }
}
print(json.dumps(output))
" <<< "$CONTENT"
else
  python3 -c "
import json
print(json.dumps({'hookSpecificOutput': {'additionalContext': 'Context was compacted. Project: $PROJECT. No CLAUDE.md found — proceed with care.'}}))
"
fi
