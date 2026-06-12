# Civ VI Access — Hotkey Reference

Our keyboard map, and the engine defaults we build on top of — modeled on Civ V
Access's `docs/hotkey-reference.md`. Purpose: every key we bind is a conscious
choice, classified and rationalized, so the key audit and the Help (`?`) catalog
both have one source of truth.

Authoritative engine source: `Base/Assets/Configuration/Data/InputConfiguration.xml`
(`InputActionDefaultGestures`). Where this doc and the game disagree, the XML wins
— verify at runtime when in doubt.

> **Status:** living doc. The scanner + capture-all rows are current as of
> 2026-06-08. The full per-key audit (every existing mod binding classified +
> registered in Help) is task #15 — fill this in as that proceeds.

---

## The capture-all model (how we own keys)

**Proven 2026-06-08 (live probe):** wrapping `WorldInput`'s `OnInputHandler` and
returning `true` for a key **suppresses the engine's InputAction**. So on the map
we own the keyboard: the WorldInput wrap consumes a key → we handle it; returns
false → the engine handles it (and we may still announce around it). This is why
"no more key fights" — collisions are a non-issue for any key we choose to
consume. Sighted mode = the wrap returns false for everything (vanilla play).

**`Keys` enum gotcha:** Civ VI's `Keys` table is its OWN numbering, NOT Windows VK
(`Keys.Y` = 25, `Keys.VK_OEM_COMMA` = 89, `Keys.VK_OEM_PERIOD` = 91). Always bind
via `Keys.*` constants — never hardcode VK literals.

---

## Three-way classification (the rule every key goes through)

1. **RECLAIM** — the engine's function is *sighted-only* and worthless to a blind
   player (camera zoom/pan, map search, full-screen-map toggle, yield/grid
   overlays). Take the key.
2. **KEEP** — the engine's function is a *game action a blind player uses* (B =
   found city, fortify, attack, unit missions). Let the engine do it (return
   false), just announce around it. Don't reclaim.
3. **FREE** — genuinely unbound by the engine. Use freely.

Never bind (screen-reader collisions, not the game): **Insert** (NVDA/JAWS key),
**Caps Lock** (NVDA secondary / Narrator), **Numpad with NumLock OFF** (NVDA
laptop modifier).

---

## Engine defaults to know (Civ VI, the map / World context)

Bound single letters (engine consumes them — RECLAIM or KEEP per above):
- **A** Attack, **B** FoundCity, **C** ToggleCivicsTree, **E** AutoExplore,
  **F** Fortify, **G** ToggleGrid, **H** FortifyUntilHeal, **L** ToggleReligion,
  **M** MoveTo, **O** ToggleGreatPeople, **P** OnlinePause, **Q** ToggleResources,
  **R** RangedAttack, **T** ToggleTechTree, **V** Alert, **W** ToggleGreatWorks,
  **Y** ToggleYield, **Z** Sleep
- **1–9** Lenses; **Space** SkipTurn, **Return** EndTurn, **Home** PauseMenu,
  **End** ToggleFSMap, **Delete** DeleteUnit
- **Comma** PrevUnit, **Period** NextUnit, **[ / ]** Prev/Next city,
  **Backslash** CapitalCity, **Arrows** CameraPan
- **PageUp / PageDown** camera zoom (engine-hardcoded, not in XML)
- **Ctrl+F** OpenMapSearch

Unbound (FREE): single letters **D, I, J, K, N, S, U, X**; **Tab** (fires
nothing); most punctuation; most modifier-combos (audit case by case).

---

## Our bindings

### Scanner (NEW 2026-06-08) — forwarded from the WorldInput wrap, handled in the addin VM

- **PageDown / PageUp** — next / prev scanner *item*. *RECLAIM: engine use is
  sighted camera zoom. Mirrors Civ V Access; the most-pressed scanner axis.*
