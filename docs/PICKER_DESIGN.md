# Picker Design — Production / Tech / Civic

Locked design and execution queue for the picker arc that closes
0.5.1 (production picker) and seeds 0.5.x (tech + civic pickers).
Conversation 2026-05-26 with Noel converged the picker UX; this doc
captures decisions, open questions, and a serial work queue so the
implementation can run end-to-end without per-step approval.

Supersedes the Phase 4 section in `docs/PLAYABLE_BASICS_PLAN.md`.

## Status

Updated 2026-05-26 evening — picker is functional end-to-end for the
Produce tab. Shipped: shell + nav, entry construction (units /
districts / buildings / wonders / projects), disabled-with-reason
labels, turn counts on labels, commit via CityManager.RequestOperation,
prev/next-city cycle (comma/period), Ctrl+T long-form expansion via
ToolTipHelper, kind-aware commit verb. Open: Gold + Faith tabs (Stage
3), queue editing (J'), tile placement (K/L), advisor linkage (P).

Bugs found and fixed along the way: pPlayer:GetCityByID is
gameplay-VM-only and silently throws in UI VM (use Members iteration
instead); Civ VI's UITutorialManager/tutorial gating was NOT the
buildings-empty culprit — it was Trajan's "Trajan's Column" leader
ability pre-building a Monument; UI.SelectCity is required before
CanProduce queries return truthful results on a non-head-selected
city; closing the picker requires UI.DeselectAllCities + InterfaceMode
reset to escape city view ("Hotel California" fix); UI VM
.GetHeadSelectedUnit lags UnitSelectionChanged so cycle-to-self
detection needs deferred-batch counter rather than direct ID compare.

| Item | State |
|---|---|
| Nav model | Locked |
| Tab structure | Locked |
| Group structure | Locked |
| Per-item label token order | Locked |
| Tile placement flow | Locked (sub-flow K/L deferred) |
| Entry-point | Locked (Shift+P direct + notification-activation pending) |
| Advisor linkage | Locked (P task pending) |
| Speech-clobber fix | Shipped |
| Wonder size + 3-best-site scoring | Open |
| Bookmarks before picker? | Per existing roadmap (after picker) |

## Architectural decisions

- **BaseMenu modal**, not WebView2. Picker is structured-list nav,
  not document nav; BaseMenu handles it. WebView2 stays reserved for
  the EOT report (real document content with paragraph / sentence /
  word nav via the screen reader's browse mode).
- **Build in `CivViAccess.exe` / mod first.** Don't extract to CAMM
  yet. Promote later if Factorio Access or another adopter shows up
  needing a picker primitive.
- **No new framework abstractions.** Picker is one screen with three
  layers of nav (tab, group, item). Three layers earns its own
  conventions (see Nav model); we don't need a generic three-layer
  primitive in BaseMenu until a second screen wants the same shape.
- **Standalone modal Context, not engine ProductionPanel wrap.**
  Civ V Access intercepted the engine's CHOOSEPRODUCTION popup; we
  build our own modal opened via `UIManager:QueuePopup`. Two reasons:
  (a) Civ VI's ProductionPanel is a slide-out side panel, not a
  modal, so wrapping it doesn't cleanly fit the BaseMenu pattern;
  (b) "blind-first" principle — our picker IS the production UI
  for blind players, not an overlay on top of the sighted one. On
  picker open we hide the engine ProductionPanel; on close we
  unhide. Per Noel 2026-05-26.
- **Sighted-mode coexistence (per-turn gate).** Per
  [[project-sighted-mode-per-turn]], hotseat / MP players are
  per-player-mode: Noel = blind, Julian = sighted, mode flips at
  turn boundary. When the sighted player is on turn, the picker
  MUST NOT auto-open on notification activation, and the engine's
  ProductionPanel MUST stay visible. The picker module's `open()`
  function will check the local player's mode before proceeding;
  if sighted, no-op (the engine's standard production flow takes
  over). Stage 2 wires this gate; Stage 1 is single-player blind
  testing only.

## Nav model

Three layers of nav. Convention:

- **Tab nav** (Produce / Gold / Faith): `Tab` (forward), `PageUp` /
  `PageDown` (backward / forward). Matches Game Options + AdvancedSetup.
  `Ctrl+Tab` deliberately NOT used — observed broken in Game Options
  earlier in development.
- **Group nav** (Units / Districts / Buildings / Wonders / Projects
  / Queue): `Shift+PageUp` / `Shift+PageDown`. Slurp/burp confirmed
  2026-05-26 — Shift modifier preserved on PageUp / PageDown KeyDown
  events (only `Shift+Tab` is unreliable in Civ VI's input system).
- **Item nav**: `Up` / `Down` arrow within the current group.
  `Home` / `End` for first / last item in the focused tab.
- **Activate**: `Enter`, `Space`, or `Shift+Enter` all commit. Three
  welcoming ways, not confusing.
- **Close**: `Esc`.
- **Item detail**: `Ctrl+T` reads the long-form expansion (advisor
  reasoning, yield deltas, boost relevance, prerequisites,
  disabled-reason).

Group structure is **flat-with-headers**, not drill-in. One long list
per tab, group headers announced as you cross them with Shift+PgUp /
Shift+PgDn (or arrow past the boundary). Justification: 18 sections
total (3 tabs × 6 groups) would be heavy with drill-in modality.

## Tab structure

Three tabs:

1. **Produce** — items the city can build with hammers.
2. **Gold** — items the city can rush-purchase with gold.
3. **Faith** — items the city can faith-purchase (Apostles, Holy
   Site buildings, some wonders depending on religion).

Tabs that have zero items in the current city auto-hide (no Faith tab
if the city has no faith income / no faith-purchasable items). Tab
strip announce: "Produce tab, 24 items" / "Gold tab, 8 items" / etc.

Initial tab on open: Produce by default. Notification-driven open
respects what the notification asked for (production-complete
notification opens Produce; Faith-amassed notification could open
Faith).

## Group structure

Six groups per tab:

1. **Units** — military, civilian, settler, builder, religious, support.
2. **Districts** — Civ VI's defining category; Civ V doesn't have
   these. Limited by population, require tile placement.
3. **Buildings** — buildings buildable in already-placed districts.
4. **Wonders** — global + national wonders. Require tile placement.
5. **Projects** — Spaceport projects, Carnival, Naval Tradition,
   policy-card-tied projects.
6. **Queue** — read-only display of current build queue (up to N slots).

Order is fixed across all three tabs for consistency: Units →
Districts → Buildings → Wonders → Projects → Queue.

A group with zero items still announces its header ("Districts,
none available") so the nav structure stays uniform.

## Per-item label token order

Standardized so the user can predict what each token slot says:

```
{name} — {turns or cost} — {boost relevance} — {advisor flag} — {disabled-with-reason}
```

Examples:
- `Library — 8 turns`
- `Granary — 6 turns — completes Pottery boost`
- `Holy Site — 12 turns — advisor recommended`
- `Industrial Zone — 14 turns — disabled, requires Apprenticeship`
- `Settler — 280 gold` (in the Gold tab)

Boost relevance only appears for items that complete a Eureka or
Inspiration boost for tech / civic the player hasn't yet acquired.

Advisor flag only appears if `Game.SetAdvisorRecommenderCity(city)`
returns this item as recommended for THIS city.

Disabled items are still shown (skim-able) but their label includes
the reason. Engine's `CanTrainTooltip` / `CanConstructTooltip` /
purchase variants supply the human-readable reason.

## Ctrl+T expansion contract

For each focused item, `Ctrl+T` reads:

1. Full description (engine's `Description` field, LOC-resolved).
2. Yield delta this would provide ("+2 production per turn, +1
   science per Library").
3. Boost relevance, expanded ("Building this would complete the
   Pottery Eureka, granting 50% of the Pottery research immediately").
4. Advisor reasoning if advisor recommended ("Economic advisor: this
   city has low production output and would benefit from an
   Industrial Zone").
5. Prerequisites if any ("Requires Bronze Working").
6. Disabled reason if any (engine's tooltip string).

`Ctrl+T` is the standard long-form key across the mod; no exceptions
here.

## Tile placement sub-flow (districts + wonders)

When the player commits a district or wonder, the picker closes and
hands off to a placement sub-flow rather than the sighted "free-walk
the map looking for legal tiles" pattern.

**Wonder placement** (Noel locked 2026-05-26):
1. Speak the wonder's size requirement ("Hanging Gardens, plains
   tile required, 3 viable sites in your borders").
2. Present the top 3 candidate sites by quality score (yield delta
   + adjacency bonus + proximity to city center).
3. Each candidate is one list item: "Site 1: 2 hexes SE of city
   center, plains adjacent to river" / etc.
4. `Enter` commits, `Esc` cancels back to the picker.
5. If zero viable sites: speak "No viable sites in your borders.
   Purchase cancelled. Explore to find new terrain." The player has
   to explore first before this wonder is available again.

**District placement**: same shape as wonder, but the candidate list
can be longer (districts have many more legal tiles). Show top N by
quality (open: 3, 5, or 7?). "Show all viable sites" expansion key
TBD.

**Quality scoring** (open design):
- Yield delta from this district / wonder (adjacency bonuses,
  appeal, etc.)
- Distance to city center (closer is generally better for working)
- Whether the tile has a resource or feature that placement would
  destroy (negative weight)
- Whether the tile is currently being worked by a citizen (negative
  weight)

Locked: quality scoring is the right ordering principle. Open: exact
weight tuning, default candidate count, "show all" hotkey.

## Entry-point flow

Notification-center driven, not auto-pop. Consistent with the
blind-first design principle and the EOT-report pull-when-ready
direction.

1. City needs production (founded, completed an item, queue
   exhausted) → engine fires `NOTIFICATION_PRODUCTION` with a
   distinct earcon.
2. Player navigates to that notification with the notification
   center (bare `[` / `]` cycle).
3. Activating the notification (Space or Enter on the focused
   notification) opens the picker for THAT city.
4. Picker opens with the city's name + population + yields read as
   preamble (mirrors Civ V Access pattern).

The tutorial should teach the notification-center pattern as the
canonical way to handle pending decisions. See
[[project_tutorial_accessibility_goal]].

## Advisor notification linkage

Every "advisor wants to speak" moment becomes a notification of a
dedicated type with its own earcon. Pattern (Noel locked 2026-05-26):

1. Advisor has a recommendation → fire
   `NOTIFICATION_ACCESSIBILITY_ADVISOR` (new type, our addition) with
   the advisor's headline.
2. Activating the notification reads the advisor headline + plays
   A/V if engine has voiceover (tutorial advisor has voiceover;
   production advice is text-only in engine data — TTS-voicing the
   text is a v0.6.x stretch).
3. `Ctrl+T` while the notification is focused expands to full
   reasoning.
4. Reasoning is stored on the player's session-state object keyed by
   `(city, item, advisor)`.
5. Picker's `Ctrl+T` handler on each item looks up the same store —
   advisor reasoning attached to that item is replayed.

Result: cross-referenced advisor content, no forced interruption,
player decides when to consume advisor advice.

## Notification dismissal contract

Engine already exposes per-notification `CanUserDismiss()`; our
notifications module already reads it (Notifications.lua line 303).
Missing piece: user-facing dismiss action.

- **Delete** key on a focused notification:
  - If `CanUserDismiss = true`: engine + our center both forget it.
    Announce "dismissed."
  - If `CanUserDismiss = false`: announce "Cannot dismiss. {reason}"
    where {reason} is what's blocking ("This is an end-turn
    blocker", "Must be resolved first", etc.).
- Sticky / blocker notifications stay until the action is resolved;
  no "mark as read but keep showing" option (would defeat the
  purpose of a blocker).

## Tech and civic pickers — extension

Same nav shape as production picker. Smaller scope (no district
dependencies, no tile placement, no purchase tabs).

**Tech picker** (R = Research, or via notification):
- One tab. No Produce / Gold / Faith split.
- Groups: Available now (no prereqs missing) / Locked (one or more
  prereqs missing) / Already researched.
- Per-item label: `{name} — {turns to research} — {boost status}`.
  Boost status: "boosted" if Eureka completed, "boost available
  via {action}" if Eureka completable, blank otherwise.
- `Ctrl+T` reads description, prerequisites, what units / buildings
  / districts this unlocks.

**Civic picker** (C, or via notification):
- Same shape as tech picker.
- Per-item label includes "envoy on completion" if civic grants one.
- `Ctrl+T` adds policy unlocks.

Both pickers share the same per-item label format conventions as
production, just with fewer slots populated.

## Resolved questions (locked 2026-05-26)

1. **Wonder candidate count** — **scale to wonder footprint.** Each
   wonder declares its terrain requirements; iterate legal tiles and
   present min(top-3-by-quality, all-legal-tiles). A wonder with only
   2 legal tiles shows 2; one with 50 legal tiles shows top 3.
2. **District candidate count** — **scale to district type.** Same
   shape: min(top-N-by-quality, all-legal-tiles). N defaults to 5 for
   districts (most have more options than wonders); Aqueduct will
   show fewer because few tiles qualify, Holy Site shows 5.
3. **"Show all viable sites"** — **last item in the candidate list
   reveals it.** After "Site 3" (or "Site 5"), the list ends with a
   "Show all N sites" entry that, when activated, expands the list
   to include every legal tile sorted by quality. No new hotkey;
   discoverable via arrow nav. Backs out with Esc to the trimmed
   list.
4. **Faith tab** — **auto-hide** if the city has no faith income or
   no faith-purchasable items.
5. **Queue editing** — **IN scope for 0.5.1.** Promoted from
   out-of-scope per Noel's "if you can do it visually, I'd like to
   do it." UX: when focused on a queue item, Enter enters
   move-position mode; speech says "Library, slot 3 of 5. Type 1
   through 5 to move." Digit press commits, Esc cancels.
   `Delete` removes the queue item entirely. See queue item J' below.
6. **EOT report integration** — **Esc closes EOT, picker stays
   open.** Noel: in-game playtest will validate. Treat this as the
   default and revisit if it feels wrong.

## Execution queue

Serial work units. Each is sized to be a single commit (small
batches were the rule until 0.5.0; bigger batches are fine now per
Noel's "queue more, fix less" preference). Execute top-down without
per-step approval unless something genuinely blocks.

### A. Speech-clobber fix (pre-picker, blocks UX)

"Warrior fortify" got stomped by "ready for next turn" during today's
rest-cascade test. Same class of bug will affect "Library, 8 turns"
when the picker activates an item that satisfies an end-turn blocker.
Fix first.

**Plan**:
1. Trace the "ready for next turn" announce path — find what fires
   it. Likely `TurnAnnouncements.lua` or a subscriber to
   `Events.EndTurnDirty` / similar.
2. Either delay the ready-for-next-turn announce by N ms after
   `UnitOperationDeactivated` / `CityProductionCompleted`, OR give
   unit-action confirmations interrupt-priority so they preempt the
   queue.
3. Test with R on a Warrior — confirm "Warrior fortify" is heard
   before "ready for next turn."

### B. TurnAnnouncements.lua:55 runtime error

Log line 193–197 from today: `function expected instead of nil` at
`TurnAnnouncements.lua:55` in `announceTurnBegin`. Fires every
`TurnBegin` event. Likely an undefined helper or missing nil-check.
Read the file, fix the call site, deploy.

### C. Settler "researching pottery" misstitch

Speech path conflated civ-wide research with selected unit. Likely
in `ScreenReaderEventHandlers.OnUnitSelectionChanged` or a
post-selection summary. Investigation: find where "researching X"
is composed; ensure it's only attached to civ-level summaries, not
unit-level. Likely a one-line removal of an over-eager append.

### D. Unit cycle silence (Shift+./Shift+,)

Per `project_05_session_handoff_2026_05_24`: cycle-all fires per
log (action ids 98, 99) but Noel hears nothing. Hypothesis:
NOINTERRUPT queue race. Fix: ensure cycle confirmation speech is
interrupt-priority OR drain the NOINTERRUPT queue before pushing.

### E. "Only one unit" announce on cycle wrap

Today's session: Noel mashed cycle and didn't hear anything beyond
the Warrior. Should announce "only one unit" (or similar) when the
cycle target is the same unit as the current selection. Easy:
detect cycle-to-self in the cycle handler.

### F. Production picker — Bindings + entry point

1. Add `CIVVIACCESS_OpenProductionPicker` ActionId. Hotkey: TBD
   (bracket-friendly given notification center owns `[` / `]`;
   consider `P` since OnlinePause is on Alt+P now — bare `P` is
   used in vanilla for OnlinePause but our Alt+P rebind freed it).
2. Hook the production-needed notification → activating opens picker
   for that city.
3. From the picker, prev/next-city (`,` / `.`) cycles the picker
   target like Civ V Access does.

### G. Production picker — BaseMenu shell

1. Tab strip (3 tabs: Produce / Gold / Faith).
2. Flat-with-headers groups (6 groups per tab, headers as Text items
   between group boundaries).
3. Nav: Tab / PgUp / PgDn (tabs), Shift+PgUp / Shift+PgDn (groups),
   arrow (items), Enter (activate), Esc (close), Ctrl+T (long form).
4. Preamble: city name + pop + growth + current production + yields
   + status + defense (mirror Civ V Access).
5. Esc handling — match the pattern from
   `CivVAccess_ChooseProductionPopupAccess.lua` (modal Esc binding
   to handle popup-queued contexts).

### H. Production picker — Entry construction

Pure logic, testable offline. Port from
`CivVAccess_ChooseProductionLogic.lua`:

1. `buildUnitEntries(city, isProduce)` — iterate `GameInfo.Units`,
   filter by `city:CanTrain(id, 0)` (visibility) and
   `city:CanTrain(id, 0, true)` (strict), populate entries.
2. `buildDistrictEntries(city, isProduce)` — iterate
   `GameInfo.Districts`, filter by `city:GetBuildQueue():CanProduce()`.
3. `buildBuildingEntries(city, isProduce)` — same shape; separate
   wonder vs non-wonder via `MaxGlobalInstances > 0` or
   `MaxPlayerInstances == 1`.
4. `buildProjectEntries(city, isProduce)` — iterate
   `GameInfo.Projects`.
5. Sort each list by era-by-tech (Civ V parity) so the picker's
   item order mirrors the sighted production panel's layout.
6. Strip `[ICON_*]` markers from all labels via the standard helper.

### I. Production picker — Label composition

Per the locked token order. Compose `{name} — {turns or cost} —
{boost relevance} — {advisor flag} — {disabled-with-reason}` for
each entry, city-aware so refresh after prev/next-city cycle works.

Boost detection: iterate `Player:GetTechs():GetEureka()` and
`Player:GetCivics():GetInspiration()` to see which techs / civics
have boosts available and whether this item completes one.

### J. Production picker — Commit paths

1. **Produce tab commit**: `pCity:GetBuildQueue():CreateIncompleteBuild(
   productionHash, true)` (or whatever the actual API is; verify).
   For shift-click append: `CreateIncompleteBuild(hash, false)`.
2. **Gold tab commit**: `pCity:Purchase(YieldTypes.YIELD_GOLD,
   productionHash)` — verify exact API. Plays purchase sound.
3. **Faith tab commit**: same but `YIELD_FAITH`.

On any commit: speak confirmation, close picker (single-add mode) or
stay open with "added, slot N" speech (append mode).

### J'. Production picker — Queue editing (PROMOTED from out-of-scope)

When focused on an item in the Queue group:
1. `Enter` enters move-position mode. Speech: "Library, slot 3 of
   5. Type 1 through 5 to move."
2. Digit press (1–6, since queue cap is 6 in vanilla Civ VI)
   commits the move. Speech: "Library moved to slot N."
3. `Esc` cancels move-position mode without changing position.
4. `Delete` removes the queue item entirely. Speech: "Library
   removed from queue."

Engine API to verify: `pCity:GetBuildQueue():SetBuildQueueAt(slot,
hash)` or similar — need to find the actual reorder primitive.

### K. Production picker — Tile placement sub-flow (districts)

1. Detect commit of a district or wonder.
2. Close picker.
3. Compute top-N candidate sites by quality score (see Quality
   scoring above; N=5 for districts, scales down to count of legal
   tiles if fewer).
4. Open a flat list of candidates as a BaseMenu modal. Last entry
   is "Show all N sites" which expands to the full legal-tile list
   on activation.
5. Enter commits placement: `UnitManager.RequestOperation` or the
   district-placement engine API (verify).
6. Esc cancels back to picker.

### L. Production picker — Tile placement sub-flow (wonders)

Same shape as district sub-flow above but:
- Default N=3 (wonders are more constrained).
- If zero legal tiles: speak "No viable sites in your borders.
  Purchase cancelled. Explore to find new terrain." and cancel the
  commit so the wonder remains available to attempt later.
- "Show all" still appears as the last list entry when there are
  more than 3 legal tiles.

### M. Production picker — Tests

Offline tests for entry construction + label composition. Mirror
the structure of `tests/` if it exists; otherwise create
`tests/picker_logic_spec.lua` or similar.

### N. Tech picker

1. Same BaseMenu shell as production, single tab.
2. Three groups: Available / Locked / Researched.
3. Per-item: `{name} — {turns to research} — {boost status}`.
4. Commit: `pPlayer:GetTechs():SetResearchingTech(techHash)`
   (verify API).
5. Hotkey: TBD — `T` is taken by abilities reread; lean `Alt+T` or
   `Shift+T`. Resolve in implementation.

### O. Civic picker

Clone of tech picker. Per-item adds "envoy on completion" if civic
grants one. Hotkey: TBD — `C` collides with CursorSE. Lean
`Alt+C` or `Shift+C`.

### P. Advisor notification linkage

1. New notification type `NOTIFICATION_ACCESSIBILITY_ADVISOR`.
2. Subscribe to engine advisor recommendation events.
3. Fire our notification when advisor has new content.
4. Wire `Ctrl+T` in the notification center to expand advisor
   reasoning.
5. Wire `Ctrl+T` in the picker to look up the same reasoning by
   `(city, item, advisor)` key.

### Q. Documentation + memory updates

1. Update `docs/PLAYABLE_BASICS_PLAN.md` Phase 4 section to point at
   this doc.
2. Add memory entry summarizing locked picker design.
3. Update `project_pickers_and_reader_plan` memory entry: open
   questions → locked design, with link here.

## Implementation order rationale

A → B → C → D → E are bug fixes that block or degrade picker UX.
Fix first.

F → G → H → I → J are the production picker proper. Each is a
clean commit boundary.

K → L are the placement sub-flow — can be deferred to a follow-up
version (0.5.2) if 0.5.1 wants to ship the picker without district /
wonder placement first. In that case, committing a district shows
"District placement coming in 0.5.2; this commit queued the
district but it will not start building until you place it via
mouse" — pragmatic stopgap.

M is tests; can run in parallel with J / K.

N → O are the tech and civic pickers; deferred to 0.5.x post-0.5.1.

P is the advisor linkage; could be deferred unless the picker work
naturally pulls it in.

Q is the documentation pass at the end.

## Out of scope

- Multi-city batch production (set the same item across multiple
  cities in one action) — would be a powerful accessibility feature
  but defer to a later pass.
- Production from the Notifications panel (the picker IS the
  production UI from the notification panel; no second path).
- Eureka completion via the picker (player completes Eurekas
  through gameplay, not by selecting them in the picker).

Note: queue reordering / cancel was promoted INTO scope as item J'
per Noel's 2026-05-26 answer to open question #5.
