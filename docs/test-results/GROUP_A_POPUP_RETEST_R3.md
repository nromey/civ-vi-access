# Group A Popup — Retest ROUND 3

Only **6 popups** to test this round. The other four (NaturalWonder, WonderBuilt,
BoostUnlocked, TechCivic) are settled — their code is unchanged since round 2 and
verified passing, so **skip them.**

What changed since round 2:
- 5 DLC popups: `ReplaceUIScript` is now `criteria`-gated (round 2 it was ungated
  and no-op'd). Should now load + announce.
- ProjectBuilt: input-context recovery added to its dismiss path. Should no longer
  soft-lock.

## Setup
1. **Relaunch the launcher** (redeploys today's modinfo + Lua). Close the game first.
2. New game, **Gathering Storm**, AdvancedSetup → Game Modes: enable **Heroes &
   Legends** AND **Secret Societies**. Get past turn 1.
3. Attach FireTuner2.

## STEP 1 — the load check (do this first, before raising anything)

After the game loads (modes on), check Lua.log for our wrapper loading. In round 2
only the 5 base popups logged it; all 5 DLC ones should now appear too.

Search Lua.log for:  `RevealPopupAccess.lua: loaded`

Which of these 5 prefixes now appear? (Y/N each)
- `EraCompletePopup:`  ____
- `NaturalDisasterPopup:`  ____
- `RockBandMoviePopup:`  ____
- `HeroesPopup:`  ____
- `SecretSocietyPopup:`  ____

(If any are still missing, that one's criteria is off — tell me which.)

## STEP 2 — raise the 5 DLC popups

```
LuaEvents.CivViAccess_DebugRaisePopup("EraComplete")
```
- speaks? ____  Enter/Esc dismiss (no soft-lock)? ____
no speak no run

```
LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
```
- speaks? ____  dismiss? ____
nope

```
LuaEvents.CivViAccess_DebugRaisePopup("RockBand")
```
- speaks? ____  dismiss? ____
nope
```
LuaEvents.CivViAccess_DebugRaisePopup("Heroes")
```
nope
- speaks? ____  **I reads the hero visual description?** ____  dismiss? ____

```
LuaEvents.CivViAccess_DebugRaisePopup("SecretSociety")
```
- speaks? ____  **I reads the society visual description?** ____  dismiss? ____
nope
## STEP 3 — ProjectBuilt (the soft-lock fix)

```
LuaEvents.CivViAccess_DebugRaisePopup("ProjectBuilt")
```
- speaks? ____
yep
- **dismiss with Esc/Enter WITHOUT soft-lock?** ____  (round 2 this needed alt+F4;
  it may still log a harmless WARN about "no active lock" — that's expected)
- after dismiss, do arrow keys / unit cycling work normally again? ____

## Notes / anything that crashed
(I'll pull Lua.log directly — just tell me roughly what happened)
