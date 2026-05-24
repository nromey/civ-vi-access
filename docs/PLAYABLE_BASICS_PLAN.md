# Playable Basics Plan — 0.5.x

**Framing question**: how do we add features so a blind player can play Civ VI's basic game loop?

Today (0.4.1, 2026-05-23) the new-game flow is end-to-end speakable
through to first-turn-interactive. HexCursor reads tiles. The player
can found their first city with B. After that — they're stuck.
They can't move units, can't set research, can't choose production
when notifications fire.

This plan covers the four features that unlock basic play:

1. **Movement Phase 1** — direct-move via Alt+cluster keys
2. **Movement Phase 2** — target mode with multi-hex path preview
3. **Research** — keyboard-accessible tech + civic tree
4. **City production** — keyboard-accessible city production picker

Combat, diplomacy, World Congress, religion, espionage, and the rest
of the mid/late game are explicitly **deferred**. Goal is "can play a
peaceful builder game" first; combat and beyond are next-arc work.

Per Noel 2026-05-23: "how do we add features to help us start playing
the game basics."

## Cross-cutting design decisions

**Coords are verbosity-toggleable.** Default off — per-move announces
stay short ("Plains with Woods"). User presses Alt+V to flip on; then
per-move includes coords ("Plains with Woods, 23, 14"). Same pattern
as the existing Alt+V chatty/terse toggle from the front-end. Alt+S
(absolute coords) and Shift+S (relative-to-capital) hotkeys remain
available regardless of verbosity.

**Civ V Access is the reference design.** Every feature in this plan
starts by reading the Civ V Access analogue first. Local clone at
`C:\dev\Civ-V-Access`; read directly, do NOT fetch from GitHub. See
also [[reference_civ_v_access]], [[reference_local_access_mod_sources]],
[[feedback_civ_v_access_is_local]].

**Civ VI engine differences** that affect this plan:
- No Havok Script Lua hook for engine fork → can't add custom engine
  events like Civ V Access's `CivVAccessMissionDispatched`. Lean on
  pure engine signals (`Events.UnitMoveComplete`, `UnitOperations`,
  etc.) instead. May require timing fallback for net-message resolution.
- Civ VI uses InputActions registered via XML for global hotkeys.
  Pattern proven in 0.4.1 — see `Assets/Data/RemapForHexCursor.xml`
  for the existing HexCursor + R/T/I/S registrations and the rebind-
  conflicting-engine-actions-to-Alt pattern.
- City management is on its own UI context. Keyboard input dispatch
  to LoadScreen-style overlays is fragile during `InputContext.Loading`
  — for in-game contexts (`World`, `Diplomacy`, `Popup`) input dispatch
  is more reliable, but each new screen needs its own ContextPtr or
  global InputAction route.

## Phase 1: Direct-move (Alt+QWEADZXC)

Single-step movement: press Alt+cluster-key, unit moves one hex in
that direction. Cursor follows. Speak the result.

### Civ V Access reference

- File: `C:\dev\Civ-V-Access\src\dlc\UI\InGame\CivVAccess_UnitControlMovement.lua`
- Key fn: `directMove(direction)` lines 167–256
- Commit fn: `commitDirectMove()` line 150 — sends `MISSION_MOVE_TO`
  via `Game.SelectionListMove()`
- Async result: `onUnitMoveCompleted()` (line 480) reads
  `SerialEventUnitMove`; `onMissionDispatched()` (line 535) reads the
  engine fork hook
- Out-of-moves gate: lines 201–204 — interrupts with "out of moves"
  rather than queuing 0-MP single-step

### Civ VI port

**Bindings** (extend `Assets/Data/RemapForHexCursor.xml`):

```
CIVVIACCESS_MoveNW → Alt+Q   (NW move)
CIVVIACCESS_MoveNE → Alt+E
CIVVIACCESS_MoveW  → Alt+A
CIVVIACCESS_MoveE  → Alt+D
CIVVIACCESS_MoveSW → Alt+Z
CIVVIACCESS_MoveSE → Alt+C
```

