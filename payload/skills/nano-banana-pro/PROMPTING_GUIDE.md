# Nano Banana Pro (Imagen 3) Prompting Guide

Research compiled from Google's official Vertex AI documentation.

---

## Core Formula: Subject + Context + Style

Every prompt should include:

1. **Subject** - The object, person, animal, or scenery you want
2. **Context/Background** - Where the subject is placed (studio, outdoors, etc.)
3. **Style** - The visual style (photo, illustration, sketch, 3D render, etc.)

**Example:** "A sketch (style) of a modern apartment building (subject) surrounded by skyscrapers (context)"

---

## Imagen 3 Specific Tips

### Short vs Long Prompts
- **Short prompts** work well for quick generation
- **Long prompts** add specific details and build your vision
- Iterate: Start with core idea, refine until you get what you want

### Descriptive Language
- Use detailed adjectives and adverbs
- Be specific about what you want to see
- Reference specific artists or styles if you have a vision

### Text in Images
- **Keep text under 25 characters** for best results
- Use 2-3 distinct phrases max
- Specify font style (bold, serif, modern) - expect creative interpretation
- Specify size (small, medium, large)
- Guide placement but expect variations

**Example:** `A poster with the text "Summerland" in bold font as a title, underneath is the slogan "Summer never felt so good"`

---

## Style Modifiers

### Photography
Start with "A photo of..." then add:
- **Camera proximity:** close up, taken from far away
- **Camera position:** aerial, from below, eye level
- **Lighting:** natural, dramatic, warm, cold, studio
- **Camera settings:** motion blur, soft focus, bokeh, portrait mode
- **Lens types:** 35mm, 50mm, fisheye, wide angle, macro
- **Film types:** black and white, polaroid, vintage

### Illustration/Art
Start with "A painting of...", "A sketch of...", "An illustration of..."
- Digital art, vector illustration, watercolor, oil painting
- Minimalist, flat design, isometric 3D
- Cartoon, anime, comic book style

### Materials & Shapes
- "...made of [material]..."
- "...in the shape of..."
- Great for creative/impossible imagery

### Historical Art References
- "...in the style of [art period/movement]..."
- Art deco, pop art, impressionist, etc.

---

## Quality Modifiers

Add these to boost output quality:

**General:**
- high-quality
- beautiful
- stylized
- professional

**Photos:**
- 4K
- HDR
- studio photo
- cinematic

**Art/Illustration:**
- by a professional
- detailed
- polished
- clean lines

---

## Aspect Ratios

- **1:1 (Square)** - Social media posts (default)
- **4:3 (Fullscreen)** - Photography, presentations
- **3:4 (Portrait)** - Mobile-first content
- **16:9 (Widescreen)** - YouTube thumbnails, banners
- **9:16 (Vertical)** - Stories, TikTok, Reels

---

## Template Prompts

### Course Thumbnail / UI Element
```
A clean, minimalist [style] showing [subject]. 
Background: [solid color / gradient / simple].
Style: modern, professional, high-quality.
Include text "[TEXT]" in [font style] at [position].
```

### Product/Logo
```
A [style] logo/icon for [subject].
Style: [minimalist/modern/vintage].
Colors: [color palette].
Background: [solid color].
Include the text "[TEXT]".
```

### Tech/Software Illustration
```
A [style] illustration of [software UI element].
Include: [specific elements like terminal, icons, buttons].
Style: modern, clean, professional.
Color scheme: [colors].
```

---

## Common Failures & Fixes

| Issue | Fix |
|-------|-----|
| Text garbled | Keep under 25 chars, simpler fonts |
| Wrong style | Be more explicit: "photorealistic" vs "illustration" |
| Missing elements | List each element explicitly |
| Poor quality | Add quality modifiers: "high-quality, detailed, 4K" |
| Wrong composition | Specify camera/position: "centered, front view" |

---

## Iteration Workflow

1. **Draft (1K):** Quick test with basic prompt
2. **Refine:** Add/remove descriptors based on output
3. **Iterate:** Small changes, new filename each time
4. **Final (4K):** Only when prompt is locked

Save your successful prompts for reuse!
