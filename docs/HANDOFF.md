# Handoff — latest session state

**This file is overwritten each session.** It holds "where we are right now."
Full history is in `git log` — don't make dated copies. The ordered plan is in
`docs/TASK_PLAN.md`; durable facts are in memory.

_Last updated: 2026-06-24 (long menu session: graphics v2 VERIFIED, then built
the Accessibility tab, Graphics Advanced, accessible KeyBindings, sighted/blind
designation, and the Prism-only ship. All committed, UNTESTED in-game.)_

## ►► CURRENT STATE — start here

Graphics-notice v2 is **VERIFIED** (Noel reached single player). On that green light
we did a full menu pass. Commits this session, all on `main`, none tagged:
- **68380e7** — Accessibility tab (Verbosity, Direction vocab) + standardized Options nav keys
- **69bedf7** — Graphics Advanced sub-panel + sighted/blind (global + per-player)
- **fb7369f** — Accessible KeyBindings (hotkey manager) tab
- **1d4c133** — Prism-only ship (drop Tolk native embed)

### What's built (all UNTESTED in-game; Lua hand-reviewed, XML validated, launcher builds)

1. **Standardized Options nav keys**: `Ctrl+Tab`/`Ctrl+Shift+Tab` = switch tab;
   `Tab`/`Shift+Tab` = move setting; `Up`/`Down` + `PageUp`/`PageDown` kept as reliable
   aliases. `TAB_DIAG=true` logs `OPT_TAB` to confirm the Ctrl chords arrive (strip after).
2. **Accessibility tab** (virtual tab, `choice` item kind, `SetAppOption` persistence,
   `HexGeom` direction-mode now broadcasts cross-context, boot-apply in HexCursorAddin):
   residents **Verbosity** (terse/chatty) + **Direction vocabulary** (hex/compass/clock/degrees).
3. **Graphics Advanced sub-panel**: all 21 advanced controls enumerated into `GRAPHICS_ITEMS`
   with a `gateControl` that hides them until the Advanced toggle is expanded; the toggle
   button uses `dynamicLabel` to announce its live Show/Hide caption. Control names + LOC
   keys taken from the base `Options.xml` (Steam install).
4. **Accessible KeyBindings tab** (was empty): dynamic list from `Input.GetAction*`, one
   `keybind` item per action. `Left/Right` switches gesture slot (primary/alternate),
   `Enter` records (reuses base `StartActiveKeyBinding` + capture popup; result announced via
   `InputGestureRecorded`), `Delete` clears. While the capture popup is open, `OnInput`
   passes all keys through.
5. **Sighted/blind designation** — wires the dormant keystone (`WorldInputAccessWrap`
   `_sighted` + `CivViAccess_SetSighted`, which already short-circuits capture-all to
   passthrough; nothing raised it before):
   - **Global** "Sighted mode" choice in the Accessibility tab (blind/sighted), persisted,
     fires the event live, boot-applied.
   - **Per-player** `VirtualCheckbox` in `AdvancedSetupAccess` player slots, persisted on
     `PlayerConfigurations` (`CIVVIACCESS_SIGHTED`). At world load the LOCAL player's value
     overrides the global and is broadcast to the wrap. **No speech gating yet — only flips
     input ownership.** Hotseat per-turn switching + speech gating are later content.
6. **Prism-only ship**: dropped the Tolk native embed from `CivViAccess.csproj`
   (`Tolk.dll` + `nvdaControllerClient64.dll` + `SAAPI64.dll`); `prism.dll` is the only
   speech file. **Launcher builds clean (verified, 0/0).** Tradeoff documented inline.