`ContextId="World"` (in-game only — direct-move makes no sense in
shell / menus). Plus numpad alternates.

**New file**: `Assets/UI/Accessibility/UnitMovement.lua`

Module exports `UnitMovement.directMove(direction)`. Subscribe in
`HexCursorAddin.lua` to the new InputActions and dispatch.

**Algorithm**:

1. Get currently selected unit (`UI.GetHeadSelectedUnit()`).
2. If no unit selected, speak "No unit selected" and return.
3. Get unit's current plot (X, Y).
4. Compute target plot via `Map.GetAdjacentPlot(X, Y, direction)`.
5. If target plot doesn't exist (edge of map), speak "Edge of map" and
   return.
6. Pre-validate: can this unit move there?
   - `pUnit:GetMovesRemaining()` > 0
   - `UnitManager.CanStartCommand(pUnit, UnitCommandTypes.CANCEL)`
     or similar API
   - Pathfind via `UnitManager.GetMoveToPath(pUnit, targetX, targetY)`
     — returns nil if unreachable
7. If pre-validation fails, speak the reason ("Out of moves",
   "Unreachable", "Enemy occupied — combat deferred").
8. Otherwise issue the move via `UnitManager.RequestCommand(pUnit,
   UnitCommands.MOVE_TO, params)`.
