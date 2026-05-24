# 03 — AdvancedSetup (Create Game)

The Create Game / AdvancedSetup screen. Where the player picks
their leader/civ, ruleset, map, victory conditions, game modes,
and other AI opponents before clicking Start.

**Ramps status**: largely shipped in 0.3.9 via
`AdvancedSetupAccess.lua` (BaseMenu wrap of `g_GameParameters`).
This trace identifies the remaining trim work to bring leader
selection up to the layered-info standard
([[project-layered-info-hotkeys]]) and confirms ruleset variants
are entirely data-driven (no Lua/XML override).

## Engine source

- `Base/Assets/UI/FrontEnd/AdvancedSetup.lua` (1747 lines)
- `Base/Assets/UI/FrontEnd/AdvancedSetup.xml` (659 lines)
- `Base/Assets/UI/FrontEnd/GameSetupLogic.lua` (842 lines) —
  shared parameter framework
- `Base/Assets/UI/FrontEnd/PlayerSetupLogic.lua` —
  `DisplayCivLeaderToolTip` lives here (line 732); builds the
  placard contents per leader
- DLC overrides: **none**. Grep for `AdvancedSetup` in
  `DLC/Expansion1` returns nothing; in `DLC/Expansion2` it only
  returns Stadia phone shells (unused on PC). Ruleset divergence
  is entirely data-driven — `Visible`/`CriteriaRow` flips on
  parameters, DB rows for civs/leaders/CityStates/NaturalWonders
  gated by ruleset.

Our overlay:
- `CivViAccessMod/Assets/UI/Accessibility/AdvancedSetupAccess.lua`
  (524 lines)
- `CivViAccessMod/Assets/UI/Frontend/AdvancedSetup.lua` — thin
  shadow of base that ends with `include("AdvancedSetupAccess")`

## How it opens

- User navigates MainMenu → Single Player → "Create Game"
- `LuaEvents.MainMenu_AdvancedSetup` (or equivalent) fires;
  AdvancedSetup context is shown
- `OnShow()` (line 1311 of base Lua) refreshes
  parameters, sets WindowTitle, calls
  `GameSetup_RefreshParameters()` which builds the per-parameter
  pulldowns / checkboxes via `GameSetupLogic.lua`

Two visual layouts exist, switched by `AdvancedSetupButton`:
- **Basic view** (`CreateGameWindow`) — large leader pulldown
  centered, with BasicTooltipContainer + BasicPlacardContainer
  on either side showing CivToolTip and LeaderPlacard instances
- **Advanced view** (`AdvancedOptionsWindow`) — full per-player
  slot list (`NonLocalPlayersStack`), all parameters categorized
  into Primary / Game Modes / Victory / Secondary

Our BaseMenu overlay iterates `g_GameParameters` directly, so it
gives the full parameter set regardless of which visual view is
active. The visual basic-vs-advanced toggle is irrelevant in
speech mode.

## What appears visually

**Top bar**: MainLogo (cosmetic), DefaultButton, WindowTitle
("CREATE GAME"), CloseButton.

**Basic view center**:
- Ruleset pulldown (`CreateGame_GameRuleset`)
- Local-player civ pulldown (`Basic_LocalPlayerPulldown`) with
  small CivIcon + LeaderIcon
- Difficulty pulldown
- Speed pulldown
- Map type pulldown / Map select button
- Map size pulldown
- GameMode selectors (Heroes, Apocalypse, etc.) as toggle buttons
- "Advanced Options" button at bottom

**Basic view right** (`BasicTooltipContainer`):
- `CivToolTip` instance with InfoStack of:
  - HeaderInstance rows (section titles)
  - CivIconInstance (civ name + civ ability w/ description)
  - IconInfoInstance rows (leader ability, agenda, uniques —
    each with header + description text)

**Basic view left** (`BasicPlacardContainer`):
- `LeaderPlacard` instance with `LeaderImage` (large
  leader portrait, ~340x670)

**Advanced view left** (`PlayersSection`):
- Local player row with color pulldown + civ pulldown
- `NonLocalPlayersStack` of `NonLocalPlayerSlotInstance` rows
  (one per AI slot — color + civ pulldown + RemoveButton)
- `AddAIButton` at bottom

**Advanced view right** (`OptionsSection`):
- `PrimaryParametersStack`, `GameModeParameterStack`,
  `VictoryParameterStack`, `SecondaryParametersStack`
