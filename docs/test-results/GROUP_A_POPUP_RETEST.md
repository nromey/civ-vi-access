# Group A Popup — Retest (round 2, after 2026-05-29 fixes)

Focused on what changed since round 1. **Relaunch the launcher first** (dev-mode
redeploys today's Lua + the 3 new description XMLs + the modinfo
ReplaceUIScript change). New GS game, **Heroes & Legends + Secret Societies**
both on, get past turn 1, attach FireTuner2.

Raise from any state:  `LuaEvents.CivViAccess_DebugRaisePopup("<Name>")`

## THE BIG ONE — did the 5 DLC popups start loading?

Round 1 they were silent because `ImportFiles` can't override a DLC-provided
UI context; switched to `ReplaceUIScript`. **Fastest check:** right after the
game loads (modes on), grep Lua.log — each of these should now log our wrapper:

```
RevealPopupAccess.lua: loaded
```

…prefixed by `EraCompletePopup:`, `NaturalDisasterPopup:`, `RockBandMoviePopup:`,
`HeroesPopup:`, `SecretSocietyPopup:`. In round 1 only the 5 base popups logged
it. If all 10 now log it → the replace took. If a DLC one is still missing →
tell me which; that one's context name or criteria is off (see fallback ideas).

Then raise each and confirm it speaks:

```
LuaEvents.CivViAccess_DebugRaisePopup("EraComplete")
no read, no load
LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
no read, no load
LuaEvents.CivViAccess_DebugRaisePopup("RockBand")
no read, no loadLuaEvents.CivViAccess_DebugRaisePopup("Heroes")
LuaEvents.CivViAccess_DebugRaisePopup("SecretSociety")
no read, no load
```

- EraComplete — loads? ____  speaks? ____  Enter/Esc dismiss? ____
- NaturalDisaster — loads? ____  speaks? ____  dismiss? ____
- RockBand — loads? ____  speaks? ____  dismiss? ____
- Heroes — loads? ____  speaks? ____  **I reads hero description?** ____  dismiss? ____
- SecretSociety — loads? ____  speaks? ____  **I reads society description?** ____  dismiss? ____

## Double-dot fix (was on every popup)

Listen for ".." before the dismiss/instructions line — should be gone now.

```
LuaEvents.CivViAccess_DebugRaisePopup("NaturalWonder")
t reads, i reads, exits with enter, perfect. It's hard to hear the speech while NVDA is speaking, I think we'll need to sequence these.
LuaEvents.CivViAccess_DebugRaisePopup("WonderBuilt")
t reads, i reads, same as before```

- NaturalWonder — double-dot gone? ____  T re-reads? ____  **I reads desc?** ____  Enter dismiss? ____  Esc dismiss? ____
- WonderBuilt — double-dot gone? ____  **now has "Press I" + I reads desc?** ____ (WW XML now ships)  T? ____  Enter/Esc? ____

## Crash fixes

```
LuaEvents.CivViAccess_DebugRaisePopup("ProjectBuilt")
crash still occurs
LuaEvents.CivViAccess_DebugRaisePopup("TechCivic")
crashed again
```

- ProjectBuilt — dismiss no longer throws a runtime error? ____ (now pcall-guarded; may log a WARN about "no active lock" — that's expected under the harness)
- TechCivic — no `line 311` crash on raise? ____  speaks the tech/civic? ____  Enter dismiss? ____

## Sanity (should be unchanged from round 1 = passing)

```
LuaEvents.CivViAccess_DebugRaisePopup("BoostUnlocked")
It felt like I had to hit enter twice to get that to clear
```
- BoostUnlocked — speaks? ____  T? ____  Enter dismiss? ____

## Notes / anything that crashed
(paste Lua.log tail if needed)
	I tried pasting you'll have to pull it, I must have pressed an incoprrect key., Couldn't press escape at this state, I had to press alt+f4. I kept pressing enter and it would switch between warrior and settler. nhopefully you can pull the log.
	