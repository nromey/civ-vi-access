# wonder-describer

Batch image-describer for Civ VI Access. Runs a folder of game-art images
through Gemini and produces two-tier visual descriptions (short sentence
+ long paragraph). Output is a Civ VI LOC XML file the mod's existing
text-loading machinery picks up — so descriptions become
`Locale.Lookup`-able strings, translatable on the same footing as any
other game text.

The tool is generic: one prompt file per asset category, one LOC prefix
per category. Each category is a separate run, separate output XML,
separate translation surface.

## Setup

```
pip install -r requirements.txt
export GEMINI_API_KEY=...
```

`GEMINI_API_KEY` lives in your local shell only. Don't put it in
GitHub Actions — the pipeline is local-only and one-way: you generate
the XML, you commit the XML, the mod ships the XML. CI never calls
Gemini.

## Per-category usage

Each category has its own prompt file (`prompts/`) and its own LOC
prefix. Suggested mapping:

| Category         | Prompt file                  | LOC prefix              |
|------------------|------------------------------|-------------------------|
| Natural wonders  | `prompts/natural-wonders.txt`| `LOC_CIVVIACCESS_NW`    |
| World wonders    | `prompts/world-wonders.txt`  | `LOC_CIVVIACCESS_WW`    |
| Leaders          | `prompts/leaders.txt`        | `LOC_CIVVIACCESS_LDR`   |
| Units            | `prompts/units.txt`          | `LOC_CIVVIACCESS_UNIT`  |
| Buildings        | `prompts/buildings.txt`      | `LOC_CIVVIACCESS_BLDG`  |
| Civilizations    | `prompts/civilizations.txt`  | `LOC_CIVVIACCESS_CIV`   |

Image filename convention: each file's stem becomes the LOC tag
suffix. Use the game's stable IDs:

- `FEATURE_BERMUDA_TRIANGLE.png` → `LOC_CIVVIACCESS_NW_FEATURE_BERMUDA_TRIANGLE_SHORT/_LONG`
- `LEADER_TRAJAN.png` → `LOC_CIVVIACCESS_LDR_LEADER_TRAJAN_SHORT/_LONG`
- etc.

### Example — natural wonders, starter batch

```
python describe.py \
    --images images/natural-wonders/ \
    --prompt prompts/natural-wonders.txt \
    --output-json output/natural-wonders.json \
    --output-xml  ../../CivViAccessMod/Assets/Text/en_US/NaturalWonderDescriptions.xml \
    --loc-prefix LOC_CIVVIACCESS_NW \
    --limit 5
```

### Iterating the prompt (no JSON/XML touched)

Before committing to a batch, tune the prompt against one image:

```
python describe.py \
    --images images/natural-wonders/ \
    --prompt prompts/natural-wonders.txt \
    --loc-prefix LOC_CIVVIACCESS_NW \
    --limit 1 \
    --dry-run
```

`--dry-run` prints the model output to stdout and **does not write
JSON or XML**. `--output-json` and `--output-xml` are optional in
dry-run mode. Re-run as you tweak the prompt; only do a real run
once you're happy with the prose.

## Other CLI flags

- `--limit N` — describe at most N new images this run. Use for
  starter batches.
- `--force` — re-describe entries that are already in the JSON.
- `--model gemini-2.5-flash` — override the model id.

## Output

- **JSON** (`output/<name>.json`) is the canonical store. Diff-friendly,
  easy to hand-edit, easy to re-run incrementally. Commit this.
- **XML** (`Assets/Text/<lang>/<name>.xml`) is the mod-shipping artifact.
  Two LOC rows per image: `<prefix>_<stem>_SHORT` and
  `<prefix>_<stem>_LONG`. Generated from JSON; **do not edit by hand**
  in the source language — translation files (other locales) are
  hand-edited following the existing `CivVIAccessStrings.xml`
  convention.

## Wiring on the mod side

After generating the first XML file for a category, register it once
in `CivViAccessMod.modinfo` under the `<UpdateText>` blocks (FrontEnd
and InGame, as needed):

```xml
<UpdateText id="SRAccess_FE_Text">
    <File>Assets/Text/en_US/CivVIAccessStrings.xml</File>
    <File>Assets/Text/en_US/NaturalWonderDescriptions.xml</File>
</UpdateText>
```

Then the consuming companion calls
`Locale.Lookup("LOC_CIVVIACCESS_NW_" .. featureValue .. "_SHORT")` /
`_LONG` at speech time.

## Adding a new category

1. Write a `prompts/<category>.txt` (copy one of the existing files and
   tune the category-specific guidance).
2. Pick a LOC prefix that namespaces it (`LOC_CIVVIACCESS_<CATEGORY>`).
3. Run with `--dry-run --limit 1` against one image to verify the
   prompt.
4. Real run with `--limit 5` for a starter batch, then full run.
5. Add the XML file to `<UpdateText>` in `CivViAccessMod.modinfo`.
6. Wire whichever companion consumes the category to `Locale.Lookup`
   the keys.

## Tier-4 (terrain / icon-level) art — deferred

The 3-or-4-word visual descriptors for terrain tiles, resource icons,
and similar low-detail symbols don't fit the `{short, long}` schema
cleanly. When that becomes the active surface, add a single-tier
prompt + a `--single-tier` flag (emits one LOC row per stem, no
SHORT/LONG split). Not built yet.
