"""Ad-hoc single-image describer for the Civ VI Access blind-first work.

Sibling of tools/wonder-describer/describe.py (batch-oriented, JSON+LOC
output, for shipping descriptions of leader/civ/wonder portraits). This
one is for one-off descriptions during flow-tracing — "what does this
advisor portrait look like" or "describe this loading screen."

Reads GEMINI_API_KEY from environment (set once via Windows User env var:
[Environment]::SetEnvironmentVariable("GEMINI_API_KEY", "<key>", "User")).

Usage:
    python tools/describe-image.py --image path/to/shot.png
    python tools/describe-image.py --image path/to/shot.png \\
        --prompt "Describe this in-game advisor's appearance briefly"
    python tools/describe-image.py --image path/to/shot.png \\
        --prompt-file prompts/leader-portrait.txt

Output goes to stdout — one block of text, ready to paste into a trace
doc.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


DEFAULT_PROMPT = (
    "Describe what's visible in this image in 1-2 sentences as if "
    "narrating for a blind player. Focus on identity, appearance, "
    "expression, posture, and what's happening. Use plain, factual "
    "language. Avoid artistic-style commentary, color theory, or "
    "interpretation of mood beyond what a person would notice in 2 "
    "seconds of looking. If text is on screen, summarize it briefly."
)


def resolve_prompt(args: argparse.Namespace) -> str:
    if args.prompt_file:
        return Path(args.prompt_file).read_text(encoding="utf-8").strip()
    if args.prompt:
        return args.prompt
    return DEFAULT_PROMPT


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--image", required=True, type=Path,
        help="Path to the image file (.png, .jpg, .jpeg, .webp).",
    )
    parser.add_argument(
        "--prompt", default=None,
        help="Inline prompt text. Default: brief blind-first description.",
    )
    parser.add_argument(
        "--prompt-file", default=None,
        help="Read prompt from this file instead. Wins over --prompt.",
    )
    parser.add_argument(
        "--model", default="gemini-2.5-flash",
        help="Gemini model name. Default: gemini-2.5-flash.",
    )
    args = parser.parse_args()

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print(
            "ERROR: GEMINI_API_KEY not set. Set it once via PowerShell:\n"
            '  [Environment]::SetEnvironmentVariable("GEMINI_API_KEY", '
            '"your-key", "User")\n'
            "Then restart your shell.",
            file=sys.stderr,
        )
        return 2

    if not args.image.exists():
        print(f"ERROR: image not found: {args.image}", file=sys.stderr)
        return 2

    prompt = resolve_prompt(args)

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        print(
            "ERROR: google-genai package not installed. Run:\n"
            "  pip install google-genai",
            file=sys.stderr,
        )
        return 2

    client = genai.Client(api_key=api_key)

    image_bytes = args.image.read_bytes()
    suffix = args.image.suffix.lower().lstrip(".")
    mime = {
        "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "png": "image/png", "webp": "image/webp",
    }.get(suffix, "image/png")

    response = client.models.generate_content(
        model=args.model,
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type=mime),
            prompt,
        ],
    )

    text = (response.text or "").strip()
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
