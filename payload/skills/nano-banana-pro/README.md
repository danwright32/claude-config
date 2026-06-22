# Nano Banana 2 - Image Generation Skill for Claude Code

Generate and edit images directly from your terminal using Google's Nano Banana 2 (Gemini 3.1 Flash Image) API as a Claude Code skill.

## What It Does

This skill gives Claude Code the ability to generate and edit images on command. Ask Claude to create an image and it handles everything - prompt engineering, API calls, file saving - without leaving your terminal.

**Powered by Gemini 3.1 Flash Image** - Google's latest image generation model. 3-5x faster than the previous generation with lower costs at high resolutions.

## Features

- **Text-to-image generation** - Describe what you want, get a PNG
- **Image editing** - Pass an existing image + instructions to modify it
- **4 resolution tiers** - 0.5K (512px), 1K (1024px), 2K (2048px), 4K (4096px)
- **14 aspect ratios** - From 1:1 square to 21:9 ultrawide
- **Image Search Grounding** - Reference real-world subjects with visual accuracy
- **Auto-resolution detection** - When editing, matches output to input image size
- **Zero-dependency workflow** - Uses `uv` for automatic dependency management

## Prerequisites

- [Claude Code](https://claude.ai/code) installed
- [uv](https://docs.astral.sh/uv/) installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- A [Gemini API key](https://aistudio.google.com/apikey) set as `GEMINI_API_KEY` environment variable

## Installation

### Option 1: Clone to Claude Code skills directory (recommended)

```bash
git clone https://github.com/grandamenium/nano-banana-2-skill.git ~/.claude/skills/nano-banana-pro
```

### Option 2: Clone anywhere and symlink

```bash
git clone https://github.com/grandamenium/nano-banana-2-skill.git ~/nano-banana-2-skill
ln -s ~/nano-banana-2-skill ~/.claude/skills/nano-banana-pro
```

### Option 3: Manual copy

```bash
git clone https://github.com/grandamenium/nano-banana-2-skill.git
cp -r nano-banana-2-skill ~/.claude/skills/nano-banana-pro
```

After installation, Claude Code will automatically discover the skill via the SKILL.md file.

## Usage

Once installed, just ask Claude naturally:

- "Generate an image of a sunset over mountains"
- "Create a 16:9 thumbnail for my video about AI"
- "Edit this screenshot to remove the watermark"
- "Make a 4K wallpaper of a cyberpunk city"

Or run the script directly:

```bash
# Generate
uv run ~/.claude/skills/nano-banana-pro/scripts/generate_image.py \
  --prompt "A serene Japanese garden with cherry blossoms" \
  --filename "japanese-garden.png" \
  --resolution 2K \
  --aspect-ratio 16:9

# Edit existing image
uv run ~/.claude/skills/nano-banana-pro/scripts/generate_image.py \
  --prompt "Make the sky more dramatic" \
  --filename "dramatic-sky.png" \
  --input-image "original.jpg"

# With grounding (real-world subjects)
uv run ~/.claude/skills/nano-banana-pro/scripts/generate_image.py \
  --prompt "A detailed painting of a Timareta butterfly" \
  --filename "butterfly.png" \
  --resolution 2K \
  --grounding
```

## Script Options

| Flag | Description |
|------|-------------|
| `--prompt`, `-p` | Image description or editing instructions (required) |
| `--filename`, `-f` | Output filename (required) |
| `--input-image`, `-i` | Input image path for editing |
| `--resolution`, `-r` | `0.5K`, `1K` (default), `2K`, `4K` |
| `--aspect-ratio`, `-a` | `1:1`, `16:9`, `9:16`, `21:9`, and 10 more |
| `--grounding`, `-g` | Enable Google Image Search grounding |
| `--api-key`, `-k` | Override GEMINI_API_KEY env var |

## Resolution Guide

| Tier | Size | Best For | Cost |
|------|------|----------|------|
| 0.5K | ~512px | Thumbnails, previews, fast drafts | Cheapest |
| 1K | ~1024px | Standard generation, iteration | $0.067 |
| 2K | ~2048px | High-quality output | $0.101 |
| 4K | ~4096px | Final production images | $0.151 |

## Aspect Ratios

1:1, 1:4, 1:8, 2:3, 3:2, 3:4, 4:1, 4:3, 4:5, 5:4, 8:1, 9:16, 16:9, 21:9

Common mappings: square (1:1), landscape/widescreen (16:9), portrait/stories (9:16), cinematic (21:9), banner (4:1 or 8:1)

## Recommended Workflow

1. **Draft at 0.5K** - Fast iteration, cheap, get the prompt right
2. **Iterate at 1K** - Refine with better quality feedback
3. **Final at 4K** - Only when you're happy with the prompt

## Files

- `SKILL.md` - Claude Code skill definition (auto-discovered)
- `PROMPTING_GUIDE.md` - Tips for getting better results
- `scripts/generate_image.py` - The generation script

## Credits

Built for the [Agent Architects](https://www.skool.com/agent-architects) community.
