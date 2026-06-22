# Execution Surfaces

This document defines the six execution surfaces available to orchestration agents, their tool mappings, and the universal verification loop that applies to every action.

---

## The Six Surfaces

### 1. Browser (Web)

**Primary Tool:** Playwright MCP
**Use For:** Web applications, online dashboards, SaaS platforms, web-based forms, content management systems, social media platforms, cloud consoles

**Key Operations:**
- `browser_navigate` - Open URLs
- `browser_click` - Click elements
- `browser_fill_form` - Fill input fields
- `browser_snapshot` - Capture page state (accessibility tree)
- `browser_take_screenshot` - Visual capture for evidence
- `browser_evaluate` - Run JavaScript for complex interactions
- `browser_file_upload` - Upload files to web forms
- `browser_select_option` - Dropdown selections
- `browser_press_key` - Keyboard actions
- `browser_wait_for` - Wait for elements/conditions

**Verification Method:** `browser_snapshot` + content assertion. Take a snapshot, check for expected elements/text. Screenshot for visual evidence.

---

### 2. Native macOS Apps

**Primary Tool:** Peekaboo CLI
**Use For:** Desktop applications (Keynote, Pages, Numbers, Calendar, Mail, Finder, Preview, Terminal, System Preferences, any macOS app)

**Key Operations:**
- `peekaboo see --app "<App>"` - Capture current state of an app (returns element tree with IDs + screenshot)
- `peekaboo click --app "<App>" --on <ID>` - Click UI elements by ID from `see` output (e.g., B1, T2)
- `peekaboo click "<text>" --app "<App>"` - Click element by text query
- `peekaboo type "<text>" --app "<App>"` - Type text into focused field
- `peekaboo hotkey --keys "<keys>" --app "<App>"` - Press keyboard shortcuts (e.g., "cmd,c" or "cmd shift t")
- `peekaboo list apps` - List running applications
- `peekaboo list windows --app "<App>"` - List windows for an app
- `peekaboo app launch "<App>"` - Launch an application
- `peekaboo app switch --to "<App>"` - Bring app to foreground
- `peekaboo app quit --app "<App>"` - Quit an application
- `peekaboo menu click --app "<App>" --path "<Menu> > <Item>"` - Click menu items (use " > " separator)
- `peekaboo menu list --app "<App>"` - List all menu items for an app
- `peekaboo window focus --app "<App>"` - Focus a specific window
- `peekaboo paste "<text>" --app "<App>"` - Set clipboard and paste

**Verification Method:** `peekaboo see --app "<App>"` + element/content check. Capture the app state, verify expected elements exist and contain correct values.

---

### 3. Files

**Primary Tool:** Bash / Read / Write / Edit
**Use For:** Documents, configuration files, data exports, scripts, generated content, project artifacts, local databases

**Key Operations:**
- `Write` - Create new files
- `Edit` - Modify existing files
- `Read` - Read file contents
- `Bash` - Execute scripts, manage directories, run build tools
- `Glob` - Find files by pattern
- `Grep` - Search file contents

**Verification Method:** Read back the file and validate structure/content. For scripts, execute and check exit code + output. For structured data (JSON, YAML), parse and validate schema.

---

### 4. Communication

**Primary Tool:** Playwright MCP (web-based) or Peekaboo CLI (native Mail, Messages)
**Use For:** Sending emails, Slack messages, Discord messages, SMS, notifications, social media posts

**Key Operations:**
- Web-based: Playwright to navigate to platform, compose, send
- Native: Peekaboo to control Mail.app, Messages.app, etc.
- API-based: curl/MCP for services with APIs (Slack API, SendGrid, etc.)

**Verification Method:** After sending, check the "Sent" folder or delivery confirmation. For APIs, check response status. For web platforms, navigate to sent/outbox and verify the message appears.

---

### 5. Calendar

**Primary Tool:** Playwright MCP (Google Calendar, web) or Peekaboo CLI (Apple Calendar)
**Use For:** Scheduling events, setting reminders, managing time blocks, coordinating meetings

