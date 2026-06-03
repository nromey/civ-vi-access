# Accessible Civilopedia — plan + engine data map

Status 2026-06-03: **deferred to a focused build** (not shipped this batch). The
data map below is confirmed from engine source recon so the build can go fast and
testable next session. Deferred deliberately: a full HTML pedia is only as good
as the per-entry text assembly (intricate chapter/LOC keys); building it blind
risks mostly-empty pages. The most acute pedia need — "what unlocks this
improvement and where" — is already partly met inline by the Build picker v2
(it speaks each locked improvement's PrereqTech / PrereqCivic / valid terrain).

## Design (locked with Noel)

- **F1** = full pedia: table of contents (really an index) + search. Search is
  browser-native (Ctrl+F in the Edge report window) — no need to build our own.
- **Shift+I** = context deep-link: from any picker / focused object, open that
  object's pedia entry directly.
- Rendered as HTML to a file and opened via the **Edge report bridge** (already
  validated — same path as U / N reports).
- Civ V parity: surface "more info / pedia available" cues on items that have a
  pedia context (later polish).

## Engine data map (recon 2026-06-03)

Files: `Base/Assets/UI/Civilopedia/CivilopediaScreen.lua`,
`CivilopediaSupport.lua` (~1795 lines, the core), `Civilopedia.xml` (DB schema),
and 21 `CivilopediaPage_*.lua` layout handlers (one per content type).

**All content assembles from `GameInfo.*` tables + `Locale.Lookup` — no
Civilopedia UI needs to be open.** This is the key enabler: we can build the
whole thing from data in any context.

Table of contents / enumeration:
- `GameInfo.CivilopediaSections()` — root sections (CONCEPTS, CIVILIZATIONS,
  LEADERS, UNITS, TECHNOLOGIES, CIVICS, BUILDINGS, WONDERS, IMPROVEMENTS,
  RESOURCES, FEATURES, DISTRICTS, GOVERNMENTS, RELIGIONS, GREATPEOPLE,
  UNITPROMOTIONS, CITYSTATES). Cols: SectionId, Name (LOC), Icon, SortIndex.
- `GameInfo.CivilopediaPages()` — static pages (section intros, CONCEPTS theory).
- `GameInfo.CivilopediaPageGroups()` — collapsible headers per section.
- `GameInfo.CivilopediaPageQueries()` — **SQL that generates pages from game
  objects**, e.g. `SELECT TechnologyType as PageId, EraType as PageGroupId,
  "Technology" as PageLayoutId, Name ... FROM Technologies`. One page per row.
- `GameInfo.CivilopediaPageGroupQueries()` — SQL that populates groups.

Lookup (deep-link): the game-object **type string IS the PageId**. e.g.
`UNIT_WARRIOR` → SectionId UNITS / PageId UNIT_WARRIOR / PageLayoutId Unit;
`TECH_POTTERY` → TECHNOLOGIES / TECH_POTTERY / Technology;
`IMPROVEMENT_FARM` → IMPROVEMENTS / IMPROVEMENT_FARM / Improvement.
So a picker stores `(SectionId, PageId)` and deep-links straight to it.

Per-entry text:
- Title: page Name LOC key.
- Body: chapter system — `LOC_PEDIA_<SectionId>_PAGE_<PageId>_CHAPTER_<ChapterId>_BODY`
  (and `..._PARA_1/2/...`), with `CivilopediaPageChapterHeaders` /
  `CivilopediaPageChapterParagraphs` for static defs. Text-key fallback chain:
  `LOC_PEDIA_<Section>_PAGE_<PageId>_<Tag>` → `LOC_PEDIA_PAGE_<PageId>_<TAG>` →
  `LOC_PEDIA_PAGE_<TAG>` → custom `TextKeyPrefix`.
- Stats: direct from `GameInfo.Units/Buildings/Technologies/...` columns +
  related-data queries (UnitUpgrades, BuildingPrereqs, Modifiers, etc.).
- Caveat: a little is player-specific/live (IsTechRevealed, unique-unit upgrade
  filtering) and only computed at render. Static data (descriptions, stats,
  prereqs, names) is always available.

## Build approach (next session)

1. F1 handler (HexCursorAddin or a new addin) → build HTML string:
   for each section → group → entry (from the PageQueries SQL or by iterating the
   matching GameInfo table) → name + assembled chapter body + key stats.
2. Write HTML to `%LocalAppData%\CivVIAccess\pedia.html`, open via the existing
   ReportWindow/Edge bridge (reuse Report.lua path).
3. Shift+I deep-link: map the focused object's type → (SectionId, PageId), jump
   to an anchor in the same HTML (`#SECTION_PAGEID`).
4. Test against a live game; verify chapter text isn't sparse for common types
   (units, techs, civics, improvements) before widening to all 17 sections.
