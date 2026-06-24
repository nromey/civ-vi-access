# Handoff — latest session state

**This file is overwritten each session.** It holds "where we are right now."
Full history is in `git log` — don't make dated copies. The ordered plan is in
`docs/TASK_PLAN.md`; durable facts are in memory.

_Last updated: 2026-06-24 (graphics v2 VERIFIED by Noel; built the first
Accessibility settings tab + standardized the Options nav keys. Both staged,
UNTESTED — playtest next.)_

## ►► CURRENT STATE — start here

### ★ Graphics-notice v2 = VERIFIED (the gate is cleared)
Noel ran `dotnet run` 2026-06-24: heard the graphics notice, **Continue took him to
the menu, and the menu was arrow-navigable to single player**. So the FrontEndPopup
re-route works and the dead-arrows blocker is gone. The whole "next session" plan was
gated on this — now unblocked.

### ★ This session: Accessibility settings tab + standardized menu nav (BUILT, UNTESTED)

**1. Standardized the Options nav keys** (`OptionsAccess.lua` `OnInput`) to the
standard Windows tab-dialog model Noel asked for:
- **`Ctrl+Tab` / `Ctrl+Shift+Tab`** = switch tab page (NEW)
- **`Tab` / `Shift+Tab`** = next / prev setting within a tab (NEW — was: bare Tab
  switched tabs)
- **`Up`/`Down`** (settings) and **`PageUp`/`PageDown`** (tabs) KEPT as reliable
  aliases. Left/Right still = value adjust (NOT remapped to tabs — would collide with
  sliders). `Ctrl+Left/Right` = big step. F1 = help. Esc = close.
- **Known risk = Shift ghosting on the Options context** (the reason PageUp/PageDown
  existed). So `Ctrl+Shift+Tab` backward is the at-risk piece; PageUp is the
  guaranteed fallback. **`TAB_DIAG = true`** in OptionsAccess logs the message forms
  each Tab chord delivers (`OPT_TAB msg=… key=… ctrl=… shift=…`) — read Lua.log to
  confirm Ctrl+Tab/Ctrl+Shift+Tab actually arrive, THEN strip TAB_DIAG and (if solid)
  retire the fallbacks.

**2. First Accessibility settings tab** — a **virtual tab** in the Options screen
(no base panel; handled entirely in `OptionsAccess`). Architecture:
- New **`choice`** item kind: ordered value list + `get`/`set` closures (no base
  control). `isItemUsable` now treats control-less items as usable.
