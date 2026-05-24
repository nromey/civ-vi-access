# 10 — World interactive baseline (HexCursor + map nav resumption)

The first moment the user can move a logical cursor over the
map and explore it via screen-reader output. All blocking
popups have dismissed (waypoints 05, 06), the first unit has
been announced (waypoint 08), and the engine has handed control
to the player. From here on, the experience is the in-game
loop — and the cornerstone for blind navigation is **HexCursor**,
the free-roam tile cursor we've been building toward all
session.

This trace doc closes the new-game-flow arc. After this, the
sequence becomes turn-by-turn play, which is the much larger
"in-game accessibility" body of work that 0.4.x continues into.

## Engine source

Civ VI has **no native keyboard hex cursor**. Arrow keys pan
the camera; there's no logical "selected tile" the player can
move with the keyboard. Mouse hover / click is the entire
sighted UX for tile inspection.

Our HexCursor IS the cursor. Sources:

- `CivViAccessMod/Assets/UI/Accessibility/HexCursor.lua` (329 lines)
  — owns `(_x, _y)` state; Q/W/E/A/S/D/Z/X/C key layout for
  6-direction hex movement (pointy-top: NW/NE/W/E/SW/SE)
- `CivViAccessMod/Assets/UI/Accessibility/HexGeom.lua` (171
  lines) — hex geometry helpers (axial coords, neighbors)
- `CivViAccessMod/Assets/UI/Accessibility/InputRouter.lua` (118
  lines) — central input dispatch
- `CivViAccessMod/Assets/UI/Accessibility/HandlerStack.lua` (240
  lines) — stack-based handler push/pop
- `CivViAccessMod/Assets/UI/Accessibility/EngineHotkeys.lua` (91
  lines) — engine InputAction announce
- `CivViAccessMod/Assets/UI/Accessibility/ScreenReaderPlotUtils.lua`
  — terrain / feature / unit stringify helpers shared with
  ScreenReaderEventHandlers

Engine integration points:
- `Events.InputActionTriggered(actionId)` — fires when player
  invokes any engine input action; we use this for engine-bound
  hotkeys per [[project-announce-engine-actions]]
- `Map.GetPlot(x, y)` — resolves plot userdata from coords
- `Map.GetAdjacentPlot(x, y, direction)` — 6-direction
  neighbor lookup
- `Game.GetLocalPlayer()`, `Players[id]` — player context
- `Units.GetUnitsInPlot(plot)`, `Cities.GetCityInPlot(plot)` —
  what's on the tile

## How it opens

After the final blocking popup dismisses (FIRST_GREETING from
waypoint 06, or directly from waypoint 05 if no advisor), the
engine completes the transition to interactive world state:

- `Events.LoadScreenClose` fires (well before this; covered in
  waypoint 04)
- Final popup → `UIManager:DequeuePopup`
- Engine sets `Input.SetActiveContext(InputContext.World)`
  (done by LoadScreen.OnActivateButtonClicked line 57)
- Camera centers on the player's starting unit
- `Events.LocalPlayerTurnBegin` fires for turn 1
- `Events.UnitSelectionChanged` fires auto-selecting the
  Settler (waypoint 08 announces this; waypoint 09 skips its
  generic turn-begin announce since turn == startTurn)

Now HexCursor can take over. The auto-select positioned the
camera; HexCursor's first interaction should anchor the cursor
to the starting unit's hex so the player has a known origin.

## What appears visually

The 3D world view:
- Hex grid, terrain types (grassland, plains, tundra, etc.)
- Features (forest, jungle, marsh, floodplains, hills,
  mountains)
- Resources (icons over their hex when known)
- Player's units (Settler, Warrior typically)
- Goody huts (visible huts on land — tribal villages)
- Fog of war / unrevealed hexes (typically gray cloud)
- Action panel (bottom right) showing unit actions
- Notification panel (right side) for events
- Top panel (gold, science, faith, etc.)
- Minimap (bottom right)

## What it accepts as input

Engine-side hotkeys (`Events.InputActionTriggered`):
- Move unit: arrow keys + NUMPAD (engine-bound)
- Found city: B (engine-bound)
- End turn: Enter (engine-bound)
- Toggle resources lens: Q (engine-bound)
- Auto-explore: E (engine-bound)
- Attack: A (engine-bound)
- Sleep: Z (engine-bound)
- Toggle civics tree: C (engine-bound)
- Many more — see [[reference-civ-vi-default-keybindings]]

