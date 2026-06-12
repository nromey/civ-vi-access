# Handoff — latest session state

**This file is overwritten each session.** It holds "where we are right now."
Full history is in `git log` — don't make dated copies. The ordered plan is in
`docs/TASK_PLAN.md`; durable facts are in memory.

_Last updated: 2026-06-11 (evening checkpoint)._

---

## RESUME HERE — first thing tomorrow

**State:** everything below is **committed as an UNTESTED evening checkpoint** (no
release, no version bump). The launcher dev-deploys mod source on run, so just
**relaunch** and it's live. The two big pieces (the #14 key migration and combat)
have **never been run** — testing them is the first job.

**Test in THIS order (relaunch first):**

1. **Nav migration — the headline.** The cursor + unit-move keys moved off the dead
   InputAction path onto the wrap (`NavKeys.lua`).
   - **Bare Q/E/A/D/Z/C** → moves the **cursor**, speaks the tile. (Q=NW E=NE A=W D=E Z=SW C=SE)
   - **Shift + Q/E/A/D/Z/C** → moves the **unit** one hex → *"Warrior moved \<dir\>, N moves."*
     **This was silent/dead before — it's the main thing to confirm.** Shift+D = unit east.
   - **Ctrl+D** → *"Direction mode: compass / clock / …"* (vocab moved here off Shift+D).
   - **Bare A** = cursor west (NOT attack); **Ctrl+A** = attack.
2. **The fixes that ride with it** (verify while moving around):
   - Selecting your lone unit (comma) now **snaps the cursor onto it** (press W to confirm).
   - Moving into rough terrain after you've already moved → *"moving \<dir\>, not enough
     moves this turn, arrives next turn"* (NOT "blocked"). Water/mountain still "blocked, reason".
   - **No more "Historic Moment / meeting the …" spam** (debug meet disabled).
3. **Combat (Ctrl+A)** — needs an enemy. Scan to a barbarian, get your Warrior adjacent,
   **Ctrl+A** → hear the odds preview → **Ctrl+A again** → it attacks. Send the log: I need
   to confirm the `SimulateAttackVersus` numbers read right (you-deal vs you-take not
   swapped) and the `onUnitDamageChanged`/`onUnitKilledInCombat` arg shapes (logged via
   `COMBAT_DEBUG`).

**After a green test:** update CLAUDE.md + HOTKEY_REFERENCE to say the migration is
*verified* (right now they describe it as in-flight); wire combat "part 3" (the kill
announce) from the logged arg shapes; strip `COMBAT_DEBUG`. THEN consider a release.

---

## Shipped (committed + pushed, verified)

