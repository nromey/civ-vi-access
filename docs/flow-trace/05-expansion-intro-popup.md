# 05 — Expansion intro popup (R&F + GS welcome modals)

The "Welcome to Rise and Fall" / "Welcome to Gathering Storm"
slideshow that appears on the first turn of a game played with
the matching ruleset, the first time the player loads it. Nine
pages for R&F, twelve for GS, each with an illustration +
description + optional details paragraph. Has Next / Previous
nav, a Close button, and a "Don't show again" checkbox.

This is one of the modal blockers that made any blind player
stuck before reaching the world ([[project-first-turn-popups-block-input]]).
Today: mouse-only, no keyboard nav between buttons (Esc works
for dismiss), no screen-reader output.

**Vanilla rulesets**: this waypoint does not exist. Skip
straight to waypoint 06 (first-turn advisor) for Vanilla.

## Engine source

- R&F: `DLC/Expansion1/UI/Additions/ExpansionIntro.lua` (178
  lines) + `.xml`
- GS: `DLC/Expansion2/UI/Additions/ExpansionIntro.lua` (187
  lines) + `.xml`
- Same scaffold, different content tables. Files are 95%
  identical Lua code; only the diagram list, description LOC
  keys, ruleset constant, and Options key differ.

## How it opens

Both files use the same trigger:

- Hook: `Events.LoadGameViewStateDone` (the loading screen has
  finished, world is loaded but advisor popups haven't yet
  fired)