**Critical**: many of the letters we wanted for HexCursor
6-direction nav (Q/E/A/Z/C) are engine-bound. The Lua input
handler never sees them; they're consumed by the engine before
reaching Lua. Mitigation:
- Use D/W/X for unbound singletons
- Or use NUMPAD (with NumLock ON to avoid NVDA conflict — see
  [[reference-screen-reader-key-conflicts]])
- Or register our own engine InputActions in the modinfo
  Configuration DB (the path that resolved the
  "AddUserInterfaces keyboard" debug spiral —
  [[reference-addUserInterfaces-no-keyboard]])

Our HexCursor currently uses Q/W/E/A/D/Z/X/C; whether they
actually reach the handler vs being eaten by engine actions
needs verification (this is the "Configuration-DB-only modinfo
fix" the trace plan referenced).

## How it closes / advances

No "close" — the world view is persistent for the rest of the
game. Sub-screens open over it (Civilopedia, Tech tree, Civic
tree, Government screen, World Congress, Diplomacy, etc.) and
the world stays available behind. End-turn → next round → world
remains.

The "advance" out of this baseline is moving into deeper
in-game work: city panels, tech tree, diplomacy. Each becomes
its own trace doc when we get there. This waypoint is just
"the world is interactive; HexCursor + plot inspection works."

## Ruleset variants

The interactive world itself is ruleset-invariant. Content
varies per ruleset:

- **Vanilla**: standard terrain, features, resources, units
- **R&F**: adds Loyalty pressure on tiles, governors visible in
  cities, era-specific moments
- **GS**: adds environmental effects (floods, storms, volcanic
  eruptions), strategic resources require improvement
  consumption, World Congress overlay during voting periods

For HexCursor specifically, the tile readback shape is the
same — only the content (resource types, features) differs by
ruleset. Per [[reference-civ-vi-param-quirks]] this is all
DB-driven; HexCursor's terrain/feature/resource lookups via
`GameInfo.Terrains` / `GameInfo.Features` / `GameInfo.Resources`
automatically return whatever's defined in the active ruleset.

**Implementation impact**: no per-ruleset code. The same
HexCursor reads the same plot APIs; what it speaks depends on
DB content the engine surfaces.

## Current accessibility state

**HexCursor is in flight** (~500 LOC across the foundation
modules). The infrastructure exists:
- Q/W/E/A/D/Z/X/C movement → 6-direction step ✓
- Plot announce on move (terrain + feature + resource) ✓
- Cursor jump to selected unit on init ✓
- HandlerStack for managing input layers ✓
- Help system (? hotkey) for binding discovery ✓

**Open verification gaps** (the reason this waypoint trace was
the resume point):
1. Do HexCursor's Q/E/A/Z/C keys actually reach the Lua handler
   when the world is interactive, or do they get eaten by
   engine actions first? — per
   [[reference-civ-vi-default-keybindings]] all five of those
   are engine-bound
2. Did the Configuration-DB-only modinfo fix correctly register
   our own InputActions so `Events.InputActionTriggered` fires
   for our hex-nav actions?
3. Does HexCursor's Initialize correctly fire after world
   becomes interactive (not before, when the player isn't
   ready)?
4. Are the popup-blocker fixes (waypoints 05 + 06 accessible
   versions) in place so HexCursor isn't starved of input by a
   modal hiding above?

The 6-iteration debug spiral that led to this rewrite was
caused by assuming HexCursor was the problem when the real
blocker was the inaccessible first-turn popups
([[project-first-turn-popups-block-input]]).

## Blind-first design

**On world-interactive transition** (after final popup
dismisses):

1. Speak: "World interactive. Press question mark for help."
2. Anchor HexCursor at the selected unit's hex (waypoint 08
   already announced the unit; HexCursor inherits the location)
3. Player can now navigate the map via Q/W/E/A/D/Z/X/C (or
   whatever final key layout we ship)

**On HexCursor move** (already designed; ship behavior):
- Speak target tile: terrain + feature + resource + units/cities
  on the tile
- Use 6-direction vocabulary per [[project-hex-grid-navigation]]
  for adjacency mentions
