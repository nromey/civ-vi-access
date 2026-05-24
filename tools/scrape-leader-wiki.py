"""Scrape leader portraits from the Civilization VI Fandom wiki.

For the ~30 playable leaders whose portraits aren't in the SDK
Assets depot (Leader Pass, New Frontier Pass, alt personas).
Each leader's wiki page has an infobox portrait image; we fetch
the page's main image via the Fandom API (cleaner than HTML
parsing) and download it.

Output: PNG files in tools/wonder-describer/images/leaders/,
named LEADER_<TYPE>.png to match the SDK-extraction convention.

The scrape is one-shot — once we have the PNGs locally, this
script is rarely re-run. If the wiki page conventions change or
new leaders are released, edit MISSING_LEADERS and re-run with
--force.

Usage:
    python tools/scrape-leader-wiki.py            # scrape all missing
    python tools/scrape-leader-wiki.py --dry-run  # show URLs, don't download
    python tools/scrape-leader-wiki.py --leader LEADER_ABRAHAM_LINCOLN
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from urllib.parse import quote

import urllib.request
import urllib.error
import json


DEFAULT_OUT = Path(
    r"C:\dev\Civ-vi-access\tools\wonder-describer\images\leaders"
)
WIKI_API = "https://civilization.fandom.com/api.php"
USER_AGENT = (
    "CivVIAccess-AssetDescriber/0.1 "
    "(+https://github.com/nromey/civ-vi-access; one-shot leader "
    "portrait scrape for blind-player accessibility mod)"
)


# Leader type → Fandom wiki page title. Manual table because page
# conventions vary; alt personas in particular use bespoke names.
# When in doubt, the rule is "leader's display name, underscores,
# (Civ6) disambig" — but check wiki to confirm if scrape 404s.
MISSING_LEADERS: dict[str, str] = {
    # Leader Pass (2022-2023) — net-new leaders
    "LEADER_ABRAHAM_LINCOLN":   "Abraham_Lincoln_(Civ6)",
    "LEADER_JULIUS_CAESAR":     "Julius_Caesar_(Civ6)",
    "LEADER_CHARLEMAGNE":       "Charlemagne_(Civ6)",
    "LEADER_NADER_SHAH":        "Nader_Shah_(Civ6)",
    "LEADER_NZINGA_MBANDE":     "Nzinga_Mbande_(Civ6)",
    "LEADER_RAMSES":            "Ramses_II_(Civ6)",
    "LEADER_AL_HAKAM_II":       "Al-Hakam_II_(Civ6)",
    "LEADER_WU_ZETIAN":         "Wu_Zetian_(Civ6)",
    "LEADER_YONGLE":            "Yongle_(Civ6)",
    "LEADER_ELIZABETH":         "Elizabeth_I_(Civ6)",
    "LEADER_TOKUGAWA":          "Tokugawa_(Civ6)",
    # New Frontier Pass (2020-2021) — individual leader DLCs
    "LEADER_HAMMURABI":         "Hammurabi_(Civ6)",
    "LEADER_AMBIORIX":          "Ambiorix_(Civ6)",
    "LEADER_BASIL_II":          "Basil_II_(Civ6)",
    "LEADER_JOAO_III":          "Jo%C3%A3o_III_(Civ6)",
    "LEADER_MENELIK":           "Menelik_II_(Civ6)",
    "LEADER_KUBLAI_KHAN_CHINA": "Kublai_Khan_(Civ6)",
    "LEADER_SIMON_BOLIVAR":     "Sim%C3%B3n_Bol%C3%ADvar_(Civ6)",
    "LEADER_LADY_SIX_SKY":      "Lady_Six_Sky_(Civ6)",
    # Persona Pack alt personas — wiki convention is /persona
    # subpages on the base leader page, not parenthesized titles.
    "LEADER_CATHERINE_DE_MEDICI_ALT":
        "Catherine_de_Medici_(Civ6)/Magnificence",
    "LEADER_CLEOPATRA_ALT":     "Cleopatra_(Civ6)/Ptolemaic",
    "LEADER_HARALD_ALT":        "Harald_Hardrada_(Civ6)/Varangian",
    "LEADER_QIN_ALT":           "Qin_Shi_Huang_(Civ6)/Unifier",
    "LEADER_SALADIN_ALT":       "Saladin_(Civ6)/Sultan",
    "LEADER_VICTORIA_ALT":      "Victoria_(Civ6)/Age_of_Steam",
    "LEADER_T_ROOSEVELT_ROUGHRIDER":
        "Teddy_Roosevelt_(Civ6)/Rough_Rider",
    # Lady Trieu uses her Vietnamese name with diacritics on wiki.
    "LEADER_LADY_TRIEU":        "B%C3%A0_Tri%E1%BB%87u_(Civ6)",
    # Vikings Scenario pack — may need verification
    "LEADER_CNUT":              "Canute_(Civ6)",
    "LEADER_OLOF":              "Olof_Sk%C3%B6tkonung_(Civ6)",
}


def fetch_image_url(page_title: str) -> str | None:
    """Find the highest-fidelity leader image on the page.

    Strategy: enumerate all images on the page via the MediaWiki
    `generator=images` API, pick the largest image whose filename
    references the leader (heuristic: shares at least one
    name-fragment with the page title). This typically lands on
    the 1920x1080 `<Leader>_loadscreen_(Civ6).png` splash art
    used on the in-game loading screen — much richer than the
    256x256 infobox icon.

    Falls back to the largest image on the page if nothing
    matches the leader-name heuristic.
    """
    params = (
        f"?action=query&format=json"
        f"&titles={page_title}"
        f"&generator=images&gimlimit=50"
        f"&prop=imageinfo&iiprop=size%7Curl"
    )
    url = WIKI_API + params
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"    HTTP {e.code} fetching {page_title}", file=sys.stderr)
        return None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        print(f"    error fetching {page_title}: {e}", file=sys.stderr)
        return None

    pages = data.get("query", {}).get("pages", {})
    if not pages:
        print(f"    page not found: {page_title}", file=sys.stderr)
        return None

    # Build name fragments from the page title for matching.
    # "Abraham_Lincoln_(Civ6)" -> {"abraham", "lincoln"}
    title_clean = page_title.lower()
    for marker in ("_(civ6)", "(civ6)", "%c3%a3", "%c3%b3"):
        title_clean = title_clean.replace(marker, "")
    name_fragments = {
        frag for frag in title_clean.replace("_", " ").split()
        if len(frag) >= 4
    }

    candidates: list[tuple[int, int, str, str, bool]] = []
    for pid, page_data in pages.items():
        if pid == "-1":
            continue
        title = page_data.get("title", "")
        title_lower = title.lower()
        matches_leader = any(frag in title_lower for frag in name_fragments)
        for ii in page_data.get("imageinfo", []):
            w, h = ii.get("width", 0), ii.get("height", 0)
            img_url = ii.get("url", "")
            if not img_url:
                continue
            candidates.append((w, h, title, img_url, matches_leader))

    if not candidates:
        print(f"    no images on page: {page_title}", file=sys.stderr)
        return None

    # Prefer leader-name-matching images; among those, pick largest.
    # If none match, fall back to largest overall.
    matching = [c for c in candidates if c[4]]
    pool = matching if matching else candidates
    pool.sort(key=lambda c: c[0] * c[1], reverse=True)
    chosen = pool[0]
    print(f"    {chosen[0]}x{chosen[1]} {chosen[2]}", file=sys.stderr)
    return chosen[3]


def download_image(url: str, dest: Path) -> bool:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"    download failed: {e}", file=sys.stderr)
        return False
    dest.write_bytes(data)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--out", default=str(DEFAULT_OUT), type=Path,
        help="Output directory (default: wonder-describer/images/leaders).",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show URLs we'd download but don't fetch.",
    )
    parser.add_argument(
        "--leader",
        help="Scrape only this leader type (e.g. LEADER_ABRAHAM_LINCOLN). "
             "Skips dedupe / existence check.",
    )
    parser.add_argument(
        "--force", action="store_true",
        help="Re-download even if the destination PNG already exists.",
    )
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)

    targets = (
        {args.leader: MISSING_LEADERS[args.leader]}
        if args.leader and args.leader in MISSING_LEADERS
        else MISSING_LEADERS
    )

    results = {"ok": 0, "skipped": 0, "failed": 0}
    for leader_type, page_title in targets.items():
        dest = args.out / f"{leader_type}.png"
        if dest.exists() and not args.force:
            print(f"{leader_type} ... skip (exists)")
            results["skipped"] += 1
            continue

        print(f"{leader_type} ... {page_title}")
        img_url = fetch_image_url(page_title)
        if not img_url:
            results["failed"] += 1
            continue

        if args.dry_run:
            print(f"    DRY: would download {img_url}")
            results["ok"] += 1
            continue

        if download_image(img_url, dest):
            size = dest.stat().st_size
            print(f"    -> {dest.name} ({size:,} bytes)")
            results["ok"] += 1
        else:
            results["failed"] += 1

        # Polite throttle — Fandom doesn't publish a rate limit but
        # half-a-second between requests is courteous.
        time.sleep(0.5)

    print(
        f"\n{results['ok']} ok, {results['skipped']} skipped, "
        f"{results['failed']} failed.",
        file=sys.stderr,
    )
    return 0 if results["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
