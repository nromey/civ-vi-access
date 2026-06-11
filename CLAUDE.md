# Civ VI Access — Claude orientation

Accessibility mod making Sid Meier's Civilization VI playable by blind /
screen-reader users. Lua mod (in `CivViAccessMod/`) + a .NET launcher
(`CivViAccess/`) that consumes the **camm** framework via the `camm/` git
submodule. MIT-licensed, `nromey/civ-vi-access`.

## Read these FIRST, every session

1. **`docs/TASK_PLAN.md`** — the current ordered plan (what to work on, in order).
2. **`docs/HANDOFF.md`** — where the last session left off (latest state, in-flight gotchas).
3. Your memory index at `~/.claude/projects/C--dev-Civ-vi-access/memory/MEMORY.md`
   — durable facts/decisions/preferences. Open the linked `[[files]]` for detail;
   don't just skim the one-line hooks.

If you're about to ask the user something, check these first — it's probably answered.

## Architecture you MUST know (don't re-litigate or miss these)

- **Capture-all input — we OWN the map keyboard.** The WorldInput context is wrapped
  via `<ReplaceUIScript>` (`Assets/UI/Replacements/WorldInputAccessWrap.lua`).
  Consuming a key in its `OnInputHandler` (return `true`) **suppresses the engine's
  InputAction** — proven. So there are **no key restrictions** and we do **not** fight
  engine bindings or the `InputSettings.json` gesture-freeze. To add a map key:
  add it to the wrap's `SCANNER_KEYS` (any-modifier) or `SCANNER_COMBOS` (exact
  key+mods), NOT to engine InputActions. This was a huge unlock; build on it.
- **Scanner + cursor live in the HexCursorAddin VM.** The scanner
  (Core/Snap/Nav/Handler + backends) sits next to the hex cursor. The WorldInput
  wrap (a *separate* VM) forwards keys cross-VM via
  `LuaEvents.CivViAccess_ScannerInput`. 4-level nav ladder on PageUp/PageDown
  (none=item, Shift=subcategory, Ctrl=category, Alt=instance).
- **The surveyor (Noel's idea — don't re-ask for it).** A radius aggregate readout:
  "Dutch soldier 9 o'clock 6 hexes, Barbarian 11 o'clock, archer 3 o'clock 3 hexes."
  Configurable center (cursor or entered x/y/radius), category filter; output as a
  spoken clock-list OR HRTF/stereo pan; tied to zoom + the direction-vocabulary
  setting. It's P1; search is grouped with it.
- **Direction vocabulary.** `Shift+D` cycles hex / compass / clock / degrees
  globally (`HexGeom.directionString`); used by scanner + cursor where-am-I.
- **camm submodule + Prism.** The launcher's guts live in `camm/` (the mod is ~glue
  on top). Prism (Tolk-alternative screen reader) is a **pinned** submodule at
  `camm/third_party/prism`, built from source. **Gotcha:** when launcher C# uses a
  new camm/Prism API, commit+push camm + bump the gitlink + push BEFORE tagging a
  release — else Release CI compiles against the old submodule and fails (`dotnet
  run` locally uses the dirty submodule and hides it).
- **Self-updater is LIVE** (camm `Updater.cs`): Firefox-style staged `.pending` swap
  on next launch; single artifact (the exe embeds the mod). Users auto-update — no
  manual installer for camm/mod changes.

## How we work

- **Noel is blind.** Claude does ALL visual/image work (sourcing, picking, verifying);
  Noel verifies text. Noel owns the screen-reader UX calls (what's spoken, how,
  order); Claude owns codegen + scaffolding from source.
- **Every new Civ VI screen starts by reading the Civ V Access analogue FIRST.**
  Source is local at `C:\dev\Civ-V-Access` (read disk, never WebFetch). RimWorld
  Access is at `C:\dev\rimworld_access`. Prism source at `C:\dev\prism`.
- **Speech is terse by default** (label + state); long descriptions on Ctrl+T.
  Long announces interrupt on fast nav, so keep default-path speech short.
- **Communication:** concise, substance over compliments, no tables/ASCII/diagrams,
  cite LOC not time. Meta-pattern naming is signal, not noise.
- **User-facing strings go in the LOC file** (`Assets/Text/en_US/CivVIAccessStrings.xml`),
  not inline English. Register via `<UpdateText>` in the modinfo.
- **Logs** are at `AppData\Local\Firaxis Games\Sid Meier's Civilization VI\Logs\`
  (NOT Documents — OneDrive). Grep them directly. Mod folder is `CivViAccessMod`.

## Memory & handoff policy (keeps MEMORY.md from constantly hitting its cap)

The index refills because two things with different growth rates share one capped
file. Keep them separate:
- **`MEMORY.md` = durable facts/decisions/preferences/gotchas only** (slow growth).
  Don't time-slice it (per-week index files orphan timeless facts from recall).
- **Session state / "what's next" lives in the repo, not memory:** `docs/HANDOFF.md`
  (overwrite each session — don't make dated copies; `git log` is the archive) and
  `docs/TASK_PLAN.md` (the ordered plan). These are auto-discoverable in the tree
  and don't compete with durable facts for index space.
- In `MEMORY.md`, handoffs collapse to **one** pointer line → `docs/HANDOFF.md`.
- At session end: update `docs/HANDOFF.md` (+ `docs/TASK_PLAN.md` if the plan moved);
  only write a NEW memory for a genuinely new durable fact.