### ►► MORNING TEST SCRIPT (one pass covers everything)
1. `dotnet run --project C:\dev\civ-vi-access\CivViAccess`. (Speech still works → confirms
   the Prism-only drop didn't break the comm path.)
2. **Open Options.** `Ctrl+Tab`/`Ctrl+Shift+Tab` move between tabs; `Tab`/`Shift+Tab` move
   between settings. (`PageUp`/`PageDown` + `Up`/`Down` still work.)
3. **Accessibility tab** (last tab): hear "Accessibility", "Verbosity, terse". `Tab` →
   "Direction vocabulary, hex" → "Sighted mode, blind". Change each (`Left/Right`/`Enter`).
   Close/reopen → persists. Set Direction = compass; quit + relaunch + start a game →
   in-game where-am-I speaks compass bearings (boot-apply).
4. **Graphics tab** → arrow to "Show advanced graphics", `Enter` → it expands; arrow down
   into VSync / shadows / terrain / water / leader quality etc. (≈21 controls). Toggle a few.
5. **KeyBindings tab**: arrow the action list; each reads "Action, primary, <gesture>".
   `Left/Right` to "alternate". `Enter` → "Press a key combination, or Escape to cancel" →
   press a combo → hear it bound. `Delete` clears a slot. `Escape` mid-record cancels.
6. **Sighted mode**: set "Sighted mode → sighted" in the Accessibility tab; in-game the
   whole keyboard should pass through to the engine (mod keys stop responding). Set back to
   blind. (Per-player: in Advanced Setup, each player slot has a "Sighted player" checkbox;
   verify it reads/sets. The local player's setup choice applying in-game is the one thing
   to VERIFY LIVE — PlayerConfigurations custom-key survival isn't guaranteed.)
7. **Grep Lua.log for `OPT_TAB`** → confirm Ctrl+Tab/Ctrl+Shift+Tab forms, then strip `TAB_DIAG`.

### Verify-live unknowns (call these out in testing)
- `Ctrl+Shift+Tab` backward (Shift ghosting) — PageUp is the fallback if it misfires.
- KeyBindings: does our `OnInput` pass-through-while-popup-open cleanly capture a combo that
  includes keys we normally own (arrows/Enter)? The popup-hidden check should cover it.
- Per-player sighted: does `PlayerConfigurations:SetValue("CIVVIACCESS_SIGHTED")` survive
  setup→running game? If `pv` is nil in-game, fall back to a mod-side table seeded at start.

## ►► NEXT (Noel's plan 2026-06-24, remaining)
1. **Playtest** the above; reword any LOC.
2. **Coordinate mode** (3rd Accessibility resident) — NEEDS Noel's UX call: relative readout
   = direction-decomposed ("5 east, 3 southeast of capital") or grid offset ("+5, −3")?
   Then add a `HexGeom` coord-mode flag + broadcast + thread through where-am-I
   (HexCursor 558/572/603/616/676, ScreenReaderPlotUtils 144).
3. **Prism recompile + version bump** (the camm step): bump the pinned
   `camm/third_party/prism` submodule to last week's upstream, rebuild, **then** version
   bump as one batch. ⚠️ submodule-publish-before-tag. ⚠️ reconcile with the pending 0.8.0
   gate (builder last-charge fix + `CHARGE_DEBUG` strip). ⚠️ **add the loud "no speech
   backend" diagnostic to camm `ScreenReaderFactory` before a release ships the Tolk drop.**
4. Then → playability / playthrough.

### Menu gaps still open (from this session's audit — for the next menu pass)
- **Save-game filename entry** (S–M): mouse-only; needs the SR text-entry primitive (also
  unblocks Options editboxes + My2K login). Highest-value remaining single-player gap.
- **Missing standalone screens** (no companion): MP **Lobby / StagingRoom / CrossPlay /
  My2K login**, **Mods** browser, **Credits**, **Benchmark**. MP cluster gated on MP scope.
- Graphics Advanced is now filled; KeyBindings now accessible.

## Strip-before-release debug
- **`TAB_DIAG`** in `OptionsAccess.lua` — keep through the nav-key live test, then strip.
- Existing: `CHARGE_DEBUG`, `DiploDebugMeet`, Alt+M DiploProbe, `POSTFOUND_DIAG`. The
  MainMenu `[DIAG 2026-06-23]` can be stripped now (graphics v2 verified).