- **Shift+PageDown / Up** — next / prev *subcategory*. *FREE combo.*
- **Ctrl+PageDown / Up** — next / prev *category*. *FREE combo.*
- **Alt+PageDown / Up** — next / prev *instance*. *FREE combo.*
- **Home** — jump the hex cursor to the current entry. *RECLAIM: engine use is
  PauseMenu, which stays reachable on Escape. Civ V parity (it reclaimed
  Next-city there).*
- **End** — speak distance + direction to the current entry. *RECLAIM:
  full-screen-map toggle, sighted-only.*
- **Backspace** — return the cursor to the pre-jump cell. *RECLAIM: Cancel /
  Stop-automation, mouse-first.*

### Hex cursor / world nav — the Q E A D Z C cluster (MIGRATED TO THE WRAP,
### verified live 2026-06-11)

The pointy-top hex cluster carries THREE layers by modifier. NW=Q, NE=E, W=A,
E=D, SW=Z, SE=C. The bare + Shift layers ride the capture-all wrap
(`NavKeys.dispatch`, forwarded from `WorldInputAccessWrap`) — **verified in
Lua.log 2026-06-11**: every press speaks.

- **Bare Q/E/A/D/Z/C** — move the **hex CURSOR** one hex; speaks the tile
  (terrain, feature, resource, river, improvement, road, units/city), plus
  **"costs N" when the entry cost is > 1** — silence means the normal 1, so
  only turn-eaters (hills, woods) announce; roads flatten the cost back to
  quiet. (Wrap → `NavKeys` → `HexCursor.move`.) Civ V Access uses the same
  bare cluster for its cursor — already Civ V-aligned.
- **Shift+Q/E/A/D/Z/C** — move the selected **UNIT** one hex; speaks
  "Warrior moved east, N moves" / "Warrior blocked northeast, water" /
  "Warrior moving southeast, not enough moves this turn, arrives next turn"
  (queued). (Wrap → `NavKeys` → `UnitMovement.directMove`.)
- **Ctrl+D** — cycle the **direction vocabulary** (hex / compass / clock /
  degrees). Moved off Shift+D so the D-family mirrors A (bare=cursor,
  Shift=unit, Ctrl=mode/action). *Code path live; not yet exercised in a log.*
- **Alt+Q/A/Z/C** — the engine's own letter-actions, rebound here OFF the bare
  letters: **Alt+Q** ToggleResources, **Alt+A** Attack, **Alt+Z** Sleep,
  **Alt+C** ToggleCivicsTree. **These give NO speech** (visual toggles / silent
  mouse-mode attack) — fat-fingering Alt for Shift lands here silently.
  **Alt+E** is dormant (auto-explore is Alt+X). **Alt+D** = engine cursor-east.

**Remaining #14 work:** only the Alt+letter engine-actions above are still on
the legacy InputAction path — the "map some engine keys, not all" follow-up
owns + announces (or eats) them. The old `CIVVIACCESS_Cursor*/Move*`
InputActions remain in `RemapForHexCursor.xml` but the wrap suppresses them
(revert fallback; clean up later).

- **Shift+V** — verbosity toggle (terse / chatty).
- Info / readout keys (Ctrl+T re-read, Ctrl+I image, etc.) — **AUDIT TODO**:
  enumerate + classify + list here.
- Notification cycle — **`[` / `]`** prev/next (LIVE — InputActions, reclaimed
  from Prev/Next-city; the "PLANNED" note here was stale), **Alt+N** reminder
  toggle, **Shift+Enter** = ACTIVATE the current entry (wrap combo, added
  2026-06-12) — the keyboard form of clicking a notification icon: opens the
  policy picker / tech chooser / etc. for the entry the brackets last spoke.
  Civ V's `Ctrl+[`/`]` (oldest/newest) and `Shift+[`/`]` (filter) ladder is
  still future work.

### Speech history — Shift+R (UPGRADED 2026-06-12)

