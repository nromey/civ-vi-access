# Diplomacy rebuild — in-context wrap (no more "press Escape first")

Rebuilt 2026-06-04. Replaces the old `DiplomacyAccess` modal (a separate
AddUserInterfaces context that QueuePopup'd OVER the vanilla screen and competed
for input — that competition WAS the "press Escape first" bug). The fix copies
Civ V Access: get our code INSIDE the `DiplomacyActionView` context and wrap its
own input handler, so OUR handler IS the screen's. No modal, no popup stack, no
Escape.

## What ships

New files under `CivViAccessMod/Assets/UI/Replacements/`:
- `DiplomacyActionViewWrap.lua` — the wrap (the meat). Redefines `OnInputHandler`
  and re-registers it; wraps `PopulateStatementList` (OVERVIEW action menu) and
  `ApplyStatement` (CONVERSATION replies — the first-contact path) to build a
  navigable list and speak it. Selection routes back through the engine's own
  dispatch (`OnSelectInitialDiplomacyStatement` / `handler.OnSelectionButtonClicked`).
- `DiplomacyActionViewAccess.lua` / `_XP1.lua` / `_XP2.lua` — thin per-ruleset
  entry files. Each `include()`s the matching base / Expansion1 / Expansion2
  screen implementation (so it runs in our VM exactly as Firaxis built it) then
  `include()`s the wrap.

`CivViAccessMod.modinfo`:
- Added `<ActionCriteria>` for the three rulesets (`RULESET_STANDARD` /
  `_EXPANSION_1` / `_EXPANSION_2`).
- Added three `<ReplaceUIScript>` actions (LuaContext `DiplomacyActionView`),
  criteria-gated so the engine picks the right entry file, each with
  `<LoadOrder>1000</LoadOrder>` to apply AFTER the expansion's own replacement so
  ours wins the binding.
- Retired the old `DiplomacyAccess` (removed its ImportFiles line and
  AddUserInterfaces block; the `.lua`/`.xml` still ship for reference).

`DiploDebugMeet.lua` tamed to **one-shot**: forces a single real first contact on
the first eligible turn, then disarms (was every-turn, which wrecked a real game).
Reload the save to test again. `DEBUG_FORCE_MEET=true` still — flip/strip before
release.

## Speech, on a real first contact

`LeaderMeetAnnounce` (unchanged, separate addin VM) still speaks WHO + mood +
greeting on screen open. The wrap then speaks the reply options:
`"N replies. <option 1>, 1 of N. Up and down arrows to choose, Enter to select."`
Up/Down/Home/End navigate, Enter/Space select, Ctrl+T re-reads the leader's line,
Escape leaves (falls through to the vanilla close).

## THE RISK to confirm first: did our replacement win?

Two unknowns can only be settled live:
1. **Load order** — does our `ReplaceUIScript` (LoadOrder 1000) beat the
   expansion's for the `DiplomacyActionView` LuaContext?
2. **`LuaReplace` path** — `Assets/UI/Replacements/DiplomacyActionViewAccess*.lua`.
   If the engine can't resolve it, the entry file never loads.

### Diagnose from Lua.log (one open of diplomacy is conclusive)

Log path: `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`.
Open diplomacy (the one-shot force-meet, or the ribbon for a met leader), then
grep for `DiplomacyActionViewAccess` and `DiploWrap`:

- **`DiplomacyActionViewAccess: ENTRY loaded (...)`** → our ReplaceUIScript WON and
  the right ruleset file loaded. (Good — proceed.)
  - then **`DiploWrap: installed (...)`** → wrap is live; navigation should work.
  - then **`DiploWrap: CONVERSATION captured N replies`** on a first contact, or
    **`DiploWrap: OVERVIEW captured N options`** opening a met leader.
  - **`DiploWrap: screen impl globals missing`** → entry loaded but the screen
    `include()` failed (wrong impl name for this ruleset / not found). Check which
    ruleset is active vs which `ENTRY loaded` line printed.
- **NO `ENTRY loaded` line at all** after opening diplomacy → our replacement did
  NOT take. Either the expansion's ReplaceUIScript out-ordered us, the criteria
  didn't match this ruleset, or the `LuaReplace` path didn't resolve. Fallbacks,
  in order:
  1. Try `LuaReplace` without the `Assets/` prefix
     (`UI/Replacements/DiplomacyActionViewAccess_XP2.lua`).
  2. Bump `LoadOrder` higher, or add the expansions as `<Dependencies>`/
     `<References>` so we load after them.
  3. Last resort: ImportFiles-override the active expansion file by leaf name
     (the proven frontend-fork mechanism), shipping a copy of the small XP2/XP1
     top file + appended wrap.

If diplomacy still requires **Escape first** even though `DiploWrap: installed`
printed, that means input isn't reaching our wrapped handler — capture a Lua.log
and we look at whether the keys land (the wrap can be made to log every KeyUp).

## First live test — findings (2026-06-06, Gathering Storm)

Lua.log confirmed the machinery works: `ENTRY loaded (XP2 / Gathering Storm)` →
`DiploWrap: installed` → on opening diplomacy, `OVERVIEW captured 7 options` and
the emit `7 options. Declare Friendship, 1 of 7. ...`. So our ReplaceUIScript won
the binding under GS and the wrap captured the live list. Two issues surfaced:

1. **Options were never heard** — the leader greeting (`LeaderMeetAnnounce`,
   "critical") fired a beat after our options emit and clobbered it. FIXED: the
   list summary now builds immediately but speaks ~20 frames later at "status"
   (always-queues), so the greeting plays first, then the options. (Wrap:
   `scheduleAnnounce` / `speakList` via the screen's own `SetUpdate` tick.)
2. **Screen auto-closed before navigation** — tested via Alt+M during the turn-2
   popup storm (a *blocking* "Move a unit" notification + a queued Writing Eureka
   popup). Diplomacy opened via the lockless ribbon path (`m_eventID 0`) and got
   torn down (`Closing Diplomacy Action View. m_eventID: 0`) before any keys.
   This is the bad-harness trap, not our code. The forced `SetHasMet` only *fires
   a notification* — it does NOT auto-open the conversation screen.

**Retest, clean state:** resolve the turn-2 blockers first (move the unit, dismiss
the Eureka), THEN Alt+M — the overview should stay open and the 7 options be
navigable. For the real conversation/first-contact path, let an AI initiate
diplomacy over a few turns (persistent session). If the clean Alt+M still closes,
ask for a `DiplomacyManager.RequestSession`-based debug trigger.

## Known v1 scope / follow-ups

- **Deal / trade screen** (`MAKE_DEAL`) is intentionally skipped — separate
  deferred project (see `DIPLOMACY_PLAN.md`).
- **War declarations** route through the engine's confirm popup (so a stray Enter
  can't start a war); that popup (`DeclareWarPopup`) is not yet accessible.
- Overview submenus (Discuss / Casus Belli) get a synthetic navigable "Back".
- Speech ordering of greeting vs. options is a live-tune item (Noel's call).