- `AdvancedTooltipContainer` (large CivToolTip clone) on the
  right edge

**Bottom**: StartButton, optionally LoadConfig / SaveConfig.

**Modal**: `ConflictPopup` — appears when a parameter conflict
blocks Start (e.g., two players assigned the same leader).
Already detected via our `preamble` reading
`GetGameParametersError()`.

## What it accepts as input

Mouse-driven in stock Civ VI. Our overlay adds:
- Arrow keys via BaseMenu (Up/Down through items, Right
  expand/Enter activate, Left collapse/Back, Tab between groups
  per [[project-tabbed-screen-nav-patterns]])
- Type-ahead via Help.lua (post-0.4.0)
- Ctrl+T for tooltip / mechanics (planned, not yet on this
  screen)
- Ctrl+I for image / portrait description (planned, not yet
  anywhere)

## How it closes / advances

- StartButton click → `OnStartButton` → game proceeds to
  loading screen (waypoint 04)
- CloseButton click / Esc → returns to single-player menu
- DefaultButton → `OnDefaultButton` → resets parameters

## Ruleset variants

**Vanilla / R&F / GS — single Lua/XML.** No expansion override.
All divergence is data-driven via the parameter framework:

- **Ruleset pulldown** offers Vanilla / Rise & Fall / Gathering
  Storm based on which DLCs are enabled in Mods. When the user
  flips ruleset, `UI_PostRefreshParameters` fires (our overlay
  hooks this and invalidates the BaseMenu items cache, line
  513-524 of AdvancedSetupAccess.lua).
- **Parameter visibility** flips via `parameter.Visible` —
  e.g., Disaster Intensity is GS-only, Era Score Difficulty is
  R&F+ only, Climate-related params are GS-only. Our overlay's
  `paramVisible()` per-item check (line 114-118) handles this
  dynamically; an item already in the list reads as `isNavigable
  = false` when `Visible` flips off.
- **Available civs / leaders** filtered by Ruleset constraint
  on the Players DB rows. Pulldown contents differ per ruleset
  but pulldown UX is identical.
- **Available city-states** filtered same way (see
  [[project-advancedsetup-pickers-next]] for CityStatePicker
  details).
- **Natural Wonders** filtered same way (MultiSelectWindow
  shows the ruleset-appropriate list).
- **Game Modes** are R&F+ (Heroes, Apocalypse, Monopolies,
  Secret Societies, Zombies, Tech/Civic Shuffle); Vanilla shows
  the "NoGameModesContainer" label.
- **Victory Conditions** — vanilla has Domination, Science,
  Culture, Religious, Score; R&F adds nothing new; GS adds
  Diplomatic Victory (which removes Score from the default set).
- **No additional popups** open from AdvancedSetup itself based
  on ruleset.

**Implication**: one trace doc, one implementation, three test
runs. No parallel `03-vanilla.md` / `03-rnf.md` / `03-gs.md`
needed.

**Q (Noel): images for city-states and natural wonders?**
Yes — both have visual assets shown in their respective pickers
(small icons in the picker row; larger artwork tooltips on
hover for wonders). They're addressed by separate describer
batches, not the leader batch:

- **City-states**: typically a small civ-style icon (banner /
  emblem). Less rich than leader portraits — short brief
  (1 sentence) is usually enough. Surface: the
  `CityStatePicker` row (see
  [[project_advancedsetup_pickers_next]]). Add
  `LOC_CIVVIACCESS_CITYSTATE_<TYPE>_PORTRAIT_BRIEF` keys via a
  new describer batch with a `prompts/city-states.txt` prompt
  modeled on `prompts/leaders.txt`.
- **Natural wonders**: full artwork tile-art per wonder, often
  with foliage / terrain / animals / lighting variation.
  Worth a brief + full (2-line + 4-sentence) treatment like
  leaders. Surface: the `MultiSelectWindow` natural-wonders
  picker AND the in-game discover-natural-wonder popup
  (waypoint not yet traced). Add
  `LOC_CIVVIACCESS_NATURAL_WONDER_<TYPE>_PORTRAIT_BRIEF` +
  `_FULL` keys via a `prompts/natural-wonders.txt` prompt.
- **World wonders / civilizations / units / buildings**:
  prompt files already exist under `tools/wonder-describer/
  prompts/`. Run the batches once we extract the asset images
  per category.

Tracked in a follow-up describer-batches checklist; not
gating for AdvancedSetup ramps (the pickers are already
reachable + selectable, just under-described).