- **Shift+R** (once) — repeat the last announce verbatim, any kind, from any
  VM. **Shift+R again** — walk BACK through the last 20 meaningful announces,
  newest first ("Back 2. Uncovered 6 hexes: ..."); nav/picker browse chatter
  is excluded from the walk. Any new announce resets it; the oldest entry
  says "End of history". *Wrap combo → `SpeechHistory.lua` (fed by the
  `CivViAccess_SpeechEmitted` broadcast inside Speech.emit). The legacy
  `CIVVIACCESS_RepeatAnnounce` InputAction remains as a dead fallback. Depth
  becomes a setting when the accessibility options tab exists. The pager
  (next deliverable) will render long entries.*

### Government — bare G (NEW 2026-06-12)

- **G** — open **My Government** (announces the current government), then
  **G** = change government type, **P** = the policy wizard (re-slot cards:
  Up/Down browse, T reads effect, Space slots + advances, Shift+Enter keeps
  the current card, Enter applies all, Escape cancels). *RECLAIM: engine bare
  G = map grid toggle, sighted-only. Raised via
  `LuaEvents.LaunchBar_GovernmentOpenMyGovernment` — identical to clicking the
  LaunchBar button, so the RevealListeners hub intercepts as usual.*

### Survey + zoom (NEW 2026-06-09) — cursor-centered radius census

Anchored on the hex cursor; reuses the scanner backends. The cursor is the
universal center (move it / type a coord / search → jump → survey). See
`project_cursor_survey_subsystem` memory.

- **W** — where am I (quick: bearing from capital + coords). *RECLAIM: engine W =
  Great Works overlay (sighted-only). MIGRATED here from bare S (2026-06-09) to
  free S for survey; W = "Where am I". Tradeoff: gives up the S-center-of-cluster
  locate convention (`reference_where_am_i_center_key`) for a letter mnemonic —
  Noel's call.*
- **Shift+W** — rich positional locate (terrain + nearest city + coords).
  *Migrated from Shift+S.*
- **S** — survey: read the SELECTED category within the current zoom radius,
  around the cursor. *FREE after the where-am-I move.*
- **Alt+S** — sonify the current survey (spatial audio). *FREE combo.*
- **Alt+G / Alt+U / Alt+R** — select survey category: general-all / units /
  resources. *FREE combos (G/U/R clear of the Alt+QEADZC move cluster). The
  selected category is saved (session state). More categories (cities / terrain /
  improvements / yields) TBD: dedicated keys vs a "next category" cycle.*
