# Spatial Awareness — the three-tier map loop

Noel's framing 2026-05-31: the early/exploration game is a **sense → locate → act**
pipeline, where each tier's output feeds the next. This is the playability unlock
after Group B — it makes "play a turn fluently on the map" real. Build order is
NOT the experience order (see below).

The pipeline:
- **Tier 1 — REVEAL ANNOUNCE (awareness).** As fog lifts, summarize what was
  uncovered: "Uncovered 6 hexes: 4 hills, 2 rainforest." Produces a mental map.
- **Tier 2 — SCANNER (locate).** Turn awareness into a concrete target: cycle/find
  the nearest feature ("nearest hill, 3 hexes northeast") and drop the hex cursor
  on it. Output = a specific hex.
- **Tier 3 — ROUTES BUILDER (act).** Take a hex (from the scanner or the cursor),
  pathfind, hear the preview ("3 turns, through forest, ends next to the city"),
  confirm, engine auto-paths multi-turn until arrival. Plus a little brother:
  auto-explore a unit. See [[project_routes_builder]] for the full prior-art notes.

The scanner's output (a hex) is literally the routes builder's input — it's ONE
system with three verbs, not three features.

## Build order: TIER 1 → TIER 3 → TIER 2 (Noel's call 2026-05-31)
Experience order is 1→2→3, but build order differs:
- **Tier 1 first** (Noel's pick) — you explore blind otherwise; also the cheapest
  (passive, fires on fog reveal). Ship awareness before locomotion.
- **Tier 3 next** — the headline fix ("move a unit to a city," Noel's stated pain).
  Works standalone against the existing hex cursor (no scanner needed yet).
- **Tier 2 last** — the scanner becomes most useful once you can both perceive
  (tier 1) and travel-to (tier 3) a target; it's the glue between them.

## Shared primitive (build ONCE, reuse across tiers)
"Describe what's at a hex" — terrain + feature + resource + improvement + units +
distance/direction from a reference. Tier 1 summarizes many hexes' worth, tier 2
reads the located hex, tier 3's route preview describes the destination + path
stops. We ALREADY have ScreenReaderPlotUtils.lua + HexGeom.lua (pointy-top
6-direction math) — this primitive likely lives there or extends it.

## What we already own (don't rebuild)
- **HexCursor.lua** — navigate the map by hex, the cursor that tier 3 reads a
  destination from and tier 2 parks on a found target.
- **HexGeom.lua** — pointy-top hex math, strict 6-direction vocab
  ([[hex-grid-navigation]]). Distance/direction for "3 hexes northeast."
- **UnitMovement.lua** — Alt+QWEADZXC one-hex nudges; already drives
  RequestOperation(MOVE_TO) + filters UnitMoveComplete by (player, unit). Tier 3
  is the destination-pathing wrapper AROUND this, not a replacement.
- **ScreenReaderPlotUtils.lua** — plot description; the seed of the shared primitive.
- **UnitInfo.lua** — unit state readback.

## Static terrain vs dynamic weather — two announce categories (Noel 2026-06-01)
Don't conflate them. **Terrain** (snow/tundra/desert/grass…) is PERMANENT base-game
map data — Tier 1 tallies it, Tier 2 scans it. Polar **snow/ice** doubles as an EDGE
landmark ("you're near the top of the map"), like coast marks the water edge — a free
orientation anchor for the scanner. **Gathering Storm weather** (blizzard, sandstorm,
hurricane, flood, drought, volcanic eruption) is a DYNAMIC event layer that plays out
*on top of* terrain — transient, moves, damages units. GS adds it; it does NOT replace
the snow terrain. So weather needs TIME-SENSITIVE event announces (storm approaching /
unit in path / flood incoming), NOT the static scan path. Foothold already exists:
`NaturalDisasterPopup.lua` (blizzard/flood/hurricane/sandstorm/tornado/volcano/drought
popups) — in the reveal family's "built but not parity-audited" bucket; needs a pass.

## TIER 1 — reveal announce (build first)
- **Event (VERIFY exact name at build):** a fog/visibility-change engine Event.
  Candidates: `Events.LocalPlayerChangedVisiblePlots`, or a per-plot
  visibility-changed event. Confirm signature (likely hands a LIST of plot indices
  newly revealed) before building — grep Base UI + FireTuner. NOT yet pinned.
- **FIREHOSE RISK (design in, not bolt on):** a scout crossing open ground reveals
  many hexes per move. Per [[feedback_terse_announce_default]], tier 1 = COALESCED
  SUMMARY per move ("uncovered 6 hexes: 4 hills, 2 rainforest"), NOT per-hex
  narration. Tally terrain/feature counts across the revealed batch, speak one line.
  Consider: detail-on-demand key for the full list; a verbosity gate; maybe a
  threshold (don't announce 1-2 routine hexes, do announce notable features —
  resources, natural wonders, rivers, another civ's border).
- **Output:** the awareness layer. Read-only, no commit.

## TIER 3 — routes builder + auto-explore (build second)
- **Preview (read-only):** `UnitManager.GetMoveToPathEx(unit, endPlotId)` →
  `pathInfo.plots` (ordered plot IDs) + per-turn boundaries (WorldInput.lua:961
  draws the path this way; `UI.AddNumberToPath(turn, plotId)` tags turn counts).
  Speak: turn count + terrain summary + end-tile description + fog/embark/combat
  hints. Civ V Access bound this to **Space** (preview to cursor).
- **Commit (multi-turn is FREE):** `UnitManager.RequestOperation(unit, MOVE_TO,
  {PARAM_X, PARAM_Y})` to a DISTANT hex already auto-paths across turns natively;
  `GetQueuedDestination(unit)` reads the standing destination, the engine resumes
  each turn until arrival. So "multi-turn" = ride the engine queue + ANNOUNCE
  progress ("moving to destination, 2 turns remaining" on turn begin), NOT writing
  a turn-by-turn mover. Civ V Access: **M** = move-to.
- **Auto-explore little brother:** auto-explore is an existing engine action (one
  of the silent engine-bound hotkeys, [[project_announce_engine_actions]]). "Build
  a scout, set it exploring" is mostly an ANNOUNCE problem (expose the action +
  speak state), riding the same infra. Civ V Access: Ctrl+A toggles automation.
- **Engine constraints (learned via rock-band walk, [[reference_civ_vi_vm_split]]):**
  can't MOVE_TO an enemy city CENTER (target adjacent hex); PlaceUnit refuses
  foreign territory (walk in). Guards: `UI.IsGameCoreBusy()`, `UI.IsMovementPathOn()`.
- **VERIFY at build:** exact `GetMoveToPathEx` return shape + how per-turn
  boundaries are encoded; how to read "turns remaining" for the progress announce.

## TIER 2 — scanner (build last)
- Cycle/find map features relative to a reference unit/cursor: nearest hill, river,
  resource, enemy, city, unexplored edge, etc. Reuses the shared describe-hex
  primitive + HexGeom distance/direction. Parks the hex cursor on the found target
  → which tier 3 then reads as its destination. Port the surveyor/scanner patterns
  from Civ V Access ([[reference_civ_v_access]], [[reference_civ_v_basemenu_pattern]]).
  **RE-READ FRESH BEFORE BUILDING (2026-06-01):** Civ V Access **v1.2.0** overhauled the
  scanner/surveyor — new **Geography category** (landmasses/oceans,
  CivVAccess_ScannerBackendGeography.lua ~307 LOC), **Scanner Favorites**
  (CivVAccess_ScannerFavorites.lua ~381 LOC — save/bookmark scan targets, converges with
  [[project_map_pins_feature]] + [[board-query-navigable-list]]), river-tile count in the
  surveyor, plus sighted-player highlights. Port from the v1.2.0 code, NOT the older model.
- **Natural wonders are a scan category** (Noel 2026-06-01). They're just map
  features (FeatureType, IsNaturalWonder) on known plots once revealed — the scanner
  FINDS them, we don't place anything. Fog-gated: only scannable once discovered.
  "Nearest natural wonder, 4 hexes northeast" → park cursor → route there (Tier 3).
  Pairs with the discovery popup (Tier 1): the popup is the WHAT-you-found moment,
  the scanner is the go-back-to-it later. **Idea: auto-drop a map pin
  ([[project_map_pins_feature]]) on discovery** so a wonder becomes a permanent
  navigable landmark — bridges the discovery moment to persistent recall
  ([[bonus-recall-empire-reader]]). NB you can't settle/build ON a wonder tile, so
  the routing target near one is an ADJACENT settle/work hex, not the wonder itself.

## Board-query "sweep" probe — graduation notes (live re-test 2026-06-01)
The throwaway BoardQueryProbe (the macro "sweep" register) re-ran with the tuned
wording and worked: *"Open grassland and plains sweeping from south to southeast, 8
tiles out, 224 tiles in total area, room for about 16 cities, river through it.
Resources: 16 kinds including Aluminum, Bananas, Cattle."* Engine recs: *"southeast, 2
tiles. Close to a friendly site."* Two-register model CONFIRMED live: the sweep reads
the MACRO opportunity (the big southern frontier), the engine recommendations answer
"where does THIS settler go *now*" (close + loyalty-supported) — complementary, not
contradictory. The play falls right out: settle the close rec now, pump settlers south
into the frontier before a neighbor claims it.

Fixes for when the probe graduates to a shipping feature:
- **Pluralization:** "1 tiles" → "1 tile / N tiles". Trivial.
- **Recommendations speak TERRAIN + FRESH WATER (done in probe 2026-06-01).** They used
  to give only direction + distance + "close to a friendly site" — Noel had to inspect
  each hex by hand to learn it was plains-hills / plains-wheat. `siteDescriptor(tx,ty)`
  now appends terrain + feature + a water cue ranked the way the engine's own
  AssignStartingPlots does: **on a river → fresh water → coastal → no fresh water** (that
  last is the load-bearing NEGATIVE cue). So a line now reads "southeast, 2 tiles, Plains
  Hills, on a river. Close to a friendly site." Real version: same descriptor per list
  item ([[board-query-navigable-list]]).
- **Resource bucket still ALPHABETICAL** (Aluminum/Bananas/Cattle) — rank STRATEGIC >
  LUXURY > BONUS for the real version (per [[board-query-design-2026-05-31]]).

## Scanner ↔ sweep convergence (Noel's worked example, 2026-06-01)
Noel's flow that ties Tier 2 to the sweep and into Tier 3: *"open the scanner, select
'river', it lists several river sites with distances; with a unit selected, start
walking that way."* That's the Civ V Access scanner flow, and it produces the SAME
shape of output the sweep + engine recs already do (feature + distance + direction). So
the scanner (Tier 2) is the per-FEATURE query (rivers, hills, resources) and the sweep
is the per-REGION query — one describe-hex + HexGeom primitive, one hand-off into Tier
3 (selected unit walks to the chosen hex). Build the scanner so a found site feeds the
routes builder directly: park hex cursor on it → Space preview → M move.

## Results as a navigable LIST — the drill UI (Noel 2026-06-01)
Don't read the whole board-query result as one announce — put it in an **arrowable list
box**. Arrow up/down through candidate hexes (city sites, land blocks, fog, wonders,
pins); each item self-reads on focus (label + direction + distance); the list scrolls;
**Enter sends the selected unit moving to that hex** (or parks the HexCursor if no unit
is selected). This is the DRILL register ([[board-query-design-2026-05-31]]) realized,
and it FUSES Tier 2 (list items = located targets) with Tier 3 (Enter = MOVE_TO) — the
scanner's output stops being a separate step from the routes builder. The city-site data
already exists (BoardQueryProbe speaks GetSettlementRecommendations today); the build is
turning it into list items. Reuse the ChoosePopupAccess picker; HexCursor follows focus;
map pins join the same list. The SWEEP one-liner still stands as the quick urgency read —
the list is the precise-interrogation complement, not a replacement. Full notes:
[[board-query-navigable-list]].

## Testing
Each tier needs LIVE play to verify (move blind, reveal fog, path a unit). Speech
goes to Lua.log (`#SCREENREADER[...] - <words>`, ScreenReader.lua:230) so the SPOKEN
strings are log-readable — but input-leak / map-side-effects are ear-only. Build
against a live game; Noel triggers, Claude reads the log
([[government-access-2026-05-31]] proved this loop).

Related: [[project_routes_builder]], [[playability-pivot-2026-05-31]],
[[hex-grid-navigation]], [[project_map_pins_feature]] (pins as named destinations),
[[project_design_directions]], [[04-in-game-plan]], [[playable-basics-arc]].