## Current accessibility state

**Shipped (ramps)**:
- All parameters (global / Game Modes / Victory Conditions)
  navigable as a BaseMenu tree
- Player slots as a sub-group with per-slot parameters
- AddAI button
- Defaults / Back / Start action row
- Per-leader pulldown speaks the leader name on focus
- Parameter conflict (`ConflictPopup` trigger) announced via
  the preamble
- City-state picker (`CityStatePickerAccess`), Leader pool
  picker (`LeaderPickerAccess`), Natural Wonders picker
  (`MultiSelectWindowAccess`) all reachable

**Trim gaps identified by this trace**:
1. Leader pulldown focus says only the leader name — no civ,
   no agenda hint. **Ramps-adjacent**: a player who doesn't
   know which leader they want has no way to compare. Fix in
   the implementation step below.
2. Civ ability, leader ability, agenda, unique units, unique
   buildings/districts are visual-only (`CivToolTip` /
   `LeaderPlacard`). No Ctrl+T readout from the leader pulldown.
3. Leader portrait (the `LeaderImage` in LeaderPlacard) is
   visual-only. No Ctrl+I readout.
4. Game Mode buttons (Heroes, Apocalypse, etc.) show a
   `GameModePlacard` with description text — same gap as
   leaders. Lower priority; modes are fewer (5-7) and most
   players leave them off.
5. Civ icon and leader icon images on every pulldown row are
   identity markers, not unique content — no per-row image
   description needed; the leader name already conveys identity.

## Blind-first design

Apply [[project-layered-info-hotkeys]] to the leader pulldown
specifically:

**Layer 1 — focus** (arrow through pulldown options):
- Speak: `<Leader Name>, <Civ Name>` (e.g., "Cleopatra, Egypt")
- Fast nav stays interruptible
- Today says only "Cleopatra"; add civ

**Layer 2 — commit** (Enter / pulldown closes):
- Speak: `<Leader> of <Civ>. Agenda: <Agenda one-liner>.
  <1-sentence portrait brief>. Press Ctrl+T for description,
  Ctrl+I for image description.`
- Example: "Cleopatra of Egypt. Agenda: Queen of the Nile.
  A young queen wearing a golden headdress and white robes.
  Press Ctrl+T for description, Ctrl+I for extended image description."
- Replaces a vague "Leader committed" with the actionable summary

**Layer 3 — Ctrl+T** (any time leader pulldown is focused):
- Speak the full mechanics readout, drawn from the same data
  `DisplayCivLeaderToolTip` uses:
  - Civ ability: name + description
  - Leader ability: name + description
  - Agenda: name + description
  - Unique unit(s): name + description (1-2)
  - Unique buildings / districts / improvements: name +
    description (0-2)
- ~30-45 seconds of speech, interruptible mid-word
- Same content as the `CivToolTip` placard but linearized

**Layer 4 — Ctrl+I** (any time leader pulldown is focused):
- Speak the full portrait description (3-5 sentences) from the
  Gemini batch describer
- This is the visual artwork description — what the leader
  looks like, what they're wearing, expression, background

**Same pattern on Game Modes** (lower priority): focus speaks
mode name; Ctrl+T speaks the GameModePlacard description text.

**No change** to the rest of AdvancedSetup — parameters,
players, action row are all ramps-complete.

## Implementation notes

**Describer batch** (one-shot, covers ramps + trim for 03 + 04):
- Source: `tools/wonder-describer/describe.py` with
  `prompts/leaders.txt`
- Inputs: every leader portrait .dds asset from
  `Base/Platforms/Windows/Art` (and expansion equivalents),
  converted to PNG. Need to enumerate leader assets across
  ruleset DLC dirs first.
- Output: `LeaderDescriptions.xml` under
  `CivViAccessMod/Assets/Text/en_US/`, registering LOC keys
  per leader:
  - `LOC_CIVVIACCESS_LEADER_<TYPE>_PORTRAIT_BRIEF` (1 sentence)
  - `LOC_CIVVIACCESS_LEADER_<TYPE>_PORTRAIT_FULL` (3-5 sentences)
- Prompt update: ask Gemini for both fields in one call to halve
  API hits