- Show conditions (`OnLoadGameViewStateDone` line 114 R&F / 123 GS):
  - `GameConfiguration.GetRuleSet() == RULESET_TYPE` (R&F or
    GS matching the file)
  - Not multiplayer
  - Not autoplay
  - Either not-already-seen (`HasSeenXP1FeaturesScreen` /
    `HasSeenXP2FeaturesScreen` user option == 0) OR tutorial
    level is novice
  - `HideXP1FeaturesScreen` / `HideXP2FeaturesScreen` user
    option is unchecked
  - It's the first turn (`Game.GetCurrentGameTurn() ==
    GameConfiguration.GetStartTurn()`)
- If conditions match: sets the seen flag, saves options,
  calls `OnShow` which queues the popup at
  `PopupPriority.TutorialHigh`
- Can also be reopened later via
  `LuaEvents.InGameTopOptionsMenu_ShowExpansionIntro` (from the
  in-game pause menu)

## What appears visually

A modal popup with these elements (same XML layout for both
expansions, just content differs):

- **Illustration** (`Controls.Illustration`) — large image,
  one per page (~9 for R&F, ~12 for GS). Textures named
  `XP1Intro_Diagram_N` / `XP2Intro_Diagram_N`
- **Description** label — main text for the page
- **FrameDeco + Description2** — optional second paragraph
  (details), hidden when empty
- **Previous button** — hidden on page 1
- **Next button** — text reads "NEXT" except on last page where
  it's "CONTINUE"
- **Close button** — X in corner, dismisses anytime
- **"Don't show again" checkbox** (`Controls.DontShowAgain`)
  bound to the `HideXP*FeaturesScreen` option

## What it accepts as input

- Mouse: click Previous / Next / Close / DontShowAgain
- Keyboard: **Esc only** (calls `HideIfVisible` → `OnClose`).
  No Tab / arrow / Enter handlers in the base code. The popup
  consumes all input (`return true` at end of `OnInput` line
  140 / 149) so nothing else is reachable while it's open.

## How it closes / advances

- Next on last page → `OnClose` → `UIManager:DequeuePopup`
- Close button → `OnClose`
- Esc → `OnInput` → `HideIfVisible` → `OnClose`
- `LuaEvents.DiplomacyActionView_HideIngameUI` → `HideIfVisible`
  (in case diplomacy steals focus)

**Earcons on close + page nav** (Noel 2026-05-22):
- "Ready" chime (pages turning, per flow 04) on popup close —
  signals "world is reachable now"
- **Book flip earcon (forward)** on Next button / Right arrow
- **Book flip earcon (reverse)** on Previous button / Left arrow
- Both new additions to the ElevenLabs earcon list — see
  Implementation notes.

On dismiss, control returns to the world (or to the first-turn
advisor popup, waypoint 06).

## Ruleset variants

| Aspect | Vanilla | R&F | GS |
|--------|---------|-----|-----|
| Popup exists? | **No** | Yes (9 pages) | Yes (12 pages) |
| Topics covered | n/a | Eras, Ages, Loyalty, Governors, Alliances, Emergencies, City Banner | World Congress, Favor, Diplomatic Victory, Grievances, Environment, Volcanoes, Geothermal, Strategic Resources, Resources, plus the R&F topics implicitly |
| Illustrations | n/a | `XP1Intro_Diagram_1`..9 | `XP2Intro_Diagram_1`..3, 11..12, 4..10 (note Firaxis-reshuffled order) |
| Seen-flag option | n/a | `HasSeenXP1FeaturesScreen` | `HasSeenXP2FeaturesScreen` |
| Hide-forever option | n/a | `HideXP1FeaturesScreen` | `HideXP2FeaturesScreen` |
| Trigger ruleset | n/a | `RULESET_EXPANSION_1` | `RULESET_EXPANSION_2` |
| Description LOC prefix | n/a | `LOC_TUTORIAL_XP1_INTRO_*` | `LOC_TUTORIAL_XP2_INTRO_*` |

**Implementation impact**: two parallel access files (one per
expansion) since Firaxis ships two parallel companions. Both
files share 95% of structure — a shared library file
(`ExpansionIntroAccessShared.lua`) can hold the BaseMenu wrap;
each expansion file just supplies the page list + ruleset
constant. Vanilla: no access file needed (the popup is never
loaded so there's nothing to wrap).

## Current accessibility state

**Mouse-only.** Esc dismisses but nothing else is reachable
from the keyboard:
- Previous / Next buttons are mouse-click only
- "Don't show again" checkbox is mouse-click only
- Close button is mouse-click only
- No focus tracking, no spoken page content, no announcement
  on page change

For a blind player on R&F or GS: they hear nothing when the
popup opens, can press Esc to dismiss, and lose all 9-12 pages
of tutorial content. Worse — many blind players won't know
they're stuck in a popup at all until they happen to press Esc.

## Blind-first design

The brief: **make this a full accessible mini-tutorial.** Not
just dismissible — actually let the player work through the
pages and toggle the "don't show again" preference. This is
the first place the user encounters a multi-page screen-reader
slideshow; setting the pattern right matters for downstream
tutorial work.

**On show**:
- Announce: "Welcome to Rise and Fall." (or "Welcome to
  Gathering Storm.")
- Then: "Page 1 of 9. <Page title>." (e.g., "Page 1 of 9.
  Welcome.")
- Speak the page Description
- If page has Details, speak them after
- Speak nav hint: "Press Right or N for next page, Left or P
  for previous, Ctrl+I for illustration description, T to
  toggle 'Don't show again', Enter to close, Escape to close."

**On page change** (Next/Previous or arrow keys):
- "Page N of M. <Page title>." + Description + Details

**Hotkeys** (active while popup is open):
- `Right arrow` / `N` → next page (engine `OnNext`)
- `Left arrow` / `P` → previous page (engine `OnPrevious`)
- `Ctrl+I` → speak the illustration description (from a
  describer pass over `XP1Intro_Diagram_*` and
  `XP2Intro_Diagram_*` .dds files) + copy to clipboard
- `Ctrl+T` → re-speak the current page's description + details
- `T` → toggle "Don't show again" (announce new state:
  "Don't show again, on" / "Don't show again, off")
- `Enter` / `Esc` → close

**Image source for the describer** (probed 2026-05-22 in
response to Noel's question): yes, all 21 diagrams are
available as loose .dds in the **Civ VI SDK Assets** depot
(Steam: "Sid Meier's Civilization VI SDK Assets"):

- **XP1 (R&F)** — 9 diagrams + 1 logo + 1 window frame in
  `Civ6/DLC/Shared/pantry/Textures/XP1Intro_Diagram_1.dds`
  through `_9.dds`, plus `XP1Intro_Logo.dds` and
  `XP1Intro_Window.dds`.
- **XP2 (GS)** — 12 diagrams + 1 logo in
  `Civ6/DLC/Expansion2/pantry/Textures/XP2Intro_Diagram_1.dds`
  through `_12.dds`, plus `XP2Intro_Logo.dds`.
- All diagram files are ~1.4 MB each at 2048×1024 (typical
  .dds sizing for the diagram count).

Extract path: convert each `.dds` to `.png` (via `imagemagick`
or `Texconv`), drop into `tools/wonder-describer/images/
intro-diagrams/`, run the batch describer with the new prompt.

**Describer prompt** (NEW, created 2026-05-22):
`tools/wonder-describer/prompts/intro-diagrams.txt`. Modeled on
`prompts/leaders.txt`. Key differences: prompt instructs Gemini
to treat these as infographic-style teaching illustrations
(not portraits), to focus on visible composition / spatial
relationships / labels / arrows / iconography, and to NOT
restate the mechanic — the popup text already explains it,
the describer job is the picture only.

**"Don't show again" UX**: speak the current state when the
popup first opens ("Don't show again is currently off — press
T to toggle"). Per
[[project-rich-text-clipboard-pattern]] this is a real
interface element, not a hidden setting.

**Page-change announce** is verbose by design — this is a
tutorial, the user wants the content. Different from
[[feedback-terse-announce-default]] which targets fast nav;
here the user is reading, not scanning.

## Implementation notes

**Files**: two access files, one per expansion, plus a shared
helper if the deduplication pays off:

- `CivViAccessMod/Assets/UI/Accessibility/ExpansionIntroAccessShared.lua`
  — `wrap(ruleset, pages)` factory that takes the ruleset
  constant + page table and returns a BaseMenu-bound popup
  handler
- `CivViAccessMod/Assets/UI/Additions/Expansion1/ExpansionIntroAccess.lua`
  — calls the shared factory with R&F's 9-page table
- `CivViAccessMod/Assets/UI/Additions/Expansion2/ExpansionIntroAccess.lua`
  — calls the shared factory with GS's 12-page table

Pages are read from the existing `INTRO_DESCRIPTIONS` /
`INTRO_DESCRIPTIONS_DETAILS` tables that the base Lua files
already define — we just iterate the same list.

**Modinfo**: register the two access files as InGameUIAddins
gated to the matching expansion's load order. Each expansion's
modinfo dependency declaration handles the ruleset gating
automatically.

**LOC strings to add** (mod-local):
- `LOC_CIVVIACCESS_EXPANSION_INTRO_WELCOME_RF` —
  "Welcome to Rise and Fall."
- `LOC_CIVVIACCESS_EXPANSION_INTRO_WELCOME_GS` —
  "Welcome to Gathering Storm."
- `LOC_CIVVIACCESS_EXPANSION_INTRO_PAGE_FORMAT` —
  "Page {1_N} of {2_M}. {3_Title}."
- `LOC_CIVVIACCESS_EXPANSION_INTRO_NAV_HINT` —
  "Press Right or N for next page, Left or P for previous,
  Ctrl+I for illustration, T to toggle 'Don't show again',
  Enter or Escape to close."
- `LOC_CIVVIACCESS_DONT_SHOW_AGAIN_ON` —
  "Don't show again, on."
- `LOC_CIVVIACCESS_DONT_SHOW_AGAIN_OFF` —
  "Don't show again, off."

**Page titles**: the existing description LOC keys
(`LOC_TUTORIAL_XP1_INTRO_WELCOME` etc.) ARE the page titles in
their first sentence. Use the LOC key suffix as the
announced title fallback if a richer header isn't extracted —
e.g., strip `LOC_TUTORIAL_XP1_INTRO_` prefix and title-case
the rest.

**Illustration describer batch** (assets located; prompt
written; ready to run):
- 9 R&F diagrams + 12 GS diagrams = 21 illustrations
- Source: SDK Assets depot, see "Image source for the
  describer" under "What it accepts as input" above
- Convert .dds → .png and drop in
  `tools/wonder-describer/images/intro-diagrams/`
- Prompt: `tools/wonder-describer/prompts/intro-diagrams.txt`
  (created 2026-05-22 — modeled on `leaders.txt`, tuned for
  info-graphic teaching illustrations)
- Same batch describe.py pipeline as leaders
- Output LOC keys: `LOC_CIVVIACCESS_XPINTRO_<DIAGRAM>_SHORT/_LONG`
  written to `CivViAccessMod/Assets/Text/en_US/IntroDiagramDescriptions.xml`
- Cost estimate: 21 images × ~$0.05 per Gemini Pro call ≈ $1
  for the batch
- Spot-check: run pages 1, 4, 9 of XP1 first; verify quality;
  trust the rest if the first three are good

**Earcons referenced** (Noel generating via ElevenLabs — see
[[project_elevenlabs_earcons]]):
- `book_flip_forward.wav` — page-turn forward sound, fires on
  Next / Right arrow
- `book_flip_reverse.wav` — page-turn reverse sound, fires on
  Previous / Left arrow
- `ready_chime.wav` — reused from flow 04 for popup close

These three plus the `clip.wav` (from flow 04) form the
"slideshow earcons" set. Add to the
[[project_elevenlabs_earcons]] catalog so they ship together.

**Estimated LOC**: ~150 for the shared library + 30 each per
expansion file = ~210 total (anchor + 2x multiplier per
[[feedback-loc-estimates-anchor-low]] → likely ~400-500 real).

## Test plan

R&F test (Vanilla skips this whole waypoint):
1. Reset the seen flag (or pick a leader you haven't played
   under R&F before — `HasSeenXP1FeaturesScreen` user option =
   0).
2. Start a new game with R&F ruleset. Pick any leader.
3. Wait through loading screen (waypoint 04).
4. Verify popup auto-opens after world load, before any other
   first-turn popup.
5. Verify announce: "Welcome to Rise and Fall. Page 1 of 9.
   Welcome." + description + nav hint.
6. Press Right → "Page 2 of 9. Eras." + description.
7. Press Left → back to page 1.
8. Press Ctrl+I → speak illustration description for page 1.
9. Press T → "Don't show again, on." Press T again → "Don't
   show again, off."
10. Navigate to page 9 → button text should be "Continue".
11. Press Enter on page 9 → popup closes, control passes to
    waypoint 06 (first-turn advisor) or directly to world.
12. Start another new R&F game → popup should not auto-open
    (seen flag set).
13. Reset seen flag, set "Don't show again" → start new R&F
    game → popup should not auto-open.
14. From in-game pause menu (Options), trigger
    `InGameTopOptionsMenu_ShowExpansionIntro` → popup should
    open mid-game (re-opening path).

GS test (12 pages instead of 9, different content):
- Repeat steps 1-14 with GS ruleset.
- Verify page count is 12 in the announce.
- Verify GS-specific topics (World Congress, Volcanoes,
  Climate) appear.

Vanilla test:
- Start a Vanilla game. Verify no expansion popup ever appears.
- Skip to waypoint 06.

## Cross-references

- [[project-first-turn-popups-block-input]] — this popup is one
  of the two we discovered blocks the world after waypoint 04
- [[project-rich-text-clipboard-pattern]] — apply to Ctrl+I
  illustration descriptions
- [[project-layered-info-hotkeys]] — Ctrl+I / Ctrl+T convention
- [[project-popup-nav-standard]] — every popup is arrow-key
  navigable with nav sound and label on each move
- [[reference-civ-vi-icon-tags-in-labels]] — strip [ICON_*] from
  description text
- Waypoint 06 — what fires next after this popup dismisses