9. Sync HexCursor to follow the unit's new position.
10. Subscribe to `Events.UnitMoveComplete` for the announce ("moved
    NW. 1 move remaining" or "moved NW. Action complete.").

**Announce format**:

- Success: "Moved {direction}. {N} moves remaining." (or "Action
  complete." if MP = 0)
- With verbosity on: append ", {tile description with coords}"
- Failure: speak the reason; cursor doesn't move

**Combat case**: enemy occupies target. For Phase 1, treat as failure:
speak "Enemy {unit-type} occupies {direction}. Combat coming in a
future release." Do NOT attempt to attack. Combat is deferred.

### Out of scope for Phase 1

- Multi-hex paths (use Phase 2)
- Embark/disembark (engine handles transparently, but speak the
  transition)
- Pending queued moves (no Shift modifier; 0-MP error is hard fail)
- War declaration popup (no movement into rival territory triggers
  this in Phase 1 since the player has no rivals adjacent yet at
  game start)

## Phase 2: Target mode (multi-hex paths)

Enter "target mode" via a hotkey; cursor moves freely with QWEADZXC;
press Enter to commit a multi-hex move; press Space to preview the
path; press Escape to cancel.

### Civ V Access reference

- File: `C:\dev\Civ-V-Access\src\dlc\UI\InGame\CivVAccess_UnitTargetMode.lua`
- Entry: `UnitTargetMode.enter()` ~line 100s
- Preview: `moveModePreview()` line ~524
- Path-to-steps formatter: `HexGeom.stepListFromPath()` line 171 of
  same file (clusters "3 NE, 2 E")
- Commit: Enter → `MISSION_MOVE_TO` (with `Shift+Enter` queueing —
  see Civ V design; for Civ VI we may skip queueing in Phase 2)

### Civ VI port

**New bindings**:

```
CIVVIACCESS_EnterTargetMode → Alt+M (mnemonic "Move")
```

Inside target mode (mode-local key handler, pushes onto HandlerStack):

- Q/W/E/A/D/Z/X/C → move cursor (reuses existing HexCursor.move,
  same as exploration)
- Space → speak path preview ("Path: 3 NE, 2 E. 5 MP. Requires
  embark on tile 4.")
- Enter → commit move via `UnitManager.RequestCommand(pUnit,
  UnitCommands.MOVE_TO, {x, y})`
- Shift+Enter → queue for next turn (deferred — Civ VI has
  `MOVE_TO` queueing in `UnitOperations`, look it up)
- Esc → cancel target mode, pop handler

**Path preview algorithm**:

1. Get unit's current plot.
2. Get cursor's plot.
3. Pathfind via `UnitManager.GetMoveToPath(pUnit, cursorX, cursorY)`.
4. If nil → speak "Unreachable" + try relaxations (Civ V Access does
   strict → declare-war → ignore-stacking → through-enemy; we can do
   simpler at first: strict only, fallback to "unreachable" message).
5. Convert path node list → step clusters via a new
   `HexGeom.stepListFromPath` (port from Civ V Access's
   `CivVAccess_HexGeom.lua` — pure formatter, no engine deps).
6. Compute MP cost (sum of `plot:GetMovementCost()` for each step).
7. Detect embark transitions (land → water boundary in path) — speak
   "Requires embark" if any.
8. Speak: "Path: {step list}. {N} MP. {turns to arrive}." Where
   turns = ceil(total MP / unit's max MP per turn).

**Move-completion announce** (same listeners as Phase 1):

- `Events.UnitMoveComplete` fires per-tile during traversal
- Final announce: "Moved {step list}. {N} moves remaining at {final
  tile description}."
- If unit stopped short of target (ran out of moves, enemy
  intercepted): "Stopped short at {tile} — {reason}."

### Path data structure (cross-phase)

Define a shared `PathInfo` table that Phase 2 produces and
announces:

```
{
  steps = { {direction = DIR_NE, count = 3}, {direction = DIR_E, count = 2} },
  mpCost = 5,
  turns = 1,
  embarkNeeded = false,
  warDeclareNeeded = false,
  destX = 23, destY = 14,
  reachable = true,
  failureReason = nil,  -- "unreachable" / "stacking" / "war required"
}
```

`UnitMovement.previewPath(unit, destX, destY)` returns this. Both
Phase 1 (single-hop) and Phase 2 (multi-hop) consume it.

## Phase 3: Research (tech tree + civic tree)

Both trees are mouse-driven in vanilla Civ VI. Player needs to:
- Choose current research from a list (visible techs)
- See research cost in turns
- See what each tech unlocks

### Civ V Access reference

- Civ V Access has tech-tree access via screen-reader navigation
  (different system than Civ VI's web-of-techs)
- Look at: `C:\dev\Civ-V-Access\src\dlc\UI\InGame\` for tech / civic
  related files (grep for "Tech" or "Research")

### Civ VI engine

- `Game.GetTechs():GetActivePlayerData()` (or similar) — current
  research, queue, etc.
- `pPlayer:GetTechs():GetResearchingTech()` — what's being researched
- `pPlayer:GetTechs():GetResearchQueue()` — queue
- `pPlayer:GetTechs():SetResearchingTech(techType, additionalCost)`
  — set what to research
- `GameInfo.Technologies[techType]` — name, description, cost
- `pPlayer:GetTechs():GetResearchProgress(techType)` — progress
- `pPlayer:GetTechs():GetResearchCost(techType)` — total cost in
  science
- Visible / researchable check: `pPlayer:GetTechs():CanResearch(
  techType)`

### UI port

Shadow `Base/Assets/UI/Civics/CivicsTree.lua` and `TechTree.lua` (or
the equivalent — check Civ VI install paths). Add a BaseMenu wrap
that:

1. Lists all techs/civics with their visible state (researchable,
   locked, completed).
2. Arrow-key navigation through the list.
3. Enter to select as current research / queue.
4. Speech: "{tech name}. {cost} science. {turns to research at current
   yield}. Unlocks: {units / buildings / abilities}."

Alternative simpler approach: hotkey to speak "Choose research" list
without opening the tree. Use Civ VI's notification "Choose new
technology" as the trigger — when it fires, our handler can open a
modal list of researchable techs and let the user pick via arrows.

### What "research is accessible" means

- Player can hear what they're currently researching + progress +
  turns left
- Player can hear what's available to research next
- Player can pick a new research target
- Same for civics

### Out of scope for Phase 3

- Tech tree visualization (no need to "see" the web)
- Eureka / inspiration triggers (announce when they fire; that's
  notification-handler work, see existing NotificationAdded)
- Research overflow handling (Civ VI quirk; one-line fix later)

## Phase 4: City production

Each city has a production queue. Player needs to:
- See current production
- See what's available to build (units, buildings, districts, wonders)
- See cost in production / gold
- Pick what to build next

### Civ V Access reference

- File pattern: `CivVAccess_City*.lua` in Civ V Access — read the
  city production / build queue access pattern
- Civ V's city production was simpler (no districts); the UX
  pattern still ports

### Civ VI engine

- `pPlayer:GetCities()` → city list
- `pCity:GetBuildQueue()` — current queue
- `pCity:GetBuildQueue():CurrentlyBuilding()` — what's being built
  now
- `pCity:GetBuildings()`, `pCity:GetDistricts()` — already-built
- Production options: iterate `GameInfo.Units`, `GameInfo.Buildings`,
  `GameInfo.Districts`, `GameInfo.Projects` and check
  `pCity:GetBuildQueue():CanProduce(productionHash)` for each
- Set production: `pCity:GetBuildQueue():CreateIncompleteBuild(
  productionHash, false)` or similar (verify API)

### UI port

Two parallel things:

1. **City selection** — when player selects a city (via mouse-click
  in vanilla, or via our HexCursor + Enter, or via NextCity engine
  action which is bound to ` (backquote) by default), speak the
  city name + population + current production + turns to complete.
  Already done in `ScreenReaderEventHandlers.OnCitySelectionChanged`
  for name + pop; extend to include production.

2. **Production picker** — shadow the city production panel UI (find
  the file — likely `Base/Assets/UI/ProductionPanel.lua` or
  `CityPanel.lua`). Wrap with BaseMenu. Categorize: Units / Buildings
  / Districts / Wonders / Projects. Arrow-nav within category, Tab
  between categories. Enter to commit selection.

### What "city production is accessible" means

- Player can hear what each city is currently producing + when it
  finishes
- Player can pick what to build next from a categorized list
- When a production completes, notification fires (already handled
  in 0.4.1) — but currently you can't pick the NEXT thing without
  the production picker

### Out of scope for Phase 4

- District placement (mouse-only tile picker; this is hard, deferred
  to a later movement-style "target mode" for districts)
- Wonder placement (same)
- Multi-item build queue management (basic single-item picker first;
  queue editing later)

## Sequencing within this arc

**Reordered 2026-05-23** after shipping 0.5.0 surfaced a hard block:
pressing Enter after founding a city routes to `ENDTURN_BLOCKING_
PRODUCTION` → opens the production panel → mouse-only modal trap →
Alt+F4 is the only escape (Noel confirmed in play). The original
plan put production at 0.5.3, but turn 1 can't END without it, so
the play loop never actually closes. Reorder pulls production
forward to 0.5.1.

1. **0.5.0 — Movement Phase 1** (Alt+QAZEDC direct-move). **DONE
   2026-05-23.** Single-hex commit, HexCursor follow, combat
   deferred. Ships with a defensive orientation hint warning that
   end-of-turn isn't reachable until 0.5.1. 0.5.0 also intercepts
   the `CHOOSE_CITY_PRODUCTION` notification routing so users
   don't get trapped in the mouse-only panel — the blocker stays
   active (turn can't end), but the modal evaporates with a
   spoken explanation.
2. **0.5.1 — City production** (basic flat-list picker). The
   play-loop-closing release. Without this, every session strands
   at turn 1. Scope is intentionally minimal: a single sorted list
   of buildable units / buildings (not the categorized panel with
   districts and wonders), Enter commits via `BuildQueue:Create
   IncompleteBuild`. District tile-placement stays deferred to a
   later arc. Once 0.5.1 ships, 0.5.0 + 0.5.1 together = "can play
   turn 1 end-to-end."
3. **0.5.2 — Research access** (tech tree + civic tree pickers).
   Same pattern as production: BaseMenu wrap over the engine's
   `pPlayer:GetTechs()` / `GetCulture()` data, simpler than
   production because there's no district / placement dimension.
4. **0.5.3 — Movement Phase 2** (target mode + path preview).
   Multi-hex routes / pathfind preview. Pushed from 0.5.1 to last
   because single-step movement already works for turn 1 play;
   multi-hex is enhancement, not blocker-removal.

Each version is a tag + release just like 0.4.1. Each is testable
as a self-contained increment. 0.5.0 commits as a checkpoint
without a tagged release until 0.5.1 closes the loop.

## Open questions for resolution before each phase starts

**Phase 1**:
- What's the right hotkey to "stop and reselect another unit" if the
  user wants to switch from the Settler to the Warrior? Tab works
  for cycling but unreliable per round-10 findings. May need our own
  `CIVVIACCESS_NextUnit` action with Alt+N or similar.

**Phase 2**:
- Do we support queued multi-turn moves in 0.5.1 or punt to 0.5.5+?
  Recommendation: punt — single-turn target mode is the 90% case for
  early game.
- War-declare popup handling: Civ V Access has `DeclareWarPopupAccess`.
  Civ VI has its own popup. Phase 2 detects + speaks "Move requires
  declaring war on {civ}. Press Y to confirm or N to cancel." — but
  the underlying popup may not be keyboard-accessible. Could be
  Phase 2 work OR another popup-access task.

**Phase 3**:
- Tech tree shadow vs. simpler list picker? Recommendation: simpler
  list first; tree visualization is sighted-UI territory anyway.
- How to handle the eureka system (research boost triggers)?
  Already announced via NotificationAdded; the player understanding
  what triggered the boost is harder. Defer to polish round.

**Phase 4**:
- Production queue editing in 0.5.3 or later? Recommendation: later.
  Single-item picker first.
- District tile-placement is the biggest UX challenge — a "place
  this district on a tile" picker that uses HexCursor + Enter. Defer
  to 0.6.x.

## How to resume in a fresh context

1. Read this doc end-to-end.
2. Read `docs/TESTING_NEW_GAME_FLOW.md` Fix Log for the 14-round
   journey that produced 0.4.1 — many gotchas listed there will save
   debug time.
3. Read `MEMORY.md` and follow links to:
   - `reference_civ_v_access` — the architectural reference
   - `reference_civ_v_access_terminology` — submenu / toggle / etc.
   - `feedback_civ_v_access_is_local` — read locally, don't fetch
   - `project_04_in_game_plan` — the trajectory this plan extends
4. For each phase, FIRST read the named Civ V Access source files
   directly, THEN write the Civ VI port. Don't reinvent.
5. Bump version + write CHANGELOG entry + commit + tag per the
   0.4.1 pattern (see commit `3639df7`).

## What this plan explicitly does NOT cover

- Combat (attack, ranged attack, melee odds, AOE) — deferred
- Diplomacy (other civ leaders, deals, war/peace) — deferred
- World Congress / Diplomatic Victory mechanics — deferred
- Religion mechanics — deferred
- Espionage — deferred
- Era / Age transitions speech — deferred
- Victory progress / endgame screens — deferred
- Civilopedia keyboard access — deferred
- Trade routes — deferred
- Great People recruitment — deferred
- Multiplayer turn-timer + chat — deferred
- Tutorial advisor popups beyond FIRST_GREETING — engine state
  persistence makes this hard; address when player-profile reset
  is solved

All of the above are real features that need accessibility work
eventually. They're not in this arc because they don't gate "can
play a peaceful builder game start to finish." This arc is about
unblocking that single play loop.
