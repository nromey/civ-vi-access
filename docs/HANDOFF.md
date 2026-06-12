# Handoff — latest session state

**This file is overwritten each session.** It holds "where we are right now."
Full history is in `git log` — don't make dated copies. The ordered plan is in
`docs/TASK_PLAN.md`; durable facts are in memory.

_Last updated: 2026-06-11._

## Shipped (committed + pushed)

- **v0.6.0** launcher (capture-all input, scanner v1, diplomacy rebuild).
- **P0 Prism backend** — camm **0.6.0** (tag, commit `743e9fa`) + civ-vi-access
  gitlink bump (`0706ba6`), both pushed. `IScreenReader` + Tolk/Prism (own
  `[LibraryImport]` P/Invoke), `ScreenReaderFactory` Prism→Tolk fallback, manifest
  `ScreenReaderBackend` + `CAMM_SCREEN_READER_BACKEND` override. Prism built from
  source: pinned submodule `camm/third_party/prism` @ bb68308.

## Committed this session — `CivViAccessMod/` batch, version bumped to 0.6.1

Tested live 2026-06-11, log-verified, then committed (NOT yet tagged/released —
that's the open "how to move forward" decision). CHANGELOG 0.6.1 + csproj
`<Version>` bumped together.

- **#8 scanner backends** — `ScannerBackendImprovements` / `Geography` (hybrid:
  flood-fill revealed land named by dominant continent + numbered oceans) /
  `Recommendations`. Validated live.
- **#19 survey + #17 zoom** — `ScannerSurvey.lua`, cursor-centered radius census.
  `S` survey, `Alt+S` sonify (STUB), `Alt+G/U/R` category, `Alt+1–9`/`0`/`=`/`-`
  zoom (map-size-aware). `W`/`Shift+W` where-am-I (migrated off bare-S). Validated.
- **P2 move-to** — `UnitMovement.lua`: `M` move-to-cursor (engine auto-paths),
  `Shift+M` preview (`GetMoveToPathEx`), `Ctrl+M` cancel. Arrival + turn-begin
  progress; en-route status in `StringifyUnit`. Enemy-occupied target refused
  ("… on target. Combat coming in a future release."). Validated live, incl. the
  barbarian-target refusal (warrior kept its moves — working as designed).
- **Fixes** — slash split (bare `/` = unit stats, `Ctrl+/` = recenter, only
  `Shift+/` = cheat-sheet; was a regression where any-mod `/` fired help);
  barbarians classify as "enemy"; single-unit cycle selects + names the lone unit.

## IN PROGRESS — Combat P3 (built 2026-06-11, UNCOMMITTED, pending live test)

Agreed sequence: **combat → reporting (paged) → sonification**. Combat first.

