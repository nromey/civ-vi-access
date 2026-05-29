#!/usr/bin/env bash
# One-shot: fetch a representative real-world photo per Civ VI natural wonder
# from Wikipedia's og:image, normalize to PNG named by FeatureType.
# Image is only fed to Gemini to generate a TEXT description; not shipped.
set -u
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
OUT="images/natural-wonders"
mkdir -p "$OUT"

# FeatureType | Wikipedia article
MAP="
FEATURE_BARRIER_REEF|Great_Barrier_Reef
FEATURE_BERMUDA_TRIANGLE|Bermuda_Triangle
FEATURE_CHOCOLATEHILLS|Chocolate_Hills
FEATURE_CLIFFS_DOVER|White_Cliffs_of_Dover
FEATURE_CRATER_LAKE|Crater_Lake
FEATURE_DEAD_SEA|Dead_Sea
FEATURE_DELICATE_ARCH|Delicate_Arch
FEATURE_DEVILSTOWER|Devils_Tower
FEATURE_EVEREST|Mount_Everest
FEATURE_EYE_OF_THE_SAHARA|Richat_Structure
FEATURE_EYJAFJALLAJOKULL|Eyjafjallaj%C3%B6kull
FEATURE_FOUNTAIN_OF_YOUTH|Fountain_of_Youth
FEATURE_GALAPAGOS|Galapagos_Islands
FEATURE_GIANTS_CAUSEWAY|Giant's_Causeway
FEATURE_GOBUSTAN|Gobustan_State_Reserve
FEATURE_HA_LONG_BAY|Ha_Long_Bay
FEATURE_IKKIL|Ik_Kil
FEATURE_KILIMANJARO|Mount_Kilimanjaro
FEATURE_LAKE_RETBA|Lake_Retba
FEATURE_LYSEFJORDEN|Lysefjord
FEATURE_MATTERHORN|Matterhorn
FEATURE_PAITITI|Paititi
FEATURE_PAMUKKALE|Pamukkale
FEATURE_PANTANAL|Pantanal
FEATURE_PIOPIOTAHI|Milford_Sound
FEATURE_RORAIMA|Mount_Roraima
FEATURE_TORRES_DEL_PAINE|Torres_del_Paine
FEATURE_TSINGY|Tsingy_de_Bemaraha_Strict_Nature_Reserve
FEATURE_UBSUNUR_HOLLOW|Uvs_Nuur
FEATURE_ULURU|Uluru
FEATURE_VESUVIUS|Mount_Vesuvius
FEATURE_WHITEDESERT|White_Desert_(Egypt)
FEATURE_YOSEMITE|Yosemite_National_Park
FEATURE_ZHANGYE_DANXIA|Zhangye_National_Geopark
"

ok=0; fail=0; failed=""
while IFS='|' read -r feat art; do
  [ -z "$feat" ] && continue
  [ -f "$OUT/$feat.png" ] && { echo "SKIP  $feat (exists)"; continue; }
  sleep 1
  url="https://en.wikipedia.org/wiki/$art"
  ogimg=$(curl -s -A "$UA" "$url" | grep -oE '<meta property="og:image" content="[^"]+' | head -1 | sed 's/.*content="//')
  if [ -z "$ogimg" ]; then echo "MISS  $feat ($art): no og:image"; fail=$((fail+1)); failed="$failed $feat"; continue; fi
  curl -s -A "$UA" -o _raw.tmp "$ogimg"
  if python -c "from PIL import Image; Image.open('_raw.tmp').convert('RGB').save('$OUT/$feat.png','PNG')" 2>/dev/null; then
    dim=$(python -c "from PIL import Image; print('x'.join(map(str,Image.open('$OUT/$feat.png').size)))" 2>/dev/null)
    echo "OK    $feat -> $art ($dim)"; ok=$((ok+1))
  else
    echo "FAIL  $feat ($art): not an image"; fail=$((fail+1)); failed="$failed $feat"
  fi
  rm -f _raw.tmp
done <<< "$MAP"

echo "---"
echo "downloaded $ok, failed $fail"
[ -n "$failed" ] && echo "FAILED:$failed"
