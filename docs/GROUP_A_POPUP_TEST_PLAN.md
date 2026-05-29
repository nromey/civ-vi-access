# Group A Popup — Test Plan (2026-05-29)

Fill-in checklist for validating all 10 Group A reveal popups. Raise each via
the cross-VM debug harness (no FireTuner state-combo needed — works from any
state, e.g. "Main State").

## Setup

0. **RELAUNCH via the launcher first.** The running game has OLD code — today's
   framing + raisers + NW descriptions only deploy when the launcher runs. Close
   the game, relaunch `CivViAccess.exe`, then start fresh.
1. New game, **Gathering Storm** ruleset, and in AdvancedSetup → **Game Modes**
   enable **Heroes & Legends** AND **Secret Societies** (modes stack — turn on
   both). Get in-game past the first turn.
2. Attach FireTuner2:
   `...\Sid Meier's Civilization VI SDK\FireTuner\FireTuner2.exe`
3. Raise a popup from any state (state combo NOT needed):
   `LuaEvents.CivViAccess_DebugRaisePopup("<Name>")`
4. Keys to test on each popup: **T** (re-read), **I** (full visual
   description — where noted), **Enter** and **Esc** (dismiss).

## Quick raise commands (copy-paste, any FireTuner state)

```
LuaEvents.CivViAccess_DebugRaisePopup("NaturalWonder")
LuaEvents.CivViAccess_DebugRaisePopup("WonderBuilt")
LuaEvents.CivViAccess_DebugRaisePopup("ProjectBuilt")
LuaEvents.CivViAccess_DebugRaisePopup("BoostUnlocked")
LuaEvents.CivViAccess_DebugRaisePopup("TechCivic")
LuaEvents.CivViAccess_DebugRaisePopup("EraComplete")
LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
LuaEvents.CivViAccess_DebugRaisePopup("RockBand")
LuaEvents.CivViAccess_DebugRaisePopup("Heroes")
LuaEvents.CivViAccess_DebugRaisePopup("SecretSociety")
```

For each popup, jot what you heard and Y/N per key. If anything crashes, grab
the Lua.log tail.

---

## 1. NaturalWonder  — `DebugRaisePopup("NaturalWonder")`  [base]
Expect: *"Natural wonder discovered. \<NAME>. \<effects>. Press I for the full natural wonder description. Press Enter to dismiss."* (quote voiced by game, not duplicated)
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____
- I reads description? ____  **(NOW LIVE — 33/34 wonders. Press I → evocative visual description. Paititi is the one not yet described.)**
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 2. WonderBuilt  — `DebugRaisePopup("WonderBuilt")`  [base]
Expect: *"World wonder completed. \<NAME>. \<effects>. Press Enter to dismiss."* (quote voiced, skipped)
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____
- I reads description? ____  (NA until WorldWonderDescriptions.xml ships)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 3. ProjectBuilt  — `DebugRaisePopup("ProjectBuilt")`  [base]
Expect: *"Project completed. \<NAME>. \<effects>. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____      (no I — projects have no visual description)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 4. BoostUnlocked  — `DebugRaisePopup("BoostUnlocked")`  [base]
Expect: *"Eureka. \<cause>. \<progress>. Press Enter to dismiss."* (tech boost; civic boost says "Inspiration")
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____      (no I — boosts have no visual)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 5. TechCivic  — `DebugRaisePopup("TechCivic")`  [base]
Expect: *"Technology researched. \<NAME>. \<unlock summary>. Press Enter to dismiss."* (quote voiced, skipped; civic says "Civic completed")
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____      (no I — abstract)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 6. EraComplete  — `DebugRaisePopup("EraComplete")`  [needs Rise & Fall / Gathering Storm]
Expect: *"New era. \<ERA NAME>. \<age verdict e.g. Golden Age>. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____      (no I — era art is abstract)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 7. NaturalDisaster  — `DebugRaisePopup("NaturalDisaster")`  [Gathering Storm]
Expect: *"Natural disaster. \<type / losses>. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____      (no I — cinematic scene)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 8. RockBand  — `DebugRaisePopup("RockBand")`  [Gathering Storm]
Expect: *"Rock band concert. \<band name>. Rock band level N. N tourism gained. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____      (no I — cinematic scene)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 9. Heroes  — `DebugRaisePopup("Heroes")`  [Heroes & Legends mode]
Expect: *"Hero discovered. \<message>. Press Enter to dismiss."* (also "Hero lost" / "Hero defeated" in real play)
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____
- I reads description? ____  (NA until HeroDescriptions.xml ships)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

## 10. SecretSociety  — `DebugRaisePopup("SecretSociety")`  [Secret Societies mode]
Expect: *"Secret society joined. \<title / desc>. Press Enter to dismiss."* (also "Secret society discovered" in real play)
- Spoke on open? ____  (heard: ____________________)
- T re-reads? ____
- I reads description? ____  (NA until SecretSocietyDescriptions.xml ships)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________

---

## Known caveats
- **Camera popups** (NaturalWonder, WonderBuilt, RockBand, NaturalDisaster)
  fly the camera to a plot; the raisers use your selected unit's coords so the
  engine has a valid plot (avoids the native crash we hit with `-1,-1`).
- **Within ~2s of open**, T re-read may queue behind the critical open-announce
  (the open's 2000ms shield). After the announce settles it interrupts cleanly.
- **I (description)** is NA everywhere until the describer XMLs ship; once they
  do, the "Press I…" hint will appear in the open announce for NW/WW/Heroes/SS.
- If a DLC popup raise does nothing, confirm its mode/expansion is active (the
  raiser early-returns when the mode's API is absent).