`CivViAccessMod/Assets/UI/Accessibility/UnitCombat.lua` (NEW) — no engine fork;
Civ VI exposes `CombatManager.SimulateAttackVersus` (odds), `IsAttackChangeWarState`
(war warning), `CanAttackTarget` (validity). Melee = `MOVE_TO` + `ATTACK` modifier;
ranged = `RANGE_ATTACK` op; civilian = capture (plain `MOVE_TO`). One
preview→confirm→commit engine, two entry points:
- **Ctrl+A** = attack hex-cursor target (first press previews odds + war warning +
  arms; Ctrl+A again commits). Works for ranged at distance. NOTE: first try bound
  bare A, which stomped cursor-west (bare QEADZC = cursor, Shift+QEADZC = unit move,
  both A's taken) — moved to Ctrl+A 2026-06-11.
- **Move-into-enemy** = `M`/`Alt+dir` onto an adjacent enemy redirects into the same
  flow (UnitMovement's old "combat coming" guards now call `UnitCombat.requestAttackAt`).
Wired: modinfo (both blocks), `include("UnitCombat")` in HexCursorAddin, dispatch in
ScannerAddinGlue (after movement). HOTKEY_REFERENCE updated.

**TEST + what the log must confirm (then I wire part 3 / commit):**
- Scan to the barbarian Scout, select your Warrior adjacent → press **A**: expect
  "Attack Scout. Warrior 20 versus 10. You deal N, take M. <verdict>. Press A again
  to confirm." → **A** again → "Warrior attacks Scout." Then the engine resolves.
- Verify the `SimulateAttackVersus` numbers read right (DAMAGE_TO = damage RECEIVED
  by each side — confirm "you deal/take" aren't swapped). Grep `UnitCombat` in Lua.log.
- Part 3 announces are INSTRUMENTED not final: `COMBAT_DEBUG=true` logs
  `onUnitDamageChanged` / `onUnitKilledInCombat` arg shapes. The "under attack, N HP"
  line assumes `(playerID, unitID, newDamage, prevDamage)` — confirm from the log,
  then wire the kill announce + fix damage announce. **Strip COMBAT_DEBUG before release.**
- Known MVP gaps: non-adjacent melee says "move closer" (no auto-path-to-attack);
  best-defender picks first enemy unit on the plot (civilian-under-escort edge case).

### Combat — next layer (queued, after the MVP tests green)

Civ VI-specific surfaces, all discussed 2026-06-11:
- **Smarter defender + escort phrasing** — pick the strongest enemy military unit as
  the defender (not first-on-tile); read stacks "defender first, escorting X";
  append corps/army/fleet/armada via `pUnit:GetMilitaryFormation()`.
- **District combat targets** — Encampments + city walls. Read both HP pools:
  `pDistrict:GetMaxDamage(DefenseTypes.DISTRICT_OUTER/_GARRISON)` (walls vs city HP);
  `SimulateAttackVersus` already returns wall hits separately as
  `CombatResultParameters.DEFENSE_DAMAGE_TO`. "Bring siege" when walls up; ranged
  can't capture. Extend `UnitCombat.classifyAttack` (today it no-ops on districts).
- **Survey unit subcategories** — add **Threats** (hostile combat units, civilians
  excluded — the "is anything coming for me" scan) and **My units**; civilians +
  land/sea later. Long-term: per-owner filters + user-built custom categories
  (Civ V Access model) once the survey earns a settings surface.
- **Between-turns AI movement awareness** (the P3 "speak units that moved" item /
  Civ V Access "Unit Moves" log) — we already get `UnitMoveComplete` for AI units
  (we discard non-own). ACCUMULATE foreign-visible moves during the AI turn, SUMMARIZE
  at `LocalPlayerTurnBegin` ("while you were away: Scout now 3 NE"); never speak live.
  Reviewable log; later owner filters + exclude trade units (caravans clutter).
  NOTE: today's "barbarians approaching" is an engine NOTIFICATION, not this tracker.

## Open items raised live 2026-06-11 (not blocking)

- **Global "repeat last announce"** — Noel hit `R` expecting a repeat and got
  Rest. Want a consistent repeat-last key (JJFlex/NVDA style). There's already a
  `CIVVIACCESS_RepeatAnnounce` action — wire/standardize it as the global repeat.
  Fold into the key-registry work (`project_key_registry_announce_learn`).
- **Move-adjacent affordance for enemy targets** — move-to onto an enemy is
  (correctly) refused since combat is P3. `directMove` already phrases it as
  "<enemy> <dir>"; move-to could hint "move adjacent" / pick the best adjacent
  hex. Real answer lands with combat (P3).
- **Pluralization "1 hexes" → "1 hex"** — deferred to its own small commit.
  Two layers: ad-hoc Lua concat (`ScannerSurvey`, `ScreenReaderPlotUtils`) needs a
  shared `hexCount(n)`; the `LOC_CIVVIACCESS_DIR_*_PHRASE` strings (compass/clock/
  degrees in `HexGeom`) need LOC plural handling.
- **Repo hygiene** — `CLAUDE.md` and this `HANDOFF.md` were untracked; committed
  this session.

## Test status / risk flags (verify in deeper play; all pcall-guarded)

- **Enemy-halt behavior still UNVERIFIED** — no friendly-vs-enemy move-through
  case tested. Verify "does an auto-move stop on enemy contact"; if it stalls
  silently, add a "movement paused" announce.
- Survey perf: `S` runs ALL backends (incl. geography flood-fill) each press —
  may lag on big maps; scope the gather down if so.
- Digit zoom `Alt+1–9` depends on the Civ VI `Keys` digit enum; `Alt+=/-` is the
  reliable fallback.

## Next decision (Noel to pick)

- **Combat (P3)** — move-to is exposing the gap (the barbarian-target refusal);
  unblocks enemy interaction + the move-adjacent affordance.
- **Phase 2 move** — manual waypoint legs + worker route-to (auto-build road).
- **Unexplored as a navigable category** — flood-fill fog → frontier targets →
  move-to = steerable manual exploration (`project_map_exploration_report`).
- **Search-to-center (#12)** — "search Lisbon → cursor jumps → survey/route."

## Heads-up

- A second session may be active — keep sessions on **different files**.
- The launcher dev-deploys mod source on run, so a relaunch picks up edits.