- Terse default; Ctrl+T for full tooltip detail

**Help system (? hotkey)** already loads HexCursor's bindings
and any other handler-stack entries. Pressing ? speaks the
binding list with type-ahead search per
[[project-04-engine-investigation]].

**Engine-hotkey announce** ([[project-announce-engine-actions]]):
when player invokes B (Found City), Q (Toggle Resources), etc.,
speak the action + state if toggle.

**Future polish layers** (out of scope for this trace):
- Surveyor / scanner port from Civ V Access for spatial-audio
  region scans
- Routes builder for plotted-path traversal
- Battle visualization for combat outcomes
- Plot tooltip rich-text via Ctrl+T

## Implementation notes

This waypoint largely **verifies** existing work rather than
adding new code. The trace is a checklist for resuming the
HexCursor implementation:

1. Verify the modinfo Configuration-DB registration of our
   InputActions actually works (run game, press Q while
   HexCursor is supposed to be active, check `lua.log` for
   `EngineHotkeys` print + HexCursor move log line).
2. If actions don't fire: fix the InputActions registration in
   modinfo. Check Database.log for silent failures per
   [[reference-civ-vi-modinfo-text]].
3. If actions DO fire but HexCursor doesn't move: debug the
   HandlerStack push/pop sequence; confirm HexCursor handler is
   active when world is interactive.
4. If HexCursor moves but plot announce is silent: check Tolk
   initialization timing — ScreenReader should be loaded by
   gameplay-script-time.
5. Speak "World interactive. Press question mark for help." on
   the world-interactive transition. Hook: subscribe to
   `Events.LoadScreenClose` in a gameplay script, defer ~500ms
   (advisor popup may still be processing), then announce.

**New LOC needed for the world-interactive announce**: minimal,
~20 lines.

**Estimated total work to make this waypoint shipped**: the
HexCursor work is already 500+ LOC in flight; this trace closes
out the verification + adds the world-interactive announce.
~50-100 LOC of net-new code (per
[[feedback-loc-estimates-anchor-low]] → 100-250 once edge cases
surface during the resumed debug session).

## Test plan

Per-ruleset (Vanilla, R&F, GS):

1. Apply all prior waypoint fixes (waypoints 05 + 06
   accessible popups, waypoint 08 first-turn orientation).
2. Start a new game. Click through AdvancedSetup.
3. Wait through loading (04), expansion intro if applicable
   (05), advisor popup (06). Dismiss each accessibly.
4. Verify first-turn orientation (waypoint 08) fires for the
   Settler.
5. Verify "World interactive. Press question mark for help."
   announces ~500ms after the final popup closes.
6. Press Q (or whatever the final NW key is) → HexCursor moves
   one hex NW → announces target tile.
7. Press D → HexCursor moves E → announces.
8. Continue cycling around the start unit, hitting all 6
   directions.
9. Press ? → speak the binding list (Help system).
10. Press B (Build City) → engine action fires →
    EngineHotkeys announces "Found city" if applicable.
11. Press Enter (End Turn) → next turn begins → waypoint 09's
    "Turn 2." announces.
12. Verify HexCursor cursor persists across turns (doesn't
    reset to start unit unless explicitly re-anchored).

## Cross-references

- [[project-first-turn-popups-block-input]] — the popups that
  were starving HexCursor of input; resolved by waypoints 05 + 06
- [[reference-addUserInterfaces-no-keyboard]] — why our addin
  needed engine InputActions, not raw key handling
- [[reference-civ-vi-default-keybindings]] — engine eats
  Q/E/A/Z/C; HexCursor needs registered InputActions
- [[reference-screen-reader-key-conflicts]] — NVDA numpad
  intercept; mitigations
- [[project-04-engine-investigation]] — the 0.4.0 foundation
  modules that HexCursor depends on
- [[project-hex-grid-navigation]] — 6-direction vocabulary
- [[project-announce-engine-actions]] — broader announce for
  ~30 engine-bound hotkeys
- [[project-info-hotkeys]] — H/M/P/S/U/L/D info-layer hotkeys
  that build on HexCursor's tile context
- `CivViAccessMod/Assets/UI/Accessibility/HexCursor.lua` etc.
  — existing implementation to resume
- Waypoint 08 — first-turn orientation provides the starting
  context; HexCursor takes over for subsequent exploration