- Virtual tab lives at `m_accessTabIdx = #m_tabs + 1`; reached by the same
  Ctrl+Tab / PageUp-Down cycle. `switchToTab` special-cases it
  (`showAccessTabVisual` hides base panels, sets the window title, hides Reset).
  Items = the settings + Confirm + Close (no Reset — it'd reset BASE options).
- **Residents (first cut): Verbosity (terse/chatty), Direction vocabulary
  (hex/compass/clock/degrees).**
- **Persistence** via `Options.SetAppOption("Misc", "CivViAccess_*", int)` — the same
  store the graphics flag round-trips through (proven to survive relaunch; no explicit
  SaveOptions). Verbosity = 1/0; DirMode = 1-based index into `HexGeom.MODE_ORDER`.
- **Cross-context propagation:** `HexGeom.setDirectionMode`/`cycleDirectionMode` now
  **broadcast `LuaEvents.CivViAccess_DirectionModeChanged`** (mirroring Verbosity), so
  setting it from Options reaches the cursor/scanner VM — and Shift/Ctrl+D now syncs
  every context too. HexGeom self-installs the sync listener (guarded vs re-include).
- **Boot-time apply:** `HexCursorAddin.OnLoadScreenClose` re-applies the persisted
  values at world load (the addin loads at start; the Options companion is lazy).

Files: `OptionsAccess.lua`, `HexGeom.lua`, `HexCursorAddin.lua`,
`CivVIAccessStrings.xml` (9 new LOC rows). No modinfo change (no new file; strings file
already registered). XML re-validated (128 rows). Lua hand-reviewed (no linter).

### ►► MORNING TEST SCRIPT (do this first)
1. `dotnet run --project C:\dev\civ-vi-access\CivViAccess`
2. Open **Options** (main menu or in-game Esc). Tab nav: **`Ctrl+Tab` /
   `Ctrl+Shift+Tab`** should move between tab pages; **`Tab` / `Shift+Tab`** should move
   between settings within a tab. (PageUp/PageDown + Up/Down still work as before.)
3. Cycle to the **last tab → "Accessibility"**. You should hear "Accessibility tab" then
   "Verbosity, terse". Down/Tab to "Direction vocabulary, hex".
4. On a setting, **Left/Right or Enter** changes the value (Verbosity terse↔chatty;
   Direction hex→compass→clock→degrees). Close, reopen Options → the value should
   **persist**. Quit + relaunch + start a game → the value should **still be applied**
   (boot-time apply) — e.g. set Direction to compass, then in-game where-am-I should
   speak compass bearings.
5. **Grep Lua.log for `OPT_TAB`** to confirm which forms Ctrl+Tab / Ctrl+Shift+Tab
   deliver. If Ctrl+Shift+Tab backward works, we can retire the PageUp fallback; either
   way **strip `TAB_DIAG`** after.

### Coordinate mode = deferred (needs Noel's UX call)
Noel picked Verbosity + Direction + **Coordinate mode** for the first cut, but
Coordinate mode is **not a wired toggle today** — coords are spoken via
`HexGeom.absoluteCoords()` directly; `relativeToCapital()` exists only as an unused
helper. So it's a small FEATURE: define what the capital-relative readout SAYS (Noel's
SR-UX call — direction-decomposed "5 east, 3 southeast of capital"? grid offset
"+5, -3"?), add a `HexGeom` coord-mode flag + broadcast, thread it through the
where-am-I paths (HexCursor 558/572/603/616/676, ScreenReaderPlotUtils 144). Add as the
3rd `choice` resident once Noel specs the readout.

## ►► NEXT (Noel's plan 2026-06-24, in order)
1. **Playtest** the Accessibility tab + nav keys (script above). Reword LOC if needed.
2. **Coordinate mode** — once Noel specs the relative readout (above).
3. **Sweep the rest of the menus** — audit every front-end + Options screen for gaps
   (KeyBindings tab still a stub: `KEYBINDINGS_ITEMS = {}`). Graphics Advanced sub-panel
   still unenumerated.
4. **camm: ship Prism only** — drop the Tolk-bridge embed (`CivViAccess.csproj` glob
   `..\camm\third_party\tolk\dist\x64\*.dll`); NVDA path needs no sidecar DLL.
5. **Recompile Prism** — bump the pinned `camm/third_party/prism` submodule to last
   week's upstream + rebuild from source (C toolchain present on this machine).
6. **Minor version bump** (one batch) AFTER menu + camm changes. ⚠️ Reconcile with the
   pending 0.8.0 gate (builder "last-charge" fix + `CHARGE_DEBUG` strip): either fold it
   in or ship 0.8.0 first — Noel's call at tag time. ⚠️ **submodule-publish-before-tag**:
   commit+push camm + bump gitlink + push BEFORE tagging, or Release CI fails.
7. Then → **playability / playthrough**.

## ►► STILL PENDING (dev): 0.8.0 release gate — UNCHANGED since 2026-06-14
`CHARGE_DEBUG` gate on the builder "last charge" fix, then tag 0.8.0 (bump csproj +
CHANGELOG). See `docs/TASK_PLAN.md` `►► 0.8.0 BATCH`.

## Strip-before-release debug
- **`TAB_DIAG`** in `OptionsAccess.lua` — NEW; KEEP through the nav-key live test, then
  strip.
- Existing: `CHARGE_DEBUG`, `DiploDebugMeet`, Alt+M DiploProbe, `POSTFOUND_DIAG`.
  (The MainMenu `[DIAG 2026-06-23]` can be stripped now — graphics v2 verified.)
