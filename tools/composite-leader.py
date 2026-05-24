"""Composite a Civ VI leader NEUTRAL portrait onto its BACKGROUND scene.

The SDK Assets ship leader portraits as a transparent cutout
(`LEADER_X_NEUTRAL.dds`, RGBA with variable alpha) and a separate
scenery panel (`LEADER_X_BACKGROUND.dds`, 1920x960). The game UI
composites the cutout bottom-anchored over the scenery to produce
the leader placard a sighted player sees on the AdvancedSetup
screen and during diplomacy.

For the Gemini describer to see what the player sees, we need
to do the same composite before sending to the API. The result
PNG is a 1920x960 image: scenery as base, leader scaled to the
background height and positioned bottom-center.

Usage:
    python tools/composite-leader.py LEADER_GANDHI
    python tools/composite-leader.py --all
    python tools/composite-leader.py --all --output-dir other/path
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image


SDK_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common"
    r"\Sid Meier's Civilization VI SDK Assets"
)
TEX_DIRS = [
    SDK_ROOT / "Civ6" / "pantry" / "Textures",
    SDK_ROOT / "Civ6" / "DLC" / "Expansion1" / "pantry" / "Textures",
    SDK_ROOT / "Civ6" / "DLC" / "Expansion2" / "pantry" / "Textures",
    SDK_ROOT / "Civ6" / "DLC" / "Shared" / "pantry" / "Textures",
]
DEFAULT_OUTPUT = Path(
    r"C:\dev\Civ-vi-access\tools\wonder-describer\images\leaders"
)


def find_texture(name: str) -> Path | None:
    for tex_dir in TEX_DIRS:
        candidate = tex_dir / name
        if candidate.is_file():
            return candidate
    return None


def composite_leader(leader_id: str, out_dir: Path) -> Path | None:
    """leader_id is the filename stem like 'LEADER_GANDHI' (no _NEUTRAL).

    Returns the path written, or None if assets weren't found.
    """
    neutral = find_texture(f"{leader_id}_NEUTRAL.dds")
    background = find_texture(f"{leader_id}_BACKGROUND.dds")
    if neutral is None:
        print(f"  no NEUTRAL for {leader_id}", file=sys.stderr)
        return None

    n_img = Image.open(neutral).convert("RGBA")
    if background is None:
        # No background scenery — just save the portrait as-is.
        # (Some scenario / minor-civ leaders ship without a placard
        # scene.)
        out = out_dir / f"{leader_id}.png"
        n_img.save(out, "PNG")
        return out

    b_img = Image.open(background).convert("RGBA")

    # Scale the cutout to fit the background height, keeping aspect.
    bg_w, bg_h = b_img.size
    n_w, n_h = n_img.size
    scale = bg_h / n_h
    new_w = int(round(n_w * scale))
    new_h = bg_h
    n_scaled = n_img.resize((new_w, new_h), Image.LANCZOS)

    # Bottom-center the cutout over the background — matches the
    # game's LeaderImage Anchor="C,B" StretchMode="UniformToFill"
    # placement on the LeaderPlacard.
    paste_x = (bg_w - new_w) // 2
    paste_y = bg_h - new_h  # 0 if same height; positive if shorter
    composite = b_img.copy()
    composite.alpha_composite(n_scaled, dest=(paste_x, paste_y))

    # Save as RGB JPG-ish flatten? PNG keeps alpha; Gemini doesn't
    # care, but PNG with alpha = 4 channels is fine.
    out = out_dir / f"{leader_id}.png"
    composite.save(out, "PNG")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "leader_id", nargs="?",
        help="Single leader to composite, e.g. LEADER_GANDHI. With --all, "
             "this is ignored.",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Composite every LEADER_*_NEUTRAL.dds found across the SDK "
             "Assets tree. Skips minor civs / barbarians / scenarios via "
             "name filter.",
    )
    parser.add_argument(
        "--output-dir", default=str(DEFAULT_OUTPUT), type=Path,
        help="Where to write composites. Default: "
             "tools/wonder-describer/images/leaders/",
    )
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    if args.all:
        seen: set[str] = set()
        for tex_dir in TEX_DIRS:
            if not tex_dir.is_dir():
                continue
            for path in tex_dir.glob("LEADER_*_NEUTRAL.dds"):
                leader_id = path.stem[: -len("_NEUTRAL")]
                if leader_id in seen:
                    continue
                # Filter out the obvious non-playable variants;
                # match the same exclusions as enumerate-leaders.py.
                if any(marker in leader_id for marker in (
                    "_DEFAULT",
                    "_MINOR_CIV_",
                    "_BARBARIAN",
                    "_CIVROYALE_",
                    "_SCENARIO",
                )):
                    continue
                seen.add(leader_id)
                out = composite_leader(leader_id, args.output_dir)
                if out is not None:
                    print(f"  {leader_id} -> {out.name}")
        print(f"\n{len(seen)} leaders composited.")
        return 0

    if not args.leader_id:
        print("ERROR: specify a leader_id or --all", file=sys.stderr)
        return 2

    out = composite_leader(args.leader_id, args.output_dir)
    if out is None:
        return 1
    print(f"{args.leader_id} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