- **v0.6.0** launcher (capture-all input, scanner v1, diplomacy rebuild).
- **P0 Prism backend** — camm **0.6.0** (`743e9fa`) + gitlink bump (`0706ba6`), pushed.
- **0.6.1** (`a17ab83`, local, not tagged) — scanner backends (#8), survey/zoom (#19/#17),
  move-to (#10), slash split. **Tested live 2026-06-11.**
- **docs** (`5a2e68e`) — input-model accuracy fix + memory authority rules + hotkey audit.

## Evening checkpoint — committed, NOT yet tested (this is the resume target)

### #14 capture-all key migration
Root-caused from the log: the unit-move (Shift+dir) InputAction was DEAD. Migrated the
hex cluster onto the wrap:
- `NavKeys.lua` (NEW) — bare cluster → `HexCursor.move`; Shift+cluster →
  `UnitMovement.directMove`; **Ctrl+D → direction-vocab**.
- Wrap added bare + Shift combos for the cluster + Ctrl+D. **D-family finalized:** bare
  D cursor-east / Shift+D unit-east / Ctrl+D vocab (vocab moved off Shift+D — the one
  real collision). Glue routes NavKeys first; ScannerHandler's Shift+D vocab removed.
- Old `CIVVIACCESS_Cursor*/Move*` InputActions left in `RemapForHexCursor.xml` (wrap
  suppresses them; also a revert fallback). Alt+letter engine-actions NOT migrated yet
  ("map some engine keys, not all" — follow-up). Log check: `NavKeys` lines present, NO
  `CIVVIACCESS_Cursor*/Move*` InputActionTriggered.

### Combat P3 (`UnitCombat.lua`)
No engine fork — `CombatManager.SimulateAttackVersus` (odds), `IsAttackChangeWarState`
(war warning), `CanAttackTarget` (validity). Melee = `MOVE_TO`+`ATTACK` modifier; ranged
= `RANGE_ATTACK`; civilian = capture. One preview→confirm→commit engine, two entry
points: **Ctrl+A** (cursor target, works ranged) + **move-into-enemy** (M/Alt+dir
redirects the old "combat coming" guard here). Part 3 (result announces) is INSTRUMENTED
(`COMBAT_DEBUG` logs event args) but not final. Known MVP gaps: non-adjacent melee says
"move closer"; defender = first enemy on the plot (civilian-under-escort edge case).

### Small fixes (same checkpoint)
- Move announce leads with the unit name ("Warrior moved west, N moves").
- Cursor-follows-selected-unit: the "only one unit" path now snaps the cursor onto it.
- Queued-move vs block: `resolveAndSpeak` checks `GetQueuedDestination` → "moving \<dir\>,
  arrives next turn" instead of "blocked" when the engine defers the move.
- `DiploDebugMeet` `DEBUG_FORCE_MEET = false` (was force-meeting civs every reload).

## Combat — next layer (queued, after the MVP tests green)

- **Smarter defender + escort phrasing** — strongest enemy military as defender; read
  stacks "defender first, escorting X"; corps/army/fleet/armada via `GetMilitaryFormation`.
- **District combat targets** — Encampments + city walls; read both HP pools
  (`DefenseTypes.DISTRICT_OUTER/_GARRISON`); `SimulateAttackVersus` returns wall hits as
  `CombatResultParameters.DEFENSE_DAMAGE_TO`. "Bring siege"; ranged can't capture.
- **Survey unit subcategories** — **Threats** (hostile combat units) + **My units**.
- **Between-turns AI movement** — accumulate foreign-visible moves during the AI turn,
  summarize at turn-begin; **gate the turn on Enter**, re-readable; verbosity option
  (all moves / enemy only / off). Exclude trade units.

## Other queued work (detail in memory — see MEMORY.md)

- **Sequence:** combat → **paged reports** (`project_empire_status_expansion` — one
  Reports surface, page between economy/military/cities/etc.) → **sonification**
  (the `Alt+S` survey stub + JJFlex waterfall toolkit).
- **Help pager + context-sensitive `?`** (`project_help_pager_and_context_help`) — paged
  long-text reader that buffers notifications while active; `?` becomes context-aware.
- **Unit state surfacing** (`project_unit_state_surfacing`) — sleeping/fortifying/healing/
  en-route in the slash readout + scanner via a shared `unitStatus()` helper; + a
  cancel/wake key.
- **Keymap profiles + Civ V F-key compat** (`project_keymap_profiles_civ_v_compat`).
- **Notification anti-clobber + verbosity options** (rides with the pager).

## Open items / known gaps (not blocking)

- Global "repeat last announce" key (Noel hit R, got Rest; `CIVVIACCESS_RepeatAnnounce`
  exists — standardize it).
- Pluralization "1 hexes" → "1 hex" (shared `hexCount(n)` + the `LOC_*_PHRASE` strings).
- A queued directional move arrives SILENTLY next turn (no "arrived" announce) — minor.
- Enemy-halt on auto-move still unverified (no enemy tested).
- Survey perf: `S` runs all backends incl. geography flood-fill each press.

## Heads-up

- A second session may be active — keep sessions on **different files** (the scanner
  help LOC string `CivVIAccessStrings.xml` was edited outside this session).
- The launcher dev-deploys mod source on run, so a relaunch picks up edits.
