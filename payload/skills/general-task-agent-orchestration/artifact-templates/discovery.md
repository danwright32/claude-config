# DISCOVERY.md Template

Use this template when creating the Discovery document (Phase 3). This becomes the **top authority** document - all other artifacts defer to it.

---

```markdown
# <Project Name> - Discovery Document

**Created**: <date>
**Status**: <In Progress | Complete>
**Category**: <Content Creation | Course/Curriculum | Research | Operations/Workflow | Event/Project Coordination | Outreach/Hiring>
**Rounds of Q&A**: <N>

---

## 1. <Domain Category>

**D1: <Question>**
A: <User's answer>

**D2: <Question>**
A: <User's answer>

---

## 2. <Domain Category>

**D3: <Question>**
A: <User's answer>

**D4: <Question>**
A: <User's answer>

---

## N. <Domain Category>

...
```

---

## Universal Question Domains (Always Ask)

1. **Vision and Goals** - What is this? Who is it for? What does success look like?
2. **Scope and Boundaries** - What's IN scope? What's explicitly OUT? What's deferred?
3. **Tool and Platform Preferences** - Preferred tools, platforms, services?
4. **Workflow and Process** - How should things flow from start to finish?
5. **Quality Standards** - What does "good enough" look like? What's the bar?
6. **External Services and Integrations** - What platforms, APIs, services are involved?
7. **Scheduling and Timeline** - Deadlines, milestones, time constraints?
8. **Edge Cases and Error Handling** - What happens when things go wrong?
9. **Communication and Distribution** - How are outputs delivered? To whom?
10. **Existing Assets** - What already exists that can be leveraged?
11. **Verification Criteria** - How do we know each piece is "done" and correct?
12. **Execution Surfaces** - Which surfaces (browser, native apps, files, APIs, etc.) are needed?

---

## Category-Specific Question Sets

Use the relevant set based on the project category. These supplement (not replace) the universal domains above.

### Content Creation

- What content types are being produced? (articles, videos, social posts, newsletters, etc.)
- What is the voice/tone? Formal, casual, technical, conversational?
- What are the target platforms and their specific format requirements?
- What is the publishing cadence and schedule?
- What content already exists that can be repurposed or referenced?
- What is the approval workflow? (auto-publish, draft review, editorial process)
- How is content performance measured? What metrics matter?
- Are there brand guidelines, style guides, or visual standards?
- What media assets are needed? (images, graphics, thumbnails, etc.)
- How should content be archived or organized after publishing?

### Course / Curriculum

- What is the learning outcome? What should students be able to do after completing this?
- What is the format? (live sessions, pre-recorded, text-based, hybrid)
- What platform hosts the course? (Skool, Teachable, Notion, custom LMS, etc.)
- How many modules/lessons? What is the structure?
- What assessment methods are used? (quizzes, projects, peer review, certificates)
- What prerequisite knowledge is assumed?
- What supplementary materials are needed? (worksheets, slides, resource lists)
- How do students interact? (comments, forum, live Q&A, community)
- What is the pricing model? (free, paid, subscription, cohort-based)
- What is the launch strategy? (drip content, all-at-once, cohort dates)

### Research Projects

- What is the research question or hypothesis?
- What methodologies are appropriate? (qualitative, quantitative, mixed methods)
- What data sources will be used? (APIs, databases, surveys, literature, web scraping)
- What tools are needed for analysis? (Python, R, spreadsheets, specialized software)
- What is the output format? (report, paper, presentation, dashboard, dataset)
- What are the ethical considerations or data privacy requirements?
- Who is the audience for the research output?
- What is the review/validation process?
- How should raw data be stored and organized?
- What is the timeline for each research phase?

### Operations / Workflow Setup

- What is the current workflow? (manual steps, existing tools, pain points)
- What is the desired end state? (fully automated, semi-automated, streamlined manual)
- What tools and platforms are involved? (CRM, project management, communication, storage)
- What triggers each workflow step? (time-based, event-based, manual)
- What are the integration points between systems?
- Who are the stakeholders and what are their roles?
- What data flows between systems? What formats?
- What are the failure modes and fallback procedures?
- What monitoring or alerting is needed?
- What is the migration plan from current to new workflow?

### Event / Project Coordination

- What type of event? (conference, workshop, meetup, webinar, launch, campaign)
- What is the venue/platform? (physical, virtual, hybrid)
- What is the expected attendance/scale?
- What is the timeline with key milestones?
- What are the logistics? (speakers, materials, AV, catering, registration)
- What communication is needed? (invitations, reminders, follow-ups)
- What tools manage the coordination? (project management, calendar, communication)
- What are the budget constraints?
- What is the contingency plan?
- How will success be measured post-event?

### Outreach / Hiring

- What positions/roles are being filled? Or what outreach goals exist?
- What channels are being used? (job boards, LinkedIn, email, referrals, social)
- What is the candidate/contact pipeline? (sourcing, screening, interview, offer)
- What tools manage the pipeline? (ATS, CRM, spreadsheet, Notion)
- What templates are needed? (outreach messages, job descriptions, evaluation rubrics)
- What is the evaluation criteria? How are candidates/contacts scored?
- What is the timeline for each stage?
- What communication templates are needed at each stage?
- What data needs to be tracked? (response rates, conversion, time-to-fill)
- What is the approval workflow? (hiring manager, team, HR)

---

## Question Style

- **Ask specific, decision-forcing questions** - not "tell me about the timeline" but "is this a 2-week sprint or a 3-month rollout?"
- **Offer options when relevant** - "Option A: X. Option B: Y. Which do you prefer?"
- **Ask follow-ups** - don't accept vague answers, drill down to specifics
- **Number every decision** - D1, D2, D3... for easy cross-referencing
- **Group by domain** - makes the document scannable

## Critical Rules

- **DISCOVERY.md is the top authority** - it overrides Project Brief, research files, and all other docs
- **Store EVERY question and answer** - even "obvious" ones, for completeness
- **Don't stop too early** - keep asking until you have enough detail to execute without guessing
- **Include scope exclusions** - "what's NOT in scope" decisions are as important as inclusions
- **Tag execution surfaces** - note which surfaces each decision affects
- **After all Q&A, update the status** to "Complete" and record total rounds
