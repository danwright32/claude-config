#!/usr/bin/env python3
"""
UserPromptSubmit hook: detects prose writing intent and injects the no-ai-tells skill.
Fires on writing requests (articles, blogs, copy, tooltips, sentences, etc.)
but NOT on code writing requests.
"""
import json
import os
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
        skill_path = os.path.expanduser("~/.claude/skills/no-ai-tells/SKILL.md")
        try:
            with open(skill_path, "r") as f:
                skill_content = f.read()
        except Exception as exc:
            # Said out loud, because this is the worst of the three outcomes and it used to be the
            # quietest. Having DECIDED the prompt is asking for prose, injecting nothing looks
            # exactly like having decided it was not, so the copy goes out with every tell the
            # skill exists to remove and nothing anywhere reports it (L11, L98). It can happen for
            # real: the skill lives in the config directory, not in this repo, so a Mac that has
            # not synced yet has the hook and not the skill.
            print(
                "[no-ai-tells] this prompt asks for prose, but the no-ai-tells skill could not be "
                "read from %s (%s), so nothing was loaded for it. Run 'claude-sync pull'."
                % (skill_path, exc),
                file=sys.stderr,
            )
        else:
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": skill_content,
                }
            }))

except Exception:
    # A payload that does not parse is not worth a word: this runs on EVERY prompt, and a hook that
    # complains about the shape of something it was handed would say it on all of them.
    pass
