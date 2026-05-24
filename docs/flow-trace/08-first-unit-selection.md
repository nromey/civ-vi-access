# 08 — First unit auto-selection

When the world becomes interactive after the first-turn popups
close, the engine auto-selects the player's starting unit (the
Settler, or Warrior/Scout in some configurations) and centers
the camera on it. For a sighted player this gives an immediate
"here's where you start" orientation cue.

For a blind player, our existing `ScreenReaderEventHandlers.lua`
already announces unit selection — name + adjacent points of
interest. The questions for this waypoint: does the auto-select
event actually fire (and reach our handler) on first turn? And
what context is missing from the current announce that would
help a player orient themselves at turn 1?

## Engine source

- No dedicated Lua file — this is an engine-driven auto-select
  that fires `Events.UnitSelectionChanged` on the player's
  first unit when the world becomes interactive.
- Engine-side selection logic lives in C++ (not Lua-readable).
- The "what unit does each civ start with" data lives in:
  - `Base/Assets/Gameplay/Data/Players.xml` — base civ defaults
  - `Base/Assets/Gameplay/Data/Units.xml` — unit definitions
  - DLC unit XML for civs with unique starting units
- DLC overrides for selection behavior: none Lua-visible.

## How it opens

- Engine completes world load → fires `LoadGameViewStateDone`
- Loading screen dismisses → expansion intro fires (if applicable)
- Expansion intro dismisses → first-turn advisor fires (if
  applicable)
- All popups dismissed → world becomes interactive
- Engine auto-selects the player's first unit (typically the
  Settler with `MOVES = 2`)
- Camera centers on the unit
- `Events.UnitSelectionChanged(playerID, unitID, hexI, hexJ,
  hexK, isSelected, isEditable)` fires

**Open question for verification**: does the auto-select event
fire AFTER both popups dismiss (so our handler catches it), or
does the engine fire it as part of the initial game setup,
potentially before our gameplay scripts have loaded or Tolk has
initialized? Test plan below resolves this.

## What appears visually

- Selected unit has a colored selection ring on its hex
- Action panel (bottom of screen) populates with the unit's
  available actions (Found City, Move To, Sleep, etc.)
- Unit name + HP bar + moves remaining shown in the unit panel
- Camera is centered on the unit's hex

## What it accepts as input

Once auto-select fires:
- Standard unit movement keys (arrow keys, NUMPAD diagonals)
- Action hotkeys (B for Build City, A for Attack, etc.)
- Tab to cycle to next unit (if multiple units this turn)
- HexCursor (when waypoint 10 lights up) provides arrow-key
  navigation over the map

## How it closes / advances

- Player issues a unit command (Move, Found City, Sleep, Skip)
  → unit becomes used → engine may auto-select next unit
- Player presses End Turn → turn ends, advances to waypoint 09
  (your-turn announcement on next turn)
- Player manually selects a different unit → another
  `Events.UnitSelectionChanged` fires

## Ruleset variants

The auto-select mechanism itself is ruleset-invariant — same
engine event, same selection behavior. **Starting unit
composition varies**:

- **Most civs (all rulesets)**: 1 Settler + 1 Warrior
- **Civs with starting-unit replacements**: e.g., Gilgamesh's
  Sumeria starts with a War-Cart instead of Warrior (base
  game); Cyrus's Persia starts with an Immortal (R&F)
- **R&F additions**: Cree (Poundmaker) gets a Scout instead of
  Warrior; some civs get extra builders
- **GS additions**: Maori (Kupe) starts at sea with a unique
  starting position; Phoenicia (Dido) gets a Bireme

The engine selects whichever unit comes first in the start-of-
turn unit list. Usually that's the Settler.

**Implementation impact**: ruleset-invariant code; per-civ
starting-unit content already correctly announced by the
existing handler since it reads the unit's display name from
the DB via `GameInfo.Units[unit:GetType()].Name`.

## Current accessibility state

**Shipped via `CivViAccessMod/Assets/UI/Accessibility/ScreenReaderEventHandlers.lua`** (line 107
`OnUnitSelectionChanged`):

- Announces unit name (e.g., "Settler")
- Appends "(damaged)" suffix if HP < max
- Lists adjacent units + cities by 6-direction (NE, E, SE, SW,
  W, NW)
- Filtered to own-player units only (foreign units announce via
  a different path during diplomacy)

**Gaps for first-turn orientation**:

1. **Location context** — the player doesn't know WHERE they
   are on the map. "Settler" alone doesn't say "you're on a
   grassland tile in the temperate region, near a coast." The
   first turn is when this context matters most.
2. **Terrain underfoot** — the Settler's current hex type
   (Grassland / Plains / Tundra / Desert / Snow / Coast /
   Ocean) is not announced.
3. **Movement points** — "Settler with 2 moves remaining" is
   useful context that's missing.
4. **Available actions** — for a first-time player, knowing
   "Press B to found city here" matters.
5. **Visible resources / features** — if the start tile has a
   bonus / luxury / strategic resource, that's actionable info.
6. **Starting region descriptor** — Civ VI has a stab at a
   region name internally (start bias system); could be exposed.

## Blind-first design

Extend the existing `OnUnitSelectionChanged` handler to
detect "this is the first turn, first auto-select" and queue
a richer orientation announce. After turn 1, fall back to the
current concise announce (terse-by-default per
[[feedback-terse-announce-default]]).

