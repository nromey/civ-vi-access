"""Enumerate canonical playable major-civ leader types across Civ VI.

Scans every `*_Leaders.xml` under the Civ VI install plus the base
`Leaders.xml`, extracts `Type="LEADER_*" Kind="KIND_LEADER"` rows,
deduplicates, filters out non-playable templates / personalities /
minor civs / barbarians / scenario placeholders, and prints the
sorted playable leader list to stdout.

The output is the canonical filename basis for the describer batch:
each leader type X yields `<X>.dds` in the SDK Assets depot and
`LOC_CIVVIACCESS_LDR_<X>_SHORT/_LONG` in the generated LOC XML.

Usage:
    python tools/enumerate-leaders.py
    python tools/enumerate-leaders.py --json > leaders.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


CIV_VI = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common"
    r"\Sid Meier's Civilization VI"
)

LEADER_PATTERN = re.compile(
    r'Type="(LEADER_[A-Z][A-Z0-9_]*)"\s+Kind="KIND_LEADER"'
)


def is_minor_civ(leader: str) -> bool:
    return leader.startswith("LEADER_MINOR_CIV_")


def is_barbarian(leader: str) -> bool:
    return leader in {
        "LEADER_BARBARIAN",
        "LEADER_BARBARIAN_CLAN_DEFAULT",
    } or leader.startswith("LEADER_BARBARIAN_CLAN_")


def is_default_or_template(leader: str) -> bool:
    return leader in {
        "LEADER_DEFAULT",
        "LEADER_MAJOR_CIV",
        "LEADER_EXPANSIONIST",
        "LEADER_NONRELIGIOUS_MAJOR_CIV",
        "LEADER_RELIGIOUS_MAJOR_CIV",
        "LEADER_CULTURAL_MAJOR_CIV",
        "LEADER_SCIENCE_MAJOR_CIV",
    }


def is_scenario_only(leader: str) -> bool:
    # Scenario-exclusive leaders aren't available in regular play.
    scenario_markers = (
        "_SCENARIO_",
        "_BLACK_DEATH",
        "_CIVROYALE",
        "_PIRATES",
        "_VIKINGS",
        "_AUSTRALIA_BOMB",
    )
    if any(marker in leader for marker in scenario_markers):
        return True
    # AustraliaScenario gave sub-faction "leaders" without _SCENARIO_ in
    # the name; Free Cities is a R&F mechanic faction, not a leader;
    # Polish scenario nobles (Ostrogski / Radziwill / Potocki) likewise.
    extras = {
        "LEADER_QUEENSLAND",
        "LEADER_WESTERN_AUSTRALIA",
        "LEADER_SOUTH_AUSTRALIA",
        "LEADER_FREE_CITIES",
        "LEADER_OSTROGSKI",
        "LEADER_RADZIWILL",
        "LEADER_POTOCKI",
        # Personality variants that share a leader portrait with the
        # base persona — Teddy Roosevelt Rough Rider uses the same
        # portrait as Teddy with different ability text. We'll wire
        # the LOC keys to share the base persona's image.
        "LEADER_T_ROOSEVELT_ROUGHRIDER",
    }
    return leader in extras


def is_agenda_or_trait(leader: str) -> bool:
    # Some "LEADER_*" rows in DB are actually agenda / trait identifiers
    # piggybacking on the namespace. Heuristic: short tokens are leaders;
    # tokens with verb-like fragments are agendas.
    agenda_fragments = (
        "_ADVENTURES_",
        "_KILLER_OF_",
        "_MAGNANIMOUS",
        "_SURROUNDED_BY_",
        "_AGGRESSIVE_",
        "_LOW_RELIGIOUS_",
        "_LOW_CITY_STATE_",
        "_GIFTS_FOR_",
        "_GRAND_EMBASSY",
        "_HOLY_ROMAN_EMPEROR",
        "_PAX_BRITANNICA",
        "_RIGHTEOUSNESS_OF_FAITH",
        "_RELIGIOUS_CONVERT",
        "_ROOSEVELT_COROLLARY",
        "_SATYAGRAHA",
        "_KILLER_OF_CYRUS",
        "_DIVINE_WIND",
        "_EL_ESCORIAL",
        "_MEDITERRANEAN",
        "_UNIT_",
        "_MELEE_COASTAL_RAIDS",
    )
    return any(fragment in leader for fragment in agenda_fragments)


def is_playable(leader: str) -> bool:
    if is_minor_civ(leader):
        return False
    if is_barbarian(leader):
        return False
    if is_default_or_template(leader):
        return False
    if is_scenario_only(leader):
        return False
    if is_agenda_or_trait(leader):
        return False
    return True


def collect_leader_files(root: Path) -> list[Path]:
    files: list[Path] = []
    base = root / "Base" / "Assets" / "Gameplay" / "Data" / "Leaders.xml"
    if base.is_file():
        files.append(base)
    dlc = root / "DLC"
    if dlc.is_dir():
        for entry in dlc.rglob("*_Leaders*.xml"):
            # Skip audio SFX and icon XMLs; only the data definitions
            # use the Type=/Kind= row schema.
            if "audio" in entry.as_posix().lower():
                continue
            if "Icons" in entry.name:
                continue
            files.append(entry)
    return files


def extract_leaders(path: Path) -> set[str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return set()
    return set(LEADER_PATTERN.findall(text))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--json", action="store_true",
        help="Emit JSON {playable: [...], filtered_out: [...]} instead "
             "of a sorted plaintext list.",
    )
    parser.add_argument(
        "--root", default=str(CIV_VI), type=Path,
        help="Civ VI install root (default: standard Steam location).",
    )
    args = parser.parse_args()

    files = collect_leader_files(args.root)
    if not files:
        print(f"ERROR: no Leaders.xml files under {args.root}", file=sys.stderr)
        return 2

    all_leaders: set[str] = set()
    for path in files:
        all_leaders |= extract_leaders(path)

    playable = sorted(L for L in all_leaders if is_playable(L))
    filtered = sorted(all_leaders - set(playable))

    if args.json:
        json.dump(
            {"playable": playable, "filtered_out": filtered},
            sys.stdout, indent=2,
        )
        sys.stdout.write("\n")
    else:
        for leader in playable:
            print(leader)
        print(
            f"\n# {len(playable)} playable leader types across "
            f"{len(files)} XML files. {len(filtered)} non-playable "
            f"entries filtered out (minor civs, barbarians, scenarios, "
            f"agendas, templates).",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
