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

### Hex cursor / world nav (existing — to be normalized toward Civ V during the migration)

- **Alt+Q/E/A/D/Z/C** — move the cursor one hex (the `Alt+` prefix is a *crutch*
  to dodge engine letter-bindings; once the capture-all migration lands we can
  drop it back to bare Q/E/A/D/Z/C like Civ V — task #14).
- **Shift+V** — verbosity toggle (terse / chatty).
- Info / readout keys (Ctrl+T re-read, Ctrl+I image, etc.) — **AUDIT TODO**:
  enumerate + classify + list here.
- Notification cycle — currently on mod InputActions. **PLANNED (Noel 2026-06-08):
  move to `[` / `]`** for notification review (RECLAIM from Prev/Next-city, which
  the scanner's Cities category supersedes; matches Civ V's bracket message-buffer
  convention). Trivial now under capture-all — consume `[`/`]` in the wrap, route
  to the notification reader. Civ V also uses `Ctrl+[` / `Ctrl+]` (jump to oldest/
  newest) and `Shift+[` / `Shift+]` (cycle filter) — borrow that ladder.

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