**Detection**: `Game.GetCurrentGameTurn() ==
GameConfiguration.GetStartTurn()` AND first time this handler
has fired for an own-player unit since game start.

**First-turn auto-select announce** (queued lines, each
interruptible by next-key):

1. `"<Unit name>, <terrain underfoot>."` —
   e.g., "Settler on grassland."
2. `"<Movement points> moves remaining."`
3. `"<Region descriptor or coordinates>."` — e.g., "Temperate
   region." or "Map position 23, 14." Use start-bias data or
   fall back to hex coords.
4. `"Visible nearby: <feature/resource list>."` — only if
   non-empty. e.g., "Visible nearby: rice southeast, fish east."
5. `"Adjacent: <existing adjacency line>"` — from current
   handler (units + cities adjacent)
6. `"Press B to found city here. Press Shift+M for a map
   overview. Press Tab to cycle units. Press End Turn (Enter)
   when ready."` — first-turn nav hint

**Subsequent turn unit selections**: keep the current terse
announce (unit name + adjacency).

**Edge case: starting unit isn't auto-selected**: if our
handler doesn't fire within ~2 seconds of `WorldInteractive`
event, manually trigger an announce: "Your starting units are
ready. Press Tab to select." This is the safety net for the
"does auto-select reach our handler" open question.

## Implementation notes

**File to extend**: existing
`CivViAccessMod/Assets/UI/Accessibility/ScreenReaderEventHandlers.lua`
(line 107 `OnUnitSelectionChanged`). Add a first-turn branch
at the top of the function.

**New helper**: `firstTurnOrientation(pUnit, hexI, hexJ)` that
builds the multi-line announce. Returns nil for turn ≥ 2 so the
existing concise path runs.

**Data sources**:
- Terrain: `Map.GetPlot(hexI, hexJ):GetTerrainType()` →
  `GameInfo.Terrains[type].Name`
- Movement: `pUnit:GetMovesRemaining()`
- Resources: iterate adjacent + same hex via
  `Map.GetPlot():GetResourceType()`
- Region: `pUnit:GetStartingPlot()` may have a region tag, or
  compute coarse latitude band from hexJ relative to map height

**LOC strings to add**:
- `LOC_CIVVIACCESS_FIRST_TURN_UNIT_FORMAT` —
  "{1_Unit} on {2_Terrain}."
- `LOC_CIVVIACCESS_MOVES_REMAINING_FORMAT` —
  "{1_N} moves remaining."
- `LOC_CIVVIACCESS_REGION_TEMPERATE` / `_TROPICAL` /
  `_POLAR` / `_DESERT` — region descriptors
- `LOC_CIVVIACCESS_FIRST_TURN_VISIBLE_NEARBY` —
  "Visible nearby: {1_List}."
- `LOC_CIVVIACCESS_FIRST_TURN_NAV_HINT` —
  "Press B to found city here. Press Shift+M for map overview.
  Press Tab to cycle units. Press End Turn when ready."

**Modinfo**: no changes (existing
`ScreenReaderEventHandlers.lua` is already registered).

**Estimated LOC**: ~80 to extend the handler + ~10 LOC strings
= ~90 (per [[feedback-loc-estimates-anchor-low]] →
~180-250 real once map-region detection edge cases land).

**Dependency**: ScreenReaderPlotUtils already provides
direction-string + unit/city stringify helpers; first-turn
orientation can reuse them.

## Test plan

Per-ruleset (Vanilla, R&F, GS), per-civ-variant:

1. Start a new Vanilla game as Trajan (Settler + Warrior
   start).
2. Click through advisor popups; wait for world.
3. Verify auto-select announce fires within 2s of world
   interactive. Verify content:
   - "Settler on grassland." (or whatever terrain)
   - "2 moves remaining."
   - Region descriptor
   - Adjacent line (if any)
   - First-turn nav hint
4. Press Tab → cycle to Warrior → verify terse announce ("Warrior
   on plains, adjacent: …")
5. Press Tab again → cycle back to Settler → terse announce
   (no first-turn hint repeat).
6. Press End Turn → advance to turn 2 → verify NO first-turn
   hint on next unit auto-select (only terse).

7. Restart as Gilgamesh (War-Cart instead of Warrior); verify
   War-Cart announces correctly.
8. R&F: start as Cyrus (Immortal start); verify Immortal
   announces.
9. GS: start as Kupe (sea start, Maori); verify "Settler on
   ocean" and the special starting situation announces clearly.

**Auto-select reliability check**:
- After the first-turn advisor popup dismisses, count seconds
  until first announce fires. Should be ≤2s. If never fires,
  the safety-net "starting units are ready, press Tab" should
  speak.

## Cross-references

- `CivViAccessMod/Assets/UI/Accessibility/ScreenReaderEventHandlers.lua`
  — current handler to extend
- [[feedback-terse-announce-default]] — terse on subsequent
  selections, only verbose on first turn
- [[reference-civ-vi-default-keybindings]] — B is bound to
  Build City; Tab to next unit; verify these are reachable
- [[project-hex-grid-navigation]] — 6-direction vocabulary for
  adjacency
- Waypoint 09 (your-turn announcement) — fires AFTER this
  waypoint for subsequent turns
- Waypoint 10 (world interactive baseline) — HexCursor work
  starts here; spatial map navigation builds on the same
  ScreenReaderPlotUtils helpers
