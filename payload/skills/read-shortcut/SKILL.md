---
name: read-shortcut
description: Extract and analyze Siri Shortcut (.shortcut) files: reads the AEA1 signed binary format, converts to inspectable JSON, and summarizes actions, flow logic, variables, and bugs.
user-invokable: true
args:
  - name: path
    description: Path to one or more .shortcut files (space-separated)
    required: true
---

Extract, parse, and analyze one or more Siri Shortcut files, then answer whatever the user needs: flow summary, bug diagnosis, action-by-action trace, or cross-shortcut dependency analysis.

## How .shortcut files are structured

Modern `.shortcut` files use Apple's **AEA1 signed archive** format:

```
[4 bytes]  Magic: "AEA1"
[4 bytes]  Flags
[4 bytes]  Signing certificate size (little-endian)
[N bytes]  Binary plist: signing certificate chain
[M bytes]  DER signature
[rest]     LZFSE-compressed Apple Archive (.aa) containing Shortcut.wflow
```

`Shortcut.wflow` is a **binary plist** with key `WFWorkflowActions`: an array of action dicts.

## Extraction pipeline

Run these steps for each `.shortcut` file provided:

**Step 1: Decompress the payload**

```python
import subprocess, re

with open(path, 'rb') as f:
    data = f.read()

idx = data.find(b'bvx2')   # LZFSE magic
chunk = data[idx:]
result = subprocess.run(
    ['compression_tool', '-decode', '-a', 'lzfse'],
    input=chunk, capture_output=True, timeout=10
)
aa_data = result.stdout
```

**Step 2: Extract the Apple Archive**

```bash
aa extract -i payload.aa -d /tmp/shortcut_out/
# Produces: Shortcut.wflow
```

**Step 3: Convert to JSON**

```bash
plutil -convert json -o output.json Shortcut.wflow
```

**Step 4: Parse in Python**

```python
import json
with open('output.json') as f:
    data = json.load(f)
actions = data['WFWorkflowActions']
```

## Full extraction script (all files at once)

```python
import subprocess, json, os

def extract_shortcut(path, out_json):
    with open(path, 'rb') as f:
        data = f.read()
    idx = data.find(b'bvx2')
    if idx == -1:
        raise ValueError(f"No LZFSE payload found in {path}")
    result = subprocess.run(
        ['compression_tool', '-decode', '-a', 'lzfse'],
        input=data[idx:], capture_output=True, timeout=10
    )
    aa_path = out_json + '.aa'
    out_dir = out_json + '_dir'
    os.makedirs(out_dir, exist_ok=True)
    with open(aa_path, 'wb') as f:
        f.write(result.stdout)
    subprocess.run(['aa', 'extract', '-i', aa_path, '-d', out_dir], check=True)
    wflow = os.path.join(out_dir, 'Shortcut.wflow')
    subprocess.run(['plutil', '-convert', 'json', '-o', out_json, wflow], check=True)
    with open(out_json) as f:
        return json.load(f)
```

## Key WFWorkflowActions fields to understand

Each action dict has:
- `WFWorkflowActionIdentifier`: the action type (e.g. `is.workflow.actions.getvalueforkey`)
- `WFWorkflowActionParameters`: all settings for that action

### Common action identifiers

| Identifier suffix | Meaning |
|---|---|
| `getvalueforkey` | Read key from dictionary |
| `setvalueforkey` | Write key to dictionary |
| `setvariable` | Assign to named variable |
| `getvariable` | Read named variable |
| `conditional` | If / Else / End If (`WFControlFlowMode`: 0=if, 1=else, 2=end) |
| `repeat.each` | For-each loop (`WFControlFlowMode`: 0=start, 2=end) |
| `runworkflow` | Call another shortcut |
| `text.replace` | Regex or literal find/replace |
| `text.split` | Split text into list |
| `text.match` | Regex match |
| `text.match.getgroup` | Extract capture group from match |
| `text.trimwhitespace` | Trim |
| `ask` | Prompt user for input |
| `dictionary` | Create or coerce-to dictionary |
| `detect.text` | Extract text from share sheet input |

### Condition codes (`WFCondition`)
- `4` = equals
- `5` = is not
- `8` = begins with
- `9` = ends with
- `99` = contains
- `100` = has any value
- `999` = does not contain

### Condition logic (`WFActionParameterFilterPrefix`)
- `0` = ALL (AND)
- `1` = ANY (OR)

### Variable references in text tokens
Token strings use `\ufffc` as a placeholder for variable attachments:
```json
{
  "string": "\ufffc",
  "attachmentsByRange": {
    "{0, 1}": {
      "VariableName": "myVar",       // named variable
      "OutputUUID": "UUID-...",       // magic variable (output of specific action)
      "Type": "ActionOutput"
    }
  }
}
```
**Magic variables** (OutputUUID) reference the output of a specific action by UUID, even from inside a loop. They retain the last value from the most recent execution of that action. This is important: using a magic variable from inside a loop after the loop ends gives you the last iteration's value, which may or may not be the full accumulated result.

## Analysis checklist

After extracting, work through these:

**Flow structure**
- [ ] How many actions total?
- [ ] What is the input type (`WFWorkflowInputContentItemClasses`)?
- [ ] Which other shortcuts does it call (`runworkflow`)? What does it pass?
- [ ] What variables does it build and pass out?

**Dictionary handling**
- [ ] List all keys read via `getvalueforkey`
- [ ] List all keys written via `setvalueforkey`
- [ ] Are any variables set from hardcoded `gettext` instead of the dictionary?
- [ ] Does any `runworkflow` call overwrite a dictionary that was passed in?

**Condition logic**
- [ ] Check every `conditional`: is the logic ALL vs ANY correct for its intent?
- [ ] Any typos in key names used in `getvalueforkey`?

**Loop variable bugs**
- [ ] After a loop, does any action use a magic variable (OutputUUID) from inside the loop instead of the accumulated variable? If so, it works only if the last iteration passed the condition.

**Text parsing**
- [ ] Does the split action's `WFTextSeparator` match the actual separators in the string? (e.g. "New Lines" vs "Custom" with `|||`)
- [ ] Do regex patterns correctly handle multi-line text? (`^` anchors to string start, `.` doesn't match newlines by default in ICU)

## Common bugs to flag

1. **OR vs AND in if-condition**: `WFActionParameterFilterPrefix: 1` (ANY) causes lines that match either condition to enter the block, often including lines that should be excluded.

2. **runworkflow passing magic variable instead of accumulated dict variable**, after a loop, the final `runworkflow` should use the named `dict` variable, not a magic variable from inside the loop.

3. **Hardcoded values that should come from the input dictionary**: `gettext` actions that set variables before the dictionary is ever consulted mean those values can never be overridden by callers.

4. **Caller doesn't send required keys**, if Shortcut A calls Shortcut B, and B checks for a key to change its behavior, A must include that key. Typos in key names (e.g. `rerunningShortut` vs `rerunningShortcut`) silently break the handshake.

5. **Caller dict gets overwritten**, if Shortcut B calls Shortcut C and overwrites `variableDict` with C's output, all data passed by A is lost. A must signal B to skip C, or B must merge rather than replace.

6. **Split separator mismatch**, if `%0A` is replaced with `|||` but splitting is set to "New Lines", URL-encoded input won't split. Must pick one strategy and be consistent.
