# Handoff — latest session state

**This file is overwritten each session.** It holds "where we are right now."
Full history is in `git log` — don't make dated copies. The ordered plan is in
`docs/TASK_PLAN.md`; durable facts are in memory.

_Last updated: 2026-06-12 (afternoon — post live test)._

## AFTERNOON TEST RESULTS (Noel, Lua.log 12:33) — nearly all GREEN

- **Combat VERIFIED end-to-end:** preview ("Attack Warrior... You deal 31, take
  29... confirm") → commit → damage announces → StatusMessagePanel result lines
  → Noel KILLED a barbarian warrior. The "destroys it" verdict spoke correctly
  on the lethal preview.
- **Both combat event shapes confirmed:** `UnitDamageChanged` n=5 (player,
  unit, newDmg, oldDmg, maxDmg); `UnitKilledInCombat` n=4 (killedPlayer,
  killedUnit, killerPlayer, killerUnit). `COMBAT_DEBUG` now OFF; own-loss kill
  announce wired ("Your Warrior was destroyed by X!"); enemy-kill announces
  left to the wrapped StatusMessagePanel (already speaks them — don't double).
- **Bug found + FIXED (untested):** Ctrl+A with 0 MP passed preview and spoke
  "Warrior attacks Warrior." but the engine silently queued the MOVE_TO+ATTACK
  and then DROPPED it next turn — Noel's "attack waited until next turn"
  confusion. `requestAttackAt` now refuses up front: "Out of moves. Warrior
  can attack next turn."
- **Also verified live:** queued-move announce + next-turn "arrived at
  destination"; "costs 2" on hills (silent on flat); exits ring on slash incl.
  "northeast mountain" and "southeast 1, river"; "damaged" unit state.
- **Still untested:** river-edge side correctness (a river flag spoke, but
  which-side accuracy unconfirmed); the 0-MP attack refusal; the own-loss
  kill announce.

## EVENING TEST (Noel, post-relaunch) — briefing + Ctrl+D GREEN

- **Overnight briefing VERIFIED live:** "Overnight: Your Warrior recovered 10
  HP, 37 of 100. Enemy Barbarians Scout 2 southwest of Amsterdam." — recovery
  tracking, the heal-tick deferral, AND the anchored enemy move all worked.
- **Ctrl+D VERIFIED** (all four modes cycled). The #14 hex-cluster migration
  is now fully verified.
- **R on the damaged warrior said "Warrior fortified"** — HEAL was tried first
  (damaged path) but the engine REFUSED it in the field; warrior was in
  neutral territory. Open question: does UNITOPERATION_HEAL accept for land
  military anywhere (friendly territory?), or is it naval/support-only in this
  ruleset? Either way fortify heals (+10/turn per the briefing). Follow-up
  idea: briefing says "fully healed" when a tracked unit hits max — plain
  fortify never announces completion.
- **Diplomacy re-meet (Robert kudo):** the statement DID speak ("Wise to keep
  peace with your neighbors...") but Noel's arrow presses clobbered it — each
  nav announce ("Goodbye, 1 of 1") interrupts the in-flight status line. The
  known anti-clobber / repeat-key / pager work covers this; no diplo bug.

---

## What happened this morning

**The #14 nav migration is VERIFIED.** Yesterday's handoff said the evening
checkpoint had "never been run" — that was wrong. The Lua.log (last write
2026-06-11 22:20, nine minutes BEFORE the checkpoint commit) shows the new code
was dev-deployed and live-tested: bare-cluster cursor moves speak tiles,
Shift+dir unit moves speak with the unit name leading ("Warrior moved east. out
of moves"), blocked-with-reason works ("blocked northeast, water" / "blocked
east, mountain"). CLAUDE.md + HOTKEY_REFERENCE updated to verified.

**The same log surfaced one real bug, now FIXED (untested):** moving into rough
terrain with too few moves left (Shift+C into desert hills with 1 MP) was
**silent on the first press** — the engine QUEUES the move and fires NO
completion event, so the async resolver never ran; a second press then spoke a
false "Warrior blocked southeast". Fix in `UnitMovement.directMove`: pre-detect
the queue with the pathfinder (a 1-hex path priced at >1 turn), announce
"Warrior moving southeast, not enough moves this turn, arrives next turn", and
register the unit in the move-to arrival tracker so next turn's landing speaks
"arrived at destination" (this also closes the old "queued move arrives
silently" open item). The checkpoint's `GetQueuedDestination` check in
`resolveAndSpeak` stays as a backstop but the pre-detect is the real fix.

**Phrasing fixes (also from the log, untested):**
- "moving to 1 southeast, **1 hexes**" → the `directionString` CONTRACT is that
  it carries the distance itself (hex decomposition, or the LOC phrase in
  bearing modes). Three callers were appending ", N hexes" on top —
  `ScreenReaderPlotUtils` (queued-dest readout), `UnitMovement.previewToCursor`
  (would say "northeast, 6 hexes, 6 hexes" in compass mode), and
  `ScannerSurvey.describeEntry`. All now just speak `directionString`'s output.
- The `LOC_CIVVIACCESS_DIR_{COMPASS,CLOCK,DEGREES}_PHRASE` strings now use the
  Firaxis plural syntax (`{1_Dist : plural 1?hex; other?hexes;}`).
- `ScannerBackendGeography.FormatName` pluralizes "1 hex".

**Combat part 3:** the COMBAT_DEBUG instrumentation captured a live AI-vs-barb
fight: `UnitDamageChanged` is `n=5 [playerID, unitID, newDamage, prevDamage,
maxDamage]` — which CONFIRMS the shape `onUnitDamageChanged` already assumes,
so the "under attack, N HP left" announce is correctly wired as-is.
`UnitKilledInCombat` has still never fired in a log; the kill announce stays
log-only (COMBAT_DEBUG stays ON) until one shows up.

## NEW this morning (untested): movement-cost speech (Noel's design)

- **Cursor keys** now append **"costs N" only when N > 1** (exceptions speak;
  silence = the normal 1). Tile announce also gained **improvement + road**
  names (never spoken before) with pillaged state. `PlotEntryCost` in
  `ScreenReaderPlotUtils` (engine `plot:GetMovementCost()`; unpillaged route
  rate overrides, so roaded hills go quiet).
- **Bare `/`** appends an **exits ring** after the stats: six adjacent tiles in
  Q/E/A/D/Z/C order with costs, blocked dirs named via the exported
  `UnitMovement.blockedReason`, river-crossing edges flagged ", river".
  **CAVEAT:** the river-edge direction mapping mirrors the cliff convention and
  is UNVERIFIED — if "river" speaks on the wrong side, swap fromPlot/toPlot in
  `UnitInfo.riverBetween` AND the cliff check it copies.

## NEW (afternoon, untested): overnight briefing + heal-first R

- **`BetweenTurns.lua` (NEW FILE, registered in modinfo + HexCursorAddin):**
  collects during the AI turns, speaks at the player's turn start:
  "Overnight: Your Warrior was attacked, lost 25 HP, 45 of 100 left. Your
  Scout recovered 10 HP, 55 of 100. Enemy Barbarians Warrior 2 east of
  Amsterdam." Net HP change per own unit (attack + heal in one night net
  out); recovery speaks so Noel can plan rest-vs-walk-to-city (his ask).
  Enemy moves are nearest-anchored to his units/cities, closest first, cap 3.
  Quiet night = silence. Compose is DEFERRED one event pump past
  LocalPlayerTurnBegin (heal ticks land at PlayerTurnActivated, after turn
  begin — log-proven) via GameCoreEventPublishComplete.
- **City damage events:** guard-subscribed (`CityDamageChanged` /
  `DistrictDamageChanged`, whichever exists) and LOGGED ONLY (`BT_DEBUG`)
  until a live siege confirms the arg shape — then wire "your city was
  attacked" into the briefing. Noel once lost track of a barbarian that
  attacked his city; this is the path to covering that.
- **R heal-first:** a damaged unit now tries HEAL (fortify-until-healed)
  before FORTIFY, announces "Warrior healing until full, 45 HP now"; rest
  states got real spoken forms (fortified / on alert / sleeping).
- **Still queued for the briefing:** Enter turn-gate, verbosity option
  (all moves / enemy only / off), re-read key, city-damage speech.

## NEW (evening, untested): production queue fix + completion announces

Noel's report: picked Granary mid-Warrior expecting to CHANGE production;
it silently QUEUED behind the Warrior, the Warrior finished with no announce,
and the Granary slid in as current. Log + vanilla source confirmed the cause:
our picker's `RequestOperation(BUILD)` sent no `PARAM_INSERT_MODE`, and the
engine default APPENDS — vanilla's normal pick sends `VALUE_REPLACE_AT` at
slot 0. Fixes:
- **Picker commits now REPLACE the current build** (vanilla's exact pair).
  Queue-append becomes an explicit gesture later if wanted.
- **Replace-confirmation latch (Noel 2026-06-12):** picking while another
  build is in progress warns first — "Granary is in progress, 2 turns to
  complete. Press Enter again to replace it with Builder." Second Enter on
  the same item commits; picking the already-building item says so; idle
  city commits immediately (the common blocker flow stays one press). Same
  preview->confirm idiom as Ctrl+A. Arm cleared on picker close.
- **Overnight briefing announces completions:** "Amsterdam completed Warrior,
  now building Granary" / ", production needed" (arg shape confirmed from
  vanilla TutorialUIRoot: ORDER_TRAIN/CONSTRUCT/ZONE index Units/Buildings/
  Districts). EotReport's N report still accumulates them too.
- **Known gap (deferred):** the picker's Queue tab only shows the CURRENT
  item, not queued entries — real queue display/management is future work
  (less urgent now that picks replace).

## NEW (evening, untested): bare G = My Government hub

Noel wants to CHANGE the cards Alt+P auto-picked, anytime — not only when a
blocker exists. Bare G (wrap combo; engine grid-toggle reclaimed) raises
`LuaEvents.LaunchBar_GovernmentOpenMyGovernment` — the exact event the
LaunchBar button raises — so the RevealListeners hub opens: announces current
government, then G = type chooser, P = policy wizard. TEST: just press G on
the map → expect the government announce (the hub/wizard themselves are
proven). **The wizard's REAL commit is now VERIFIED LIVE** (2026-06-12 log:
"Chose Urban Planning" → "Applying policy changes." → policy blocker
dismissed → "Ready to end turn") — the last live-pending piece of the
2026-05-31 government build is closed. Noel reached it via the
civic-completion open path.

## NEW (evening, untested): Shift+Enter activates the current notification

Noel couldn't open the policy picker from the "a policy needs to be added"
blocker — our notification cycle had NO activate path at all (only [ / ]
prev/next + Alt+N). The policies he DID get came from **Alt+P auto-pick**
(CityProduction.unblockAll quietly filled 2 slots — log line
"RequestPolicyChanges committed"). Added: **Shift+Enter** on the wrap →
`Notifications.activateCurrent()` → `NotificationManager.Find` +
`pNotification:Activate(true)` (the vanilla TryActivate chain) → the real
NotificationPanel dispatches per-type → our wrappers intercept. TEST: bracket
to the policy blocker, Shift+Enter → expect the PolicyWizard slot walk
("Military slot 1, currently ..."). If instead the RAW GS GovernmentScreen
opens (mouse wall), the GS notification handler routes differently than base —
read the log for what LuaEvent fired and wire that path.

## Test next (relaunch first — launcher dev-deploys on run)

1. **Queued move:** move a unit until ~1 MP left, Shift+dir into hills →
   "moving <dir>, not enough moves this turn, arrives next turn" (first press,
   no silence). Next turn it should say "Warrior arrived at destination."
2. **Ctrl+D** → "Direction mode: compass / clock / …" (code live, never
   exercised). Then move the cursor / run the survey in clock mode and confirm
   distances speak ONCE ("3 o'clock, 2 hexes" — not doubled, "1 hex" singular).
3. **Combat (Ctrl+A)** — still never exercised. Scan to a barbarian, get
   adjacent, Ctrl+A → odds preview → Ctrl+A → attack. Send the log: need to
   confirm SimulateAttackVersus numbers read right (you-deal vs you-take) and
   to finally capture the `UnitKilledInCombat` arg shape.
4. **Movement-cost speech:** arrow the cursor onto hills/woods → "costs 2"
   appended (flat tiles stay silent); press `/` with the Warrior selected →
   stats then "Exits: northwest 1. …" — check blocked dirs and whether
   "river" lands on the correct edges.

## Shipped (committed + pushed, verified)

- **v0.6.0** launcher (capture-all input, scanner v1, diplomacy rebuild).
- **P0 Prism backend** — camm **0.6.0** (`743e9fa`) + gitlink bump (`0706ba6`).
- **0.6.1** (`a17ab83`, local, not tagged) — scanner backends (#8), survey/zoom
  (#19/#17), move-to (#10), slash split. Tested live 2026-06-11.
- **#14 nav migration** (`ea8e726` + today's fixes) — hex cluster on the wrap,
  VERIFIED per above.

## Combat — next layer (queued, after the Ctrl+A test greens)

- **Pillage key** (Noel 2026-06-12): `UNITOPERATION_PILLAGE` / `PILLAGE_ROUTE`
  via the same RequestOperation pattern as `UnitMovement.rest()`; preview the
  yield (farms heal, mines gold, campus science) before committing; say the
  3 MP cost. No engine hotkey exists (panel-button-only) — fresh wrap key.
- **Rest-family key audit** (same pass, Noel 2026-06-12): R smart-rest /
  Alt+Z sleep / Alt+X auto-explore exist but ride legacy InputActions — move
  them onto the wrap like the nav cluster, confirm each speaks, and make sure
  every rest state (sleep/fortify/alert/heal/skip) is reachable + announced.
- Smarter defender + escort phrasing (strongest military defender; corps/army
  via `GetMilitaryFormation`).
- District combat targets (Encampments + walls; both HP pools; "bring siege").
- Survey unit subcategories: **Threats** + **My units**.
- Between-turns AI movement summary, turn gated on Enter; verbosity option.

## Other queued work (detail in memory — see MEMORY.md)

- **Sequence:** combat → **paged reports** (`project_empire_status_expansion`)
  → **sonification** (Alt+S survey stub + JJFlex waterfall toolkit).
- **Help pager + context-sensitive `?`** (`project_help_pager_and_context_help`).
- **Unit state surfacing** (`project_unit_state_surfacing`).
- **Keymap profiles + Civ V F-key compat** (`project_keymap_profiles_civ_v_compat`).
- **Notification anti-clobber + verbosity options** (rides with the pager).
- **#14 remainder:** the Alt+Q/A/Z/C engine letter-actions are still on the
  legacy InputAction path and SILENT — own + announce (or eat) them.

## Open items / known gaps (not blocking)

- Global "repeat last announce" key (`CIVVIACCESS_RepeatAnnounce` exists —
  standardize it).
- Enemy-halt on auto-move still unverified (no enemy tested).
- Survey perf: `S` runs all backends incl. geography flood-fill each press.
- Strip `COMBAT_DEBUG` + `DiploDebugMeet` + Alt+M DiploProbe + `POSTFOUND_DIAG`
  before any public release.

## Heads-up

- A second session may be active — keep sessions on **different files** (the
  scanner help LOC string `CivVIAccessStrings.xml` was edited outside this
  session; today's session ALSO touched it — the DIR phrase plurals).
- The launcher dev-deploys mod source on run, so a relaunch picks up edits.