- **Alt+1–5** — set zoom level (radius ≈ 2 / 4 / 8 / 16 / whole revealed).
  **Alt+0** — reset to level 1. *RECLAIM: number row = engine lenses, sighted-only.
  Zoom is shared by the survey AND scanner reach (#17).*

### Move-to / routes (NEW 2026-06-09, P2)

Destination = the hex cursor (park it via scanner Home / nav / search, then act).
Civ VI auto-paths a distant `MOVE_TO` across turns natively — no engine fork.

- **M** — move the selected unit to the cursor (multi-turn auto-path; arrival +
  per-turn-remaining are announced). *RECLAIM: engine M = MoveTo interface mode,
  which we replace with our own. Routed to `UnitMovement.moveToCursor`.*
- **Shift+M** — read-only **path preview** to the cursor: turn count + bearing +
  distance + embark / unexplored hints. *Routed to `UnitMovement.previewToCursor`.*
- **Ctrl+M** — cancel the selected unit's queued movement
  (`UnitManager.RequestCommand(unit, UnitCommandTypes.CANCEL)`). *Routed to
  `UnitMovement.cancelMove`.*

Units auto-moving read their status in the scanner / selection readout via
`StringifyUnit` ("... moving to northeast, 4 hexes, at 11, 31") — own units only.

Phase 2 (deferred): manual waypoint legs, worker route-to (auto-build road).
Auto-explore already exists on **Alt+X**.

### Combat (NEW 2026-06-11, P3)

No engine fork (Civ V Access forked C++; Civ VI exposes it all in stock Lua):
`CombatManager.SimulateAttackVersus` (odds), `IsAttackChangeWarState` (war
warning), `CanAttackTarget` (validity). Melee = `MOVE_TO` with the `ATTACK`
modifier; ranged = `RANGE_ATTACK` operation. One preview→confirm→commit engine
(`UnitCombat.lua`), two entry points.

- **Ctrl+A** — attack the hex cursor target. *NOT bare A (= cursor west) or
  Shift+A (= move unit west) — Ctrl completes the A-family. First press speaks the
  odds + any war warning and arms; press Ctrl+A again on the same target to commit.
  Works for ranged units at a distance.*
- **Move-into-enemy** — `M` (move-to-cursor) or `Alt+`direction onto an adjacent
  enemy routes into the SAME preview→confirm flow instead of refusing. *Melee
  only (you can only move into adjacency); the confirm press keeps it from
  starting a war by accident.*
- Melee/ranged/capture are auto-detected; a defenceless civilian is a **capture**
  (no odds, just confirm). Non-adjacent melee says "move closer"; out-of-range
  ranged says "out of range."
- **Result announces** ride engine events (`UnitKilledInCombat`,
  `UnitDamageChanged`) — instrumented with arg-logging (`COMBAT_DEBUG`) until the
  live signatures are confirmed, then the spoken "you were attacked / X destroyed"
  lines get wired from the log. *Strip `COMBAT_DEBUG` before a public release.*

### Slash family — unit stats / recenter / help

`/` (`VK_OEM_2`) is engine-FREE on the map. Three split bindings; the wrap only
captures the Shift case so bare/Ctrl stay on their InputActions:

- **`/`** (bare) — speak the selected unit's stats, then the **exits ring**:
  all six adjacent tiles with entry costs in Q/E/A/D/Z/C order ("Exits:
  northwest 1. northeast 2, river. west water. …"), blocked directions named
  with the same words the move keys speak (`CIVVIACCESS_UnitInfo` →
  `UnitInfo.speakInfo`). Stats first so the quick check is uninterrupted; keep
  listening for the exits. *InputAction path (NOT forwarded by the wrap).*
- **Ctrl+`/`** — recenter the hex cursor on the selected unit
  (`CIVVIACCESS_RecenterOnUnit`). *InputAction path.*
- **Shift+`/`** (`?`) — read the scanner cheat-sheet (`ScannerHandler` → ladder).
  *The ONLY slash case the capture-all wrap forwards (exact `Shift` combo), so it
  can't clobber bare-`/` unit stats. (Bug fixed 2026-06-11: `VK_OEM_2` had been a
  bare scanner key, so any-modifier `/` fired the cheat-sheet and ate unit-stats.)*

### Responsiveness note (Noel 2026-06-08)

Keys routed through the capture-all `OnInputHandler` path fire noticeably faster
than the old engine InputAction round-trip (gesture → InputActionTriggered →
handler). A standing reason to migrate the existing InputAction-based bindings onto
the capture path (task #14): it's not just key freedom, it's lower input latency.

### Sighted mode (task #13)

A reserved chord (TBD, e.g. the Civ V-style `Ctrl+Shift+F12`) toggles sighted
mode in BOTH states (pre-walk hook). In sighted mode the wrap passes the whole
keyboard through; speech + cues are independently muteable. Per-player sighted
designation lives in the game-setup options.

---

## Source files

- Engine: `Base/Assets/Configuration/Data/InputConfiguration.xml`.
- Ours: `WorldInputAccessWrap.lua` (capture/forward), `ScannerHandler.lua`
  (scanner dispatch), `HexCursorAddin.lua` + `HexCursor.lua` (cursor nav),
  `RemapForHexCursor.xml` (gesture reclaim where a non-capture path is used).
- Memory: `reference_civ_vi_default_keybindings` (the engine-key + capture-all
  findings this doc summarizes).
