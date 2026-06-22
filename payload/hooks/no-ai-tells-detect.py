#!/usr/bin/env python3
"""
UserPromptSubmit hook: detects prose writing intent and injects the no-ai-tells skill.
Fires on writing requests (articles, blogs, copy, tooltips, sentences, etc.)
but NOT on code writing requests.
"""
import json
import sys

try:
    data = json.load(sys.stdin)
    prompt = data.get("prompt", "").lower()

    # Direct prose format signals — these always trigger regardless of verb
    prose_terms = [
        "blog post", "blog entry", "article", "essay", "press release",
        "marketing copy", "product description", "landing page copy",
        "tooltip", "tagline", "slogan", "cover letter", "newsletter",
        "announcement", "caption", "headline", "blurb", "bio ",
        "about us", "about me", "social media post", "tweet",
        "email copy", "sales copy", "microcopy", "error message copy",
        "placeholder text", "onboarding copy", "ui copy", "ux copy",
        "ad copy", "call to action", "cta copy", "testimonial",
        "product copy", "pitch", "elevator pitch",
    ]

    # Verbs that indicate writing intent
    write_verbs = [
        "write", "draft", "compose", "author", "pen ",
        "rewrite", "rephrase", "reword", "paraphrase",
        "revise", "edit this copy", "improve this copy",
        "make this sound", "clean up this", "fix this copy",
        "polish this", "humanize", "de-ai",
    ]

    # Code signals — if these appear alongside a write verb, it's NOT prose
    code_terms = [
        "code", "function", "script", "test ", "class ",
        "component", "method", "module", "program", "api",
        "endpoint", "query", "algorithm", "snippet", "implementation",
        "refactor", "sql", "regex", "command", "cli",
    ]

    is_writing = False

    # Check direct prose format matches
    if any(term in prompt for term in prose_terms):
        is_writing = True

    # Check write verb + no code signal
    if not is_writing:
        has_write_verb = any(verb in prompt for verb in write_verbs)
        has_code_signal = any(code in prompt for code in code_terms)
        if has_write_verb and not has_code_signal:
            is_writing = True

    if is_writing:
        skill_path = "/Users/danhankins-wright/.claude/skills/no-ai-tells/SKILL.md"
        with open(skill_path, "r") as f:
            skill_content = f.read()
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": skill_content,
            }
        }))

except Exception:
    pass