**Key Operations:**
- Web: Playwright to navigate calendar, create/edit events
- Native: Peekaboo to control Calendar.app
- API: Google Calendar API, Apple EventKit via shortcuts

**Verification Method:** After creating/modifying an event, read the calendar back and confirm the event exists with correct details (title, time, date, attendees, location).

---

### 6. APIs / MCPs

**Primary Tool:** MCP tools, curl, Bash
**Use For:** External service integrations, data fetching, webhooks, cloud services, databases, any programmatic interface

**Key Operations:**
- MCP tool calls (Notion, GitHub, Slack, custom servers)
- `curl` for REST APIs
- SDK calls via Bash scripts
- Database queries

**Verification Method:** Make a follow-up API call to confirm the action took effect. For creates: read back the created resource. For updates: fetch and compare. For deletes: confirm 404/not found. Check response status codes and payload.

---

### 7. Code

**Primary Tool:** Bash
**Use For:** Running scripts, builds, tests, deployments, package management, git operations

**Key Operations:**
- Execute scripts and commands
- Run test suites
- Build and compile
- Deploy artifacts
- Package management (npm, pip, brew, etc.)

**Verification Method:** Check exit code (0 = success). Validate stdout/stderr output. For builds, verify output artifacts exist. For tests, check pass/fail counts. For deployments, hit the deployed endpoint.

---

## The Verification Loop

**Every action on every surface follows this loop:**

```
Execute -> Verify -> (pass?) -> Done
                  -> (fail?) -> Analyze -> Adjust -> Retry (max 3) -> Escalate
```

### Step-by-Step Protocol

1. **Execute** - Perform the action on the target surface using the appropriate tool
2. **Verify** - Use the surface's verification method to confirm the action succeeded
3. **Record Evidence** - Save verification output (snapshots, screenshots, file contents, API responses) to PROGRESS.md
4. **If Pass** - Move to next action
5. **If Fail** - Analyze the failure:
   - What was expected vs what happened?
   - Is it a tool issue, a configuration issue, or a logic error?
6. **Adjust** - Modify the approach based on analysis
7. **Retry** - Re-execute with the adjusted approach (maximum 3 retries)
8. **Escalate** - If 3 retries fail, escalate using the 3-tier failure protocol:
   - Tier 1: Subagent self-recovery (try alternative approach)
   - Tier 2: Orchestrator intervention (spawn fix agent)
   - Tier 3: User escalation (provide error details, ask for help)

### Evidence Format

Record verification evidence in PROGRESS.md task notes:

```
Verified: [surface] [action] - [result]
Evidence: [snapshot excerpt / screenshot path / API response / file content hash]
Retries: [0-3] if applicable
```

---

## Surface Selection Guide

When a task involves multiple possible surfaces, prefer this priority:

1. **API/MCP** - Most reliable, most verifiable, fastest
2. **Files** - Direct, deterministic, easy to verify
3. **Code** - Scriptable, repeatable
4. **Browser (Web)** - When no API exists, use Playwright
5. **Native macOS** - When task requires desktop apps, use Peekaboo
6. **Communication** - Use API when available, fall back to browser/native
7. **Calendar** - Use API when available, fall back to browser/native

### Surface Tags in Task Files

Every task file tags its actions with the target surface:

```
[browser] Navigate to platform dashboard and configure settings
[native] Open Keynote and create presentation from template
[file] Generate configuration file at path/to/config.json
[api] Call Notion API to create database entry
[comm] Send notification email via SendGrid API
[calendar] Create event in Google Calendar
[code] Run build script and verify output
```

These tags tell execution agents which tools to use and which verification method to apply.

---

## Cross-Surface Coherence

When a task spans multiple surfaces, verify coherence:

1. **Data consistency** - Does the file content match what was entered in the web form?
2. **Timing** - Did the calendar event get created before the notification was sent?
3. **State sync** - After updating via API, does the browser view reflect the change?
4. **Handoff integrity** - When output from one surface feeds into another, verify the handoff

Cross-surface checks happen during the Synergy Review phase (Phase 11) and during verification sweeps.
