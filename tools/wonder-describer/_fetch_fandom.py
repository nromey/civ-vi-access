#!/usr/bin/env python3
"""Fetch the representative game-art image for each Civ VI wonder / hero /
secret society from the Civilization Fandom wiki, normalize to PNG named
by the game's stable ID (the describer's filename convention).

The image is only fed to Gemini to generate a TEXT description; it is not
shipped. Mirrors _fetch_nw.sh but uses the MediaWiki pageimages API
(deterministic, redirect-resolving) instead of scraping og:image.

Usage:
    python _fetch_fandom.py wonders
    python _fetch_fandom.py heroes
    python _fetch_fandom.py secret-societies
    python _fetch_fandom.py all

Article title for each entry = "<display name> (Civ6)". Overrides below
patch the handful whose Fandom title doesn't follow that rule. Misses are
reported at the end so they can be fixed by hand (WebSearch the title,
add an override, re-run — it's incremental: existing PNGs are skipped).
"""
import io
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image

API = "https://civilization.fandom.com/api.php"
UA = "CivVIAccess-describer/1.0 (accessibility mod; contact nromey@gmail.com)"
HERE = Path(__file__).parent

# GAME_ID -> display name. Built from the game's en_US text; a couple are
# patched here (missing LOC or non-obvious Fandom title).
NAMES = json.loads((Path(__file__).parent / "_fandom_names.json").read_text(encoding="utf-8"))

# GAME_ID -> explicit Fandom article title, when "<name> (Civ6)" is wrong.
TITLE_OVERRIDES = {
    "HEROCLASS_HUNAHPU": "Hunahpu (Civ6)",
}

CATEGORIES = {
    "wonders": ("world-wonders", "wonders"),
    "heroes": ("heroes", "heroes"),
    "secret-societies": ("secret-societies", "secret_societies"),
}


def article_title(game_id: str, name: str) -> str:
    if game_id in TITLE_OVERRIDES:
        return TITLE_OVERRIDES[game_id]
    return f"{name} (Civ6)"


def fetch_page_image(title: str) -> str | None:
    """Return the URL of the page's representative image, or None."""
    params = {
        "action": "query",
        "format": "json",
        "prop": "pageimages",
        "piprop": "original|thumbnail",
        "pithumbsize": "1000",
        "redirects": "1",
        "titles": title,
    }
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    pages = data.get("query", {}).get("pages", {})
    for _, page in pages.items():
        if "missing" in page:
            return None
        orig = page.get("original", {}).get("source")
        thumb = page.get("thumbnail", {}).get("source")
        return thumb or orig
    return None


def download_png(img_url: str, dest: Path) -> bool:
    req = urllib.request.Request(img_url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
    if len(raw) < 5000:  # likely an error page, not real art
        return False
    Image.open(io.BytesIO(raw)).convert("RGB").save(dest, "PNG")
    return True


def run(category: str) -> None:
    subdir, names_key = CATEGORIES[category]
    out = HERE / "images" / subdir
    out.mkdir(parents=True, exist_ok=True)
    entries = NAMES[names_key]
    ok, skip, miss = 0, 0, []
    for game_id, name in entries.items():
        dest = out / f"{game_id}.png"
        if dest.exists():
            print(f"SKIP  {game_id} (exists)")
            skip += 1
            continue
        title = article_title(game_id, name)
        time.sleep(1)
        try:
            img_url = fetch_page_image(title)
        except Exception as e:
            print(f"ERR   {game_id} ({title}): {e}")
            miss.append(game_id)
            continue
        if not img_url:
            print(f"MISS  {game_id}: no page/image for '{title}'")
            miss.append(game_id)
            continue
        try:
            if download_png(img_url, dest):
                dim = "x".join(map(str, Image.open(dest).size))
                print(f"OK    {game_id} <- {title} ({dim})")
                ok += 1
            else:
                print(f"FAIL  {game_id} ({title}): image too small / not an image")
                miss.append(game_id)
        except Exception as e:
            print(f"ERR   {game_id} dl ({title}): {e}")
            miss.append(game_id)
    print(f"--- {category}: {ok} downloaded, {skip} skipped, {len(miss)} failed")
    if miss:
        print("FAILED:", " ".join(miss))


if __name__ == "__main__":
    cats = sys.argv[1:] or ["all"]
    if cats == ["all"]:
        cats = list(CATEGORIES)
    for c in cats:
        if c not in CATEGORIES:
            print(f"unknown category: {c}; choose from {list(CATEGORIES)} or 'all'")
            continue
        print(f"=== {c} ===")
        run(c)