**Code changes** in `AdvancedSetupAccess.lua`:
- The leader pulldown is wrapped via `parameterItem` →
  `BaseMenuItems.Pulldown`. To customize speech for this one
  parameter, detect `parameter.ParameterId == "PlayerLeader" or
  matches "PlayerLeader%d+"` and use a custom pulldown variant
  that:
  - Overrides the focus speech to "<Leader>, <Civ>"
  - Overrides the commit speech to the Layer 2 line above
  - Installs Ctrl+T handler that speaks Layer 3
  - Installs Ctrl+I handler that speaks Layer 4
- Layer 3 content sourcing: read `Players` / `LeaderTraits` /
  `Traits` / `Agendas` DB tables directly via the Civ VI Lua
  DB binding (`GameInfo.Players`, etc.). Don't try to scrape
  the visual `CivToolTip` — that's a one-way build, not a query.
- Layer 4 content sourcing: `Locale.Lookup(
  "LOC_CIVVIACCESS_LEADER_" .. leaderType ..  "_PORTRAIT_FULL")`
- Layer 2 brief: same key with `_PORTRAIT_BRIEF` suffix

**LOC strings to add** (in addition to the describer output):
- `LOC_CIVVIACCESS_LEADER_COMMIT_FORMAT` — translatable
  template for Layer 2 ("{1_Leader} of {2_Civ}. Agenda:
  {3_Agenda}. {4_PortraitBrief}. Press Ctrl+T for description,
  Ctrl+I for image description.")
- `LOC_CIVVIACCESS_LEADER_TOOLTIP_SECTION_<X>` — section
  headers for Layer 3 readout

**Modinfo**: register the new `LeaderDescriptions.xml` via
`<UpdateText>` per [[reference-civ-vi-modinfo-text]].

**No changes** to BaseMenu or HandlerStack: the Ctrl+T / Ctrl+I
hotkeys install via the standard help-overlay pattern already
in 0.4.0 foundation work.

## Test plan

Run all three under Vanilla, R&F, and GS rulesets. Report
per-ruleset pass/fail.

1. Open Create Game from MainMenu. Verify the screen
   announces ("Advanced Setup" or equivalent).
2. Arrow through the global parameters at L1. Verify ruleset
   pulldown is reachable and reads "Ruleset, <current>".
3. Flip the ruleset. Verify the items cache invalidates and
   GS-only / R&F+ parameters appear or disappear from the L1
   list as expected (e.g., Disaster Intensity).
4. Enter the Players group. Arrow to the local-player slot.
   Enter. Arrow to the Leader parameter. Open.
5. Arrow through leaders. Verify Layer 1 announce: "<Leader>,
   <Civ>." Three or four arrows fast — no announce overrun.
6. Press Ctrl+T on a leader. Verify Layer 3 readout starts
   and is interruptible by next arrow.
7. Press Ctrl+I on a leader. Verify Layer 4 readout (portrait
   description) starts.
8. Commit a leader (Enter). Verify Layer 2 announce includes
   leader, civ, agenda, portrait brief, and the Ctrl+T / Ctrl+I
   hint.
9. Test on a ruleset-exclusive leader (e.g., Hammurabi for R&F+
   if available, Kublai Khan for GS-only DLC). Verify the
   filtered pulldown matches the active ruleset.
10. Repeat steps 4-8 with an AI slot's leader. Confirm
    behavior matches the local-player slot.
11. (Trim) Repeat ramps test under Game Mode toggles — focus
    speaks mode name, Ctrl+T speaks mode description.
12. Start the game. Confirm the loading screen receives the
    committed leader and waypoint 04 trace can proceed.

## Cross-references

- [`screens/options.md`](screens/options.md) — sibling trace
  for the Options / Settings menu (separate gap Noel flagged
  in 2026-05-22 review). Largely shipped via OptionsAccess.lua;
  KeyBindings tab is the remaining work. Mentioned here only
  because it's the natural next ramp after AdvancedSetup —
  not coupled architecturally.
- [[project-advancedsetup-test-plan]] — the prior 28-step
  AdvancedSetup verification checklist; this trace supersedes
  the "what's missing" parts but the 28-step list is still the
  regression run after any change.
- [[reference-civ-vi-param-quirks]] — `g_PlayerParameters`
  vs `g_GameParameters`, `Visible` flag dynamics, ruleset
  refresh hook chain
- [[project-leader-civ-boons-narration]] — the broader call
  for leader/civ uniques narration; this trace partially fulfills
  it for AdvancedSetup
- [[project-layered-info-hotkeys]] — the Ctrl+T / Ctrl+I
  convention applied here for the first time
