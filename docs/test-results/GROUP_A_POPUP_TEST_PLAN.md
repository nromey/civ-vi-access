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
yes
- T re-reads? ____
no
- I reads description? ____  **(NOW LIVE — 33/34 wonders. Press I → evocative visual description. Paititi is the one not yet described.)**
no
- Enter dismisses? ____   Esc dismisses? ____
enter did not dismiss but escape did. It read, but tehre were double .. (we removed tehm before, still not receiving input
- Crash / notes: ____________________
no crash

## 2. WonderBuilt  — `DebugRaisePopup("WonderBuilt")`  [base]
Expect: *"World wonder completed. \<NAME>. \<effects>. Press Enter to dismiss."* (quote voiced, skipped)
- Spoke on open? ____  (heard: ____________________)
yes
- T re-reads? ____
yes actually, still a double dot before the ionstructions
- I reads description? ____  (NA until WorldWonderDescriptions.xml ships)
no
- Enter dismisses? ____   Esc dismisses? ____
yes and yes
- Crash / notes: ____________________
none

## 3. ProjectBuilt  — `DebugRaisePopup("ProjectBuilt")`  [base]
Expect: *"Project completed. \<NAME>. \<effects>. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
yes


- T re-reads? ____      (no I — projects have no visual description)
- Enter dismisses? ____   Esc dismisses? ____
yes
- Crash / notes: ____________________
no

## 4. BoostUnlocked  — `DebugRaisePopup("BoostUnlocked")`  [base]
Expect: *"Eureka. \<cause>. \<progress>. Press Enter to dismiss."* (tech boost; civic boost says "Inspiration")
- Spoke on open? ____  (heard: ____________________)
yes
spoke on open
- T re-reads? ____ yes      (no I — boosts have no visual)
- Enter dismisses? ____   Esc dismisses? ____
enter dismissed
- Crash / notes: ____________________
none

## 5. TechCivic  — `DebugRaisePopup("TechCivic")`  [base]
Expect: *"Technology researched. \<NAME>. \<unlock summary>. Press Enter to dismiss."* (quote voiced, skipped; civic says "Civic completed")
- Spoke on open? ____  (heard: ____________________)
spoke
- T re-reads? ____      (no I — abstract)
t reread
- Enter dismisses? ____   Esc dismisses? ____
enter dismissed
- Crash / notes: ____________________
none

## 6. EraComplete  — `DebugRaisePopup("EraComplete")`  [needs Rise & Fall / Gathering Storm]
Expect: *"New era. \<ERA NAME>. \<age verdict e.g. Golden Age>. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
didn't speak on open
'- T re-reads? ____      (no I — era art is abstract)
t did not read, didn't speak
- Enter dismisses? ____   Esc dismisses? ____
enter did dismiss
- Crash / notes: ____________________
none

## 7. NaturalDisaster  — `DebugRaisePopup("NaturalDisaster")`  [Gathering Storm]
Expect: *"Natural disaster. \<type / losses>. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
no, it doesn't appear to have loaded (See the notes which I' will paste at the end
- T re-reads? ____      (no I — cinematic scene)
no scinematic or any read
- Enter dismisses? ____   Esc dismisses? ____
none
- Crash / notes: ____________________
It just attempted load and nothing happened. Notes: LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster") 
## 8. RockBand  — `DebugRaisePopup("RockBand")`  [Gathering Storm]
Expect: *"Rock band concert. \<band name>. Rock band level N. N tourism gained. Press Enter to dismiss."*
- Spoke on open? ____  (heard: ____________________)
no speak, no cinematic
- T re-reads? ____      (no I — cinematic scene)
no
- Enter dismisses? ____   Esc dismisses? ____
none, did teh same as previous, just shows a greater than sign and the lua
- Crash / notes: ____________________
## 9. Heroes  — `DebugRaisePopup("Heroes")`  [Heroes & Legends mode]
Expect: *"Hero discovered. \<message>. Press Enter to dismiss."* (also "Hero lost" / "Hero defeated" in real play)
- Spoke on open? ____  (heard: ____________________)
no heard, still as before- T re-reads? ____
- I reads description? ____  (NA until HeroDescriptions.xml ships)
- Enter dismisses? ____   Esc dismisses? ____
- Crash / notes: ____________________
same, no read no dismiss etc.
## 10. SecretSociety  — `DebugRaisePopup("SecretSociety")`  [Secret Societies mode]
Expect: *"Secret society joined. \<title / desc>. Press Enter to dismiss."* (also "Secret society discovered" in real play)
- Spoke on open? ____  (heard: ____________________)
no, same as past previous
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
Total log from this run:
Hi!  Nice to see you again.
[ Lua State = Main State ]
 MainMenu: #SCREENREADER[kind=picker] - Multiplayer
 MainMenu: #SCREENREADER[kind=picker] - Single Player
 MainMenu: #SCREENREADER[kind=event] - Single Player, activated
 MainMenu: #SCREENREADER[NOINTERRUPT,kind=picker] - Resume Game
 MainMenu: #SCREENREADER[kind=picker] - Load Game
 MainMenu: #SCREENREADER[kind=picker] - Play Now
 MainMenu: #SCREENREADER[kind=picker] - Load Game
 MainMenu: #SCREENREADER[kind=picker] - Play Now
 MainMenu: #SCREENREADER[kind=picker] - Scenarios
 MainMenu: #SCREENREADER[kind=picker] - Create Game
 MainMenu: #SCREENREADER[kind=event] - Create Game, activated
 AdvancedSetup: There are 6 participating players.
 AdvancedSetup: Building Game Setup
 AdvancedSetup: Player Count Changed
 AdvancedSetup: There are 6 participating players.
 AdvancedSetup: Player Count Changed
 AdvancedSetup: There are 6 participating players.
 AdvancedSetup: [CivViAccess][DEBUG] HandlerStack.push 'AdvancedSetup' (depth=1)
 AdvancedSetup: [CivViAccess][INFO ] BaseMenu.onActivate [AdvancedSetup]: called, _initialized=false
 AdvancedSetup: [CivViAccess][INFO ] BaseMenu.onActivate [AdvancedSetup]: first-init, items count=34
 AdvancedSetup: #SCREENREADER[kind=picker] - Create Game
 AdvancedSetup: #SCREENREADER[NOINTERRUPT,kind=status] - ruleset, Expansion: Gathering Storm
 AdvancedSetup: There are 6 participating players.
 JoiningRoom: OnFinishedGameplayContentConfigure() g_waitingForContentConfigure=true
 AdvancedSetup: #SCREENREADER[kind=picker] - game difficulty, Prince
 AdvancedSetup: #SCREENREADER[kind=picker] - start era, Ancient Era
 AdvancedSetup: #SCREENREADER[kind=picker] - game difficulty, Prince
 AdvancedSetup: #SCREENREADER[kind=picker] - ruleset, Expansion: Gathering Storm
 AdvancedSetup: #SCREENREADER[kind=picker] - Start Game
 AdvancedSetup: #SCREENREADER[kind=picker] - BACK
 AdvancedSetup: #SCREENREADER[kind=picker] - RESTORE DEFAULTS
 AdvancedSetup: #SCREENREADER[kind=picker] - Victory Conditions, submenu, 6 items
 AdvancedSetup: #SCREENREADER[kind=picker] - Game Modes, submenu, 8 items
 AdvancedSetup: #SCREENREADER[kind=picker] - apocalypse mode, unchecked. this game mode adds new natural disasters, larger and more impactful versions of existing disasters, and increases the chances of all natural disasters. apocalypse mode also adds the soothsayer unit to the game, and should the climate reach its final level of change, comets pummel the earth and destroy humanity
 AdvancedSetup: #SCREENREADER[kind=picker] - barbarian clans mode, unchecked. this game mode replaces standard barbarian tribes with a diverse set of clans, each with its own terrain and combat preferences. additionally, the mode introduces new player actions for peaceful interactions with barbarians that provide increased strategic options
 AdvancedSetup: #SCREENREADER[kind=picker] - dramatic ages mode, unchecked. this game mode makes dark ages and golden ages more potent than ever. heroic ages are removed, and players can only be in a normal age in the first era. after that, they will either earn a dark or a golden age.[newline][newline]instead of making dedications, players get access to powerful new social policies based on their age. dark policies make a return with refreshed powerful effects. brand new golden policies are available to those who make it to a golden age. to keep earning era score, complete techs and civics and earn military unit promotions.[newline][newline]dark ages are particularly dangerous. players in dark ages will have a portion of their empire immediately fall into free cities, and free cities can exert pressure on other cities. on easier difficulty settings, ai players lose a lot of cities. on harder difficulty settings, human players do. on prince, they lose an equal amount.[newline][newline]georgia's civilization unique ability is brand new, to match the mode's unique rules
 AdvancedSetup: #SCREENREADER[kind=picker] - heroes & legends mode, unchecked. this game mode adds twelve powerful hero units from the world's myths and legends.[newline][newline]discover heroes by exploring the world and influencing city-states, then claim them in your cities. each hero is unique in the world and can be claimed by just one civilization.[newline][newline]heroes possess great power and unique abilities, but also a limited lifespan. whenever a hero appears, they remain for a set number of turns before their time is up and they naturally expire. after a hero is gone, however, their claiming civilization can recall them by spending faith.[newline][newline]each of the twelve heroes has their own special powers and distinct role. in the hands of a wise player, the right hero can truly be a game-changing force!
 AdvancedSetup: #SCREENREADER[kind=picker] - heroes & legends mode, checked
 AdvancedSetup: #SCREENREADER[kind=picker] - monopolies and corporations mode, unchecked. control, improve, and expand upon your luxury resources! the monopolies and corporations mode enables you to build profitable industries around luxury resources, found corporations to further their development, and manufacture unique products to secure your place in capitalist history
 AdvancedSetup: #SCREENREADER[kind=picker] - secret societies mode, unchecked. this game mode adds up to four powerful, mysterious, and often nefarious secret societies to the world, each based upon fictional or mythical organizations from the past. their traces can be found in barbarian camps, tribal villages, or by sending envoys to city-states and finding natural wonders. alternatively, if other leaders have discovered a society, you can learn about them by increasing your diplomatic visibility levels with them.[newline][newline]discovering a society does not mean joining it automatically, but it unlocks a new governor that does not need to be assigned to a city. spending a governor title on this governor means joining the society, giving you powerful bonuses. but choose wisely - once you appoint that governor, you commit to membership for the rest of the game, and other leaders will react to your decision. spend additional governor titles to prove your commitment to the society and unlock its deeper mysteries
 AdvancedSetup: #SCREENREADER[kind=picker] - secret societies mode, checked
 AdvancedSetup: #SCREENREADER[kind=picker] - tech and civic shuffle mode, unchecked. this game mode shuffles techs and civics within their historical eras, leading to different costs and prerequisites than normal. the resulting trees are the same for all players. techs and civics are also hidden until a prerequisite is earned, preserving the mystery of discovery all the way until the end of the game
 AdvancedSetup: #SCREENREADER[kind=picker] - zombie defense mode, unchecked. in this game mode, the dead rise to wreak havoc among the living! use new defensive structures to protect your territory, and manipulate zombies to slow your opponents
 AdvancedSetup: #SCREENREADER[kind=picker] - apocalypse mode, unchecked. this game mode adds new natural disasters, larger and more impactful versions of existing disasters, and increases the chances of all natural disasters. apocalypse mode also adds the soothsayer unit to the game, and should the climate reach its final level of change, comets pummel the earth and destroy humanity
 AdvancedSetup: #SCREENREADER[kind=picker] - zombie defense mode, unchecked. in this game mode, the dead rise to wreak havoc among the living! use new defensive structures to protect your territory, and manipulate zombies to slow your opponents
 AdvancedSetup: #SCREENREADER[kind=picker] - tech and civic shuffle mode, unchecked. this game mode shuffles techs and civics within their historical eras, leading to different costs and prerequisites than normal. the resulting trees are the same for all players. techs and civics are also hidden until a prerequisite is earned, preserving the mystery of discovery all the way until the end of the game
 AdvancedSetup: #SCREENREADER[kind=picker] - zombie defense mode, unchecked. in this game mode, the dead rise to wreak havoc among the living! use new defensive structures to protect your territory, and manipulate zombies to slow your opponents
 AdvancedSetup: #SCREENREADER[kind=picker] - apocalypse mode, unchecked. this game mode adds new natural disasters, larger and more impactful versions of existing disasters, and increases the chances of all natural disasters. apocalypse mode also adds the soothsayer unit to the game, and should the climate reach its final level of change, comets pummel the earth and destroy humanity
 AdvancedSetup: #SCREENREADER[kind=picker] - barbarian clans mode, unchecked. this game mode replaces standard barbarian tribes with a diverse set of clans, each with its own terrain and combat preferences. additionally, the mode introduces new player actions for peaceful interactions with barbarians that provide increased strategic options
 AdvancedSetup: #SCREENREADER[kind=picker] - dramatic ages mode, unchecked. this game mode makes dark ages and golden ages more potent than ever. heroic ages are removed, and players can only be in a normal age in the first era. after that, they will either earn a dark or a golden age.[newline][newline]instead of making dedications, players get access to powerful new social policies based on their age. dark policies make a return with refreshed powerful effects. brand new golden policies are available to those who make it to a golden age. to keep earning era score, complete techs and civics and earn military unit promotions.[newline][newline]dark ages are particularly dangerous. players in dark ages will have a portion of their empire immediately fall into free cities, and free cities can exert pressure on other cities. on easier difficulty settings, ai players lose a lot of cities. on harder difficulty settings, human players do. on prince, they lose an equal amount.[newline][newline]georgia's civilization unique ability is brand new, to match the mode's unique rules
 AdvancedSetup: #SCREENREADER[kind=picker] - barbarian clans mode, unchecked. this game mode replaces standard barbarian tribes with a diverse set of clans, each with its own terrain and combat preferences. additionally, the mode introduces new player actions for peaceful interactions with barbarians that provide increased strategic options
 AdvancedSetup: #SCREENREADER[kind=picker] - apocalypse mode, unchecked. this game mode adds new natural disasters, larger and more impactful versions of existing disasters, and increases the chances of all natural disasters. apocalypse mode also adds the soothsayer unit to the game, and should the climate reach its final level of change, comets pummel the earth and destroy humanity
 AdvancedSetup: #SCREENREADER[kind=picker] - Game Modes, submenu, 8 items
 AdvancedSetup: #SCREENREADER[kind=picker] - Players, submenu, 7 items
 AdvancedSetup: #SCREENREADER[kind=picker] - map random seed, -1686784996
 AdvancedSetup: #SCREENREADER[kind=picker] - game random seed, -1686784997
 AdvancedSetup: #SCREENREADER[kind=picker] - teams share visibility, checked
 AdvancedSetup: #SCREENREADER[kind=picker] - game random seed, -1686784997
 AdvancedSetup: #SCREENREADER[kind=picker] - map random seed, -1686784996
 AdvancedSetup: #SCREENREADER[kind=picker] - Players, submenu, 7 items
 AdvancedSetup: #SCREENREADER[kind=picker] - Game Modes, submenu, 8 items
 AdvancedSetup: #SCREENREADER[kind=picker] - Victory Conditions, submenu, 6 items
 AdvancedSetup: #SCREENREADER[kind=picker] - RESTORE DEFAULTS
 AdvancedSetup: #SCREENREADER[kind=picker] - BACK
 AdvancedSetup: #SCREENREADER[kind=picker] - Start Game
 JoiningRoom: OnFinishedGameplayContentConfigure() g_waitingForContentConfigure=true
 AdvancedSetup: Hiding Game Setup
 LoadScreen: [CivViAccess][INFO ] LoadScreenAccess: subscribed to InputActionTriggered
 LoadScreen: [CivViAccess][INFO ] LoadScreenAccess actions: repeat=97 abilities=88 portrait=96 transcript=89
 LoadScreen: [CivViAccess][INFO ] LoadScreenAccess.lua: loaded
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Creating game.
 LoadScreen: true
 LoadScreen: true
 LoadScreen: false
 LoadScreen: [CivViAccess][INFO ] LoadScreenAccess portrait lookup: leaderType='LEADER_RAMSES' key='LOC_CIVVIACCESS_LDR_LEADER_RAMSES_SHORT' result='A seated figure in a tall blue crown, depicted in profile, receives two supplica'
 LoadScreen: true
 LoadScreen: true
 LoadScreen: false
 LoadScreen: #SCREENREADER[kind=critical] - Egyptian Empire. Join the world stage.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Ancient Era.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Ramses II. A seated figure in a tall blue crown, depicted in profile, receives two supplicants before a wall of hieroglyphs, above a frieze of marching soldiers.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Unique abilities and features.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Abu Simbel. Gain Culture equal to 15%% of the construction cost when finishing Buildings and 30%% when completing Wonders.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Iteru. +15%% Production towards districts and wonders if placed next to a River. Does not receive damage from Floods.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Maryannu Chariot Archer. A unique land unit
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Sphinx. A unique improvement
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Press R to repeat the briefing. T re-reads abilities. I for leader description. S for Dawn of Man transcript.
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Press Enter to start the Dawn of Man speech, or Escape to skip to the game.
 Map Script: Generating Continents Map
 Map Script: Generating Plot Types
 Map Script: Existing Ratio	34.166666666667
 Map Script: New Mountains 	36
 Map Script: Mountain Set	37
 Map Script: Generating Terrain Types
 Map Script: -
 Map Script: - Desert Percentage:	25
 Map Script: --- Latitude Readout ---
 Map Script: - All Grass End Latitude:	0.1
 Map Script: - Desert Start Latitude:	0.2
 Map Script: - Desert End Latitude:	0.5
 Map Script: - Tundra Start Latitude:	0.65
 Map Script: - Snow Start Latitude:	0.8
 Map Script: - - - - - - - - - - - - - -
 Map Script: Expanding coasts
 Map Script: After Adding Hills: 	730
 Map Script: Desired Volcanoes: 4.92
 Map Script: Continent Boundary Plots: 152
 Map Script: Boundary Plots Per Volcano: 46.341463414634
 Map Script: Volcano Placed at (x, y): 17, 29
 Map Script: Volcano Placed at (x, y): 25, 26
 Map Script: Volcano Placed at (x, y): 28, 27
 Map Script: Continent Edge Volcanoes Placed: 3
 Map Script: Volcano Placed at (x, y): 57, 24
 Map Script: Volcano Placed at (x, y): 23, 38
 Map Script: Volcano Placed at (x, y): 26, 20
 Map Script: Total Volcanoes Placed: 6
 Map Script: Map Generation - Adding Rivers
 Map Script: Map Generation - Adding Lakes
 Map Script: 10 lakes added
 Map Script: Adding Features
 Map Script: Permanent Ice Tiles: 76.59
 Map Script: iPhaseIndex: 7, iIceTilesToAdd: 76.59, RandomEventEnum: 30
 Map Script: iPhaseIndex: 6, iIceTilesToAdd: 76.59, RandomEventEnum: 29
 Map Script: iPhaseIndex: 5, iIceTilesToAdd: 76.59, RandomEventEnum: 28
 Map Script: iPhaseIndex: 4, iIceTilesToAdd: 51.06, RandomEventEnum: 27
 Map Script: iPhaseIndex: 3, iIceTilesToAdd: 51.06, RandomEventEnum: 26
 Map Script: iPhaseIndex: 2, iIceTilesToAdd: 51.06, RandomEventEnum: 25
 Map Script: iPhaseIndex: 1, iIceTilesToAdd: 51.06, RandomEventEnum: 24
 Map Script: Number of Tiles: 	1008
 Map Script: Number of Forests: 	178
 Map Script: Percent Forests: 	17.65873015873
 Map Script: Number of Jungles: 	135
 Map Script: Percent Jungles: 	13.392857142857
 Map Script: Percent of Junglable: 	40.059347181009
 Map Script: Number of Marshes: 	28
 Map Script: Adding cliffs
 Map Script: In NaturalWonderGenerator.Create()
 Map Script:     Placing 4 Natural Wonders
 Map Script: Feature Type: 6, Valid Hexes: 16
 Map Script: Feature Type: 7, Valid Hexes: 0
 Map Script: Feature Type: 8, Valid Hexes: 40
 Map Script: Feature Type: 9, Valid Hexes: 6
 Map Script: Feature Type: 10, Valid Hexes: 0
 Map Script: Feature Type: 11, Valid Hexes: 22
 Map Script: Feature Type: 12, Valid Hexes: 7
 Map Script: Feature Type: 13, Valid Hexes: 16
 Map Script: Feature Type: 14, Valid Hexes: 2
 Map Script: Feature Type: 15, Valid Hexes: 21
 Map Script: Feature Type: 16, Valid Hexes: 87
 Map Script: Feature Type: 17, Valid Hexes: 6
 Map Script: Feature Type: 18, Valid Hexes: 31
 Map Script: Feature Type: 19, Valid Hexes: 4
 Map Script: Feature Type: 20, Valid Hexes: 0
 Map Script: Feature Type: 21, Valid Hexes: 72
 Map Script: Feature Type: 22, Valid Hexes: 1
 Map Script: Feature Type: 23, Valid Hexes: 26
 Map Script: Feature Type: 24, Valid Hexes: 16
 Map Script: Feature Type: 25, Valid Hexes: 45
 Map Script: Feature Type: 26, Valid Hexes: 10
 Map Script: Feature Type: 27, Valid Hexes: 28
 Map Script: Feature Type: 28, Valid Hexes: 2
 Map Script: Feature Type: 29, Valid Hexes: 0
 Map Script: Feature Type: 36, Valid Hexes: 34
 Map Script: Feature Type: 37, Valid Hexes: 146
 Map Script: Feature Type: 38, Valid Hexes: 21
 Map Script: Feature Type: 39, Valid Hexes: 29
 Map Script: Feature Type: 40, Valid Hexes: 119
 Map Script: Feature Type: 41, Valid Hexes: 11
 Map Script: Feature Type: 42, Valid Hexes: 13
 Map Script: Feature Type: 43, Valid Hexes: 115
 Map Script: Feature Type: 44, Valid Hexes: 133
 Map Script: Feature Type: 45, Valid Hexes: 24
 Map Script: Num wonders with valid location: 30
 Map Script:  Selected Wonder = 10, Random Score = 	99
 Map Script:  Set Wonder with Feature ID of 16 at location (14, 21)
 Map Script:  Selected Wonder = 22, Random Score = 	98
 Map Script:  Set Wonder with Feature ID of 28 at location (59, 7)
 Map Script:  Selected Wonder = 28, Random Score = 	93
 Map Script:  Set Wonder with Feature ID of 40 at location (50, 28)
 Map Script:  Selected Wonder = 6, Random Score = 	92
 Map Script:  Set Wonder with Feature ID of 12 at location (31, 38)
 Map Script: Adding Features from Continents
 Map Script: Fissure Placed at (x, y): 10, 31
 Map Script: Fissure Placed at (x, y): 15, 28
 Map Script: Fissure Placed at (x, y): 29, 29
 Map Script: Fissure Placed at (x, y): 11, 31
 Map Script: Fissure Placed at (x, y): 18, 31
 Map Script: Fissure Placed at (x, y): 24, 25
 Map Script: Number of Oasis: 	2
 Map Script: Number of Fissures: 	6
 Map Script: Map Generation - Marking Coastal Lowlands
 Map Script: 81 Coastal Lowland tiles added
 Map Script:   45% of eligible coastal tiles
 Map Script: In ResourceGenerator.Create()
 Map Script:     Placing resources
 Map Script: Creating start plot database.
 Map Script: Major Start X: 	52	Major Start Y: 	32
 Map Script: Major Start X: 	56	Major Start Y: 	14
 Map Script: Major Start X: 	24	Major Start Y: 	36
 Map Script: Major Start X: 	13	Major Start Y: 	38
 Map Script: Major Start X: 	29	Major Start Y: 	21
 Map Script: Major Start X: 	14	Major Start Y: 	17
 Map Script: Minor Start X: 	61	Minor Start Y: 	21
 Map Script: Minor Start X: 	18	Minor Start Y: 	30
 Map Script: Minor Start X: 	24	Minor Start Y: 	27
 Map Script: Minor Start X: 	22	Minor Start Y: 	18
 Map Script: Minor Start X: 	10	Minor Start Y: 	27
 Map Script: Minor Start X: 	23	Minor Start Y: 	12
 Map Script: Minor Start X: 	56	Minor Start Y: 	24
 Map Script: Minor Start X: 	49	Minor Start Y: 	23
 Map Script: Minor Start X: 	23	Minor Start Y: 	26
 Map Script: -------------------------------
 Map Script: Map Generation - Adding Goodies
 Map Script: -------------------------------
 Diagnostics: [CivViAccess][INFO ] Diagnostics.lua: file loaded
 Diagnostics: [CivViAccess][INFO ] Diagnostics: Events available, subscribing
 Diagnostics: [CivViAccess][INFO ] Diagnostics: LuaEvents available, subscribing
 Diagnostics: [CivViAccess][INFO ] Diagnostics: subscriptions complete
 ScreenReaderEventHandlers: [CivViAccess][INFO ] ScreenReaderEventHandlers.lua: file loaded, Initialize starting
 ScreenReaderEventHandlers: [CivViAccess][INFO ] ScreenReaderEventHandlers: Events=table: 000000003E3A17B0 Game=table: 000000003E6E0260 Players=table: 000000003E6DCB60 Map=table: 000000003E6DCAC0
 ScreenReaderEventHandlers: [CivViAccess][INFO ] ScreenReaderEventHandlers: subscriptions complete
 TurnAnnouncements: [CivViAccess][INFO ] TurnAnnouncements.lua: file loaded
 TurnAnnouncements: [CivViAccess][INFO ] TurnAnnouncements: subscribed to LocalPlayerTurnBegin
 TurnAnnouncements: [CivViAccess][INFO ] TurnAnnouncements: subscribed to EndTurnBlockingChanged
 TutorialReset: [CivViAccess][INFO ] TutorialReset.lua: file loaded
 TutorialReset: [CivViAccess][INFO ] TutorialReset: no UITutorialManager reset API found; per-item tutorial seen state not reset (only the user-options flags above).
 TutorialReset: [CivViAccess][INFO ] TutorialReset: complete.
 WorldInteractiveAnnounce: [CivViAccess][INFO ] WorldInteractiveAnnounce.lua: file loaded
 WorldInteractiveAnnounce: [CivViAccess][INFO ] WorldInteractiveAnnounce: subscribed to LocalPlayerTurnBegin
 WorldCongress: Initializing World Congress Lua
 MapLabelManager: ARCTIC OCEAN (5.9993456909244e+20, 1109331328)
 MapLabelManager: ARCTIC OCEAN (2.9063719830882e+20, 2218286080)
 MapLabelManager: ARCTIC OCEAN (5.4230270834842e+19, 3078841600)
 MapLabelManager: ARCTIC OCEAN (1.2855806611306e+21, -1362413568)
 MapLabelManager: ARCTIC OCEAN (3.456982777218e+20, 2014293632)
 MapLabelManager: ARCTIC OCEAN (1.3683524594195e+21, -1663212032)
 MapLabelManager: ARCTIC OCEAN (4.0660203877947e+20, 1794615680)
 MapLabelManager: ARCTIC OCEAN (1.4499465664059e+20, 2748272128)
 MapLabelManager: ARCTIC OCEAN (1.255481134496e+21, -1252769664)
 MapLabelManager: ARCTIC OCEAN (1.2221796892639e+21, -1128833920)
 MapLabelManager: ARCTIC OCEAN (1.0842538544509e+21, -615727744)
 MapLabelManager: IAPETUS OCEAN (8.1281268660383e+20, 343805472)
 MapLabelManager: IAPETUS OCEAN (1.0116886202925e+21, -386126880)
 MapLabelManager: IAPETUS OCEAN (7.1903563893797e+20, 687449024)
 MapLabelManager: IAPETUS OCEAN (9.0313427708683e+20, 16119695)
 MapLabelManager: IAPETUS OCEAN (7.4842950780591e+20, 580119680)
 MapLabelManager: IAPETUS OCEAN (6.7302264302011e+20, 854856384)
 MapLabelManager: IAPETUS OCEAN (8.3973013862667e+20, 247876000)
 MapLabelManager: IAPETUS OCEAN (8.7081869796064e+20, 134782000)
 MapLabelManager: IAPETUS OCEAN (5.8785155202969e+20, 1163144704)
 MapLabelManager: IAPETUS OCEAN (6.971934622202e+20, 764143936)
 MapSearchPanel: Created SearchContext 'MapSearch_Primary'
 MapSearchPanel: Created SearchContext 'MapSearch_Suggestions'
 NaturalWonderPopup: [CivViAccess][INFO ] RevealPopupAccess.lua: loaded
 WonderBuiltPopup: [CivViAccess][INFO ] RevealPopupAccess.lua: loaded
 ProjectBuiltPopup: [CivViAccess][INFO ] RevealPopupAccess.lua: loaded
 MapPinPopup: initializing MapTacks.IconOptions(0)
 MapPinPopup: Selected 16 columns
 BoostUnlockedPopup: [CivViAccess][INFO ] RevealPopupAccess.lua: loaded
 TechCivicCompletedPopup: [CivViAccess][INFO ] RevealPopupAccess.lua: loaded
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu.lua (shadowed): file loaded
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu.Initialize: starting
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu.Initialize: m_isLoadingDone=true (preset)
 InGame: Loading InGame UI - ../../../DLC/CivViAccessMod/Assets/UI/Additions/HexCursorAddin
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.lua: file loaded
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: starting
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: ContextPtr=LuaContext: 000000004E9DF6F0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: Events=table: 0000000130FE3470 LuaEvents=table: 000000013105DFC0 Game=table: 0000000131062B60 UI=table: 0000000130FE3790
 HexCursorAddin: [CivViAccess][DEBUG] HandlerStack.push 'HexCursor' (depth=1)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: pushed onto HandlerStack, depth=1
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: subscribed to Events.LoadScreenClose
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.lua: file loaded
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: starting
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: ContextPtr=LuaContext: 000000004E9DF6F0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: Events=table: 0000000130FE3470 LuaEvents=table: 000000013105DFC0 Game=table: 0000000131062B60 UI=table: 0000000130FE3790
 HexCursorAddin: [CivViAccess][DEBUG] HandlerStack.push 'HexCursor' (depth=1)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: pushed onto HandlerStack, depth=1
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: subscribed to Events.LoadScreenClose
 HexCursorAddin: [CivViAccess][INFO ] UnitMovement.lua: file loaded
 HexCursorAddin: [CivViAccess][INFO ] UnitMovement.Initialize: subscribed to Events.UnitMoveComplete
 HexCursorAddin: [CivViAccess][INFO ] UnitMovement.Initialize: subscribed to Events.UnitOperationDeactivated
 HexCursorAddin: [CivViAccess][INFO ] UnitMovement.Initialize: subscribed to Events.UnitOperationsCleared
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.lua: file loaded
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: starting
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: ContextPtr=LuaContext: 000000004E9DF6F0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: Events=table: 0000000130FE3470 LuaEvents=table: 000000013105DFC0 Game=table: 0000000131062B60 UI=table: 0000000130FE3790
 HexCursorAddin: [CivViAccess][DEBUG] HandlerStack.push 'HexCursor' (depth=1)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: pushed onto HandlerStack, depth=1
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.Initialize: subscribed to Events.LoadScreenClose
 HexCursorAddin: [CivViAccess][INFO ] UnitInfo.lua: file loaded
 HexCursorAddin: [CivViAccess][INFO ] UnitInfo.Initialize: subscribed to Events.UnitSelectionChanged
 HexCursorAddin: [CivViAccess][INFO ] CityProduction.lua: loaded
 HexCursorAddin: [CivViAccess][INFO ] Notifications.lua: file loaded
 HexCursorAddin: [CivViAccess][INFO ] Notifications: subscriptions complete
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin.lua: file loaded (diagnostic speech=false)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: ContextPtr=LuaContext: 000000004E9DF6F0
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin.Initialize: starting
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_CursorNW -> id 81
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_CursorNE -> id 80
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_CursorW -> id 84
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_CursorE -> id 79
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_CursorSW -> id 83
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_CursorSE -> id 82
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_WhereAmI -> id 86
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_WhereAmIAbs -> id 87
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_OpenHelp -> id 85
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_MoveNW -> id 92
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_MoveNE -> id 91
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_MoveW -> id 95
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_MoveE -> id 90
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_MoveSW -> id 94
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_MoveSE -> id 93
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_UnitInfo -> id 108
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_RecenterOnUnit -> id 104
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_NextUnitAll -> id 98
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_PrevUnitAll -> id 103
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_UnblockProduction -> id 107
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_Rest -> id 105
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_Sleep -> id 106
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_OpenProductionPicker -> id 102
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_OpenTechPicker -> id 110
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_OpenCivicPicker -> id 109
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_VerbosityToggle -> id 111
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_NotificationPrev -> id 100
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_NotificationNext -> id 99
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CIVVIACCESS_NotificationReminderToggle -> id 101
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound PauseMenu -> id 44
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound QuickSave -> id 48
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound QuickLoad -> id 47
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound EndTurn -> id 16
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound SkipTurn -> id 52
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound FoundCity -> id 21
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound MoveTo -> id 35
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound Fortify -> id 19
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound FortifyUntilHeal -> id 20
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound DeleteUnit -> id 15
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound Attack -> id 4
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound RangedAttack -> id 49
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound AutoExplore -> id 5
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound Sleep -> id 53
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound Alert -> id 3
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleTechTree -> id 66
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleCivicsTree -> id 56
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleGovernment -> id 59
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleReligion -> id 64
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleGreatPeople -> id 60
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleGreatWorks -> id 61
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleRankings -> id 63
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleCityStates -> id 55
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleEspionage -> id 57
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleTradeRoutes -> id 68
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound OpenCivilopedia -> id 42
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CivilopediaBack -> id 13
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CivilopediaForward -> id 14
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleFSMap -> id 58
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound OpenMapSearch -> id 43
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleGrid -> id 62
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleYield -> id 69
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound ToggleResources -> id 65
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound Toggle2DView -> id 54
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound PrevUnit -> id 46
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound NextUnit -> id 39
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound PrevCity -> id 45
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound NextCity -> id 38
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CapitalCity -> id 12
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound OnlinePause -> id 41
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CameraPanUp -> id 11
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CameraPanDown -> id 8
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CameraPanLeft -> id 9
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound CameraPanRight -> id 10
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensReligion -> id 28
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensContinent -> id 24
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensAppeal -> id 23
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensSettler -> id 29
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensGovernment -> id 26
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensPolitical -> id 27
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensTourism -> id 30
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: bound LensEmpire -> id 25
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent AdvisorPopup_ShowAdvisorPopup
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent AdvisorPopup_ClearActiveAdvisor
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent InGame_OpenInGameOptionsMenu
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent InGameTopOptionsMenu_Show
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent InGameTopOptionsMenu_Close
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent PlayerChange_Show
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent PlayerChange_Close
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent NotificationPanel_ShowNotificationContent
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: subscribed LuaEvent Tutorial_TutorialEnd
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin.Initialize: complete. diagnostic speech=false
 InGame: Loading InGame UI - ../../../DLC/CivViAccessMod/Assets/UI/Additions/ProductionPickerAddin
 ProductionPickerAddin: [CivViAccess][INFO ] ProductionPickerAddin: subscribed to CivViAccess_OpenProductionPicker
 ProductionPickerAddin: [CivViAccess][INFO ] ProductionPickerAddin.Initialize: input handler installed
 InGame: Loading InGame UI - ../../../DLC/CivViAccessMod/Assets/UI/Additions/TechPickerAddin
 TechPickerAddin: [CivViAccess][INFO ] TechPickerAddin: subscribed to CivViAccess_OpenTechPicker
 TechPickerAddin: [CivViAccess][INFO ] TechPickerAddin.Initialize: input handler installed
 InGame: Loading InGame UI - ../../../DLC/CivViAccessMod/Assets/UI/Additions/CivicPickerAddin
 CivicPickerAddin: [CivViAccess][INFO ] CivicPickerAddin: subscribed to CivViAccess_OpenCivicPicker
 CivicPickerAddin: [CivViAccess][INFO ] CivicPickerAddin.Initialize: input handler installed
 InGame: Loading InGame UI - ../../../DLC/CivViAccessMod/Assets/UI/Additions/HelpAddin
 HelpAddin: [CivViAccess][INFO ] HelpAddin: subscribed to CivViAccess_OpenHelp
 HelpAddin: [CivViAccess][INFO ] HelpAddin.Initialize: input handler installed
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/DedicationPopup
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/DisloyalCityChooser
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/EraProgressPanel
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/EraReviewPopup
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/ExpansionIntro
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/GovernorAssignmentChooser
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/GovernorPanel
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/HistoricMoments
 InGame: Loading InGame UI - ../../../DLC/Expansion2/UI/Additions/WorldCrisisPopup
 InGame: Loading InGame UI - ../../../DLC/Ethiopia/UI/Additions/SecretSocietyPopup
 InGame: Loading InGame UI - ../../../DLC/Babylon/UI/Additions/HeroesPopup
 AdvisorPopup: [CivViAccess][INFO ] AdvisorPopupAccess.lua: loaded
 TutorialUIRoot: Tutorial: Firaxis in game tutorial prompts.
 TutorialUIRoot: Version: 1
 TutorialUIRoot: Loading bank of items for tutorial scenario: 'BASE'
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(0, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(1, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(2, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(3, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(4, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(5, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(6, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(7, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(8, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(9, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(10, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(11, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(12, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(13, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(14, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(62, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerEraChanged(63, 0)
 Diagnostics: [CivViAccess][INFO ] EVENT NotificationAdded(0, 0)
 HexCursorAddin: [CivViAccess][INFO ] NotificationAdded type=NOTIFICATION_DISCOVER_CONTINENT id=0 blocker=false dismissable=true summary=We have discovered a new continent. Our explorer is naming it Africa.
 MapLabelManager: ARCTIC OCEAN (-2301.0219726563, 411.41235351563)
 MapLabelManager: ARCTIC OCEAN (1732.0305175781, 890.75061035156)
 MapLabelManager: ARCTIC OCEAN (-2303.7145996094, -991.50732421875)
 MapLabelManager: ARCTIC OCEAN (-1709.3854980469, -1115.0859375)
 MapLabelManager: ARCTIC OCEAN (-2121.3803710938, 994.36315917969)
 MapLabelManager: ARCTIC OCEAN (-983.81158447266, -1068.7624511719)
 MapLabelManager: ARCTIC OCEAN (1854.5032958984, -1044.4708251953)
 MapLabelManager: ARCTIC OCEAN (-1996.1303710938, -63.674377441406)
 MapLabelManager: ARCTIC OCEAN (-1855.6076660156, -591.16784667969)
 MapLabelManager: ARCTIC OCEAN (-1392.7774658203, -817.26171875)
 MapLabelManager: ARCTIC OCEAN (2279.1694335938, -340.23138427734)
 MapLabelManager: IAPETUS OCEAN (899.25616455078, 1010.8652954102)
 MapLabelManager: IAPETUS OCEAN (-391.83804321289, -984.55981445313)
 MapLabelManager: IAPETUS OCEAN (529.23919677734, -49.626880645752)
 MapLabelManager: IAPETUS OCEAN (418.59725952148, 547.14288330078)
 MapLabelManager: IAPETUS OCEAN (308.33615112305, -1053.5607910156)
 MapLabelManager: IAPETUS OCEAN (103.95571899414, -488.37548828125)
 MapLabelManager: IAPETUS OCEAN (7.0772151947021, 162.63874816895)
 MapLabelManager: IAPETUS OCEAN (154.95343017578, 968.37133789063)
 MapLabelManager: IAPETUS OCEAN (1088.6374511719, -1098.5792236328)
 MapLabelManager: IAPETUS OCEAN (745.73602294922, -610.74108886719)
 Diagnostics: [CivViAccess][INFO ] EVENT PlayerInfoChanged(0)
 HexCursorAddin: #SCREENREADER[kind=meta] - Notification. We have discovered a new continent. Our explorer is naming it Africa.
 LoadScreen: OnLoadGameViewStateDone
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Loading complete. Press Enter or Escape to begin the game.
 Diagnostics: [CivViAccess][INFO ] EVENT LoadGameViewStateDone(1)
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu: m_isLoadingDone=true via LoadGameViewStateDone
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 52, 32, 0, true, false)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: called (already initialized=false)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: localPlayer=0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: UI.GetHeadSelectedUnit() returned table: 0000000131160810
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: head-selected unit plot = table: 00000001311609A0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: SUCCESS — placed at (52, 32)
 LoadScreen: [CivViAccess][INFO ] LoadScreenAccess.HandleKey: keyup=102 ctrl=false ready=true loadComplete=true
 LoadScreen: #SCREENREADER[NOINTERRUPT,kind=status] - Dawn of Man speech playing. Press Enter when you are ready to begin the game.
 LoadScreen: [CivViAccess][INFO ] LoadScreenAccess.HandleKey: keyup=103 ctrl=false ready=true loadComplete=true
 Diagnostics: [CivViAccess][INFO ] EVENT LoadScreenClose()
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Settler on Plains with Plains Floodplains.
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - 2 moves remaining.
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Temperate region.
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Warrior North-West
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Press B to found a city here with the Settler. Press period to cycle to the next unit that needs orders, comma for the previous. Hold Alt with Q, E, A, D, Z, or C to move the selected unit one hex. After you found a city, press Shift+P to choose what it produces. Research is not yet keyboard-accessible; press Alt+P to auto-pick the cheapest research and civic so you can end your turn.
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: called (already initialized=false)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: localPlayer=0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: UI.GetHeadSelectedUnit() returned table: 0000000131160810
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: head-selected unit plot = table: 00000001311609A0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: SUCCESS — placed at (52, 32)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: called (already initialized=false)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: localPlayer=0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: UI.GetHeadSelectedUnit() returned table: 0000000131160810
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: head-selected unit plot = table: 00000001311609A0
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: SUCCESS — placed at (52, 32)
 HexCursorAddin: [CivViAccess][INFO ] HexCursor.init: called (already initialized=true)
 HexCursorAddin: #SCREENREADER[kind=meta] - Notification. Move a unit or have it perform an operation.
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
> LuaEvents.CivViAccess_DebugRaisePopup("NaturalWonder")
 NaturalWonderPopup: PopupManager.LOCK   'NaturalWonderPopup', id: 0, priority:1000
 NaturalWonderPopup: #SCREENREADER[kind=critical] - Natural wonder discovered. GREAT BARRIER REEF. Two tile natural wonder that can be found on coastal terrain and provides +3 Food and +2 Science. Major adjacency bonus to the Campus district.. A vast, intricate network of coral reefs and shallow turquoise lagoons stretches far along a curving coastline.. Press I for the full natural wonder description. Press Enter to dismiss
 NaturalWonderPopup: [CivViAccess][INFO ] RevealPopupAccess.NotifyShow: open
 InGame: Request to BulkHide( true, NaturalWonder ), Show on 0 = 1
 Diagnostics: [CivViAccess][INFO ] EVENT InterfaceModeChanged(-1615000917, 397393512)
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
 InGame: Request to BulkHide( false, NaturalWonder ), Show on 0 = 0
 NaturalWonderPopup: PopupManager.Unlock 'NaturalWonderPopup', id: 0, priority:1000
 Diagnostics: [CivViAccess][INFO ] EVENT InterfaceModeChanged(397393512, -1615000917)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 51, 33, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Warrior
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Settler South-East
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 52, 32, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Settler
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Warrior North-West
> LuaEvents.CivViAccess_DebugRaisePopup("WonderBuilt")
 WonderBuiltPopup: PopupManager.LOCK   'WonderBuiltPopup', id: 0, priority:1000
 WonderBuiltPopup: #SCREENREADER[kind=critical] - World wonder completed. Stonehenge. Grants a free Great Prophet. Great Prophets may found a Religion on Stonehenge instead of a Holy Site. Must be adjacent to Stone and on flat land.. Press Enter to dismiss
 WonderBuiltPopup: [CivViAccess][INFO ] RevealPopupAccess.NotifyShow: open
 InGame: Request to BulkHide( true, Wonder ), Show on 0 = 1
 Diagnostics: [CivViAccess][INFO ] EVENT InterfaceModeChanged(-1615000917, 397393512)
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
 WonderBuiltPopup: #SCREENREADER[kind=selection] - World wonder completed. Stonehenge. Grants a free Great Prophet. Great Prophets may found a Religion on Stonehenge instead of a Holy Site. Must be adjacent to Stone and on flat land.. Press Enter to dismiss
 WonderBuiltPopup: #SCREENREADER[kind=selection] - World wonder completed. Stonehenge. Grants a free Great Prophet. Great Prophets may found a Religion on Stonehenge instead of a Holy Site. Must be adjacent to Stone and on flat land.. Press Enter to dismiss
 WonderBuiltPopup: #SCREENREADER[kind=selection] - World wonder completed. Stonehenge. Grants a free Great Prophet. Great Prophets may found a Religion on Stonehenge instead of a Holy Site. Must be adjacent to Stone and on flat land.. Press Enter to dismiss
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(96)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=96 name=ActionID 96
 WonderBuiltPopup: #SCREENREADER[kind=selection] - World wonder completed. Stonehenge. Grants a free Great Prophet. Great Prophets may found a Religion on Stonehenge instead of a Holy Site. Must be adjacent to Stone and on flat land.. Press Enter to dismiss
 InGame: Request to BulkHide( false, Wonder ), Show on 0 = 0
 WonderBuiltPopup: PopupManager.Unlock 'WonderBuiltPopup', id: 0, priority:1000
 Diagnostics: [CivViAccess][INFO ] EVENT InterfaceModeChanged(397393512, -1615000917)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 51, 33, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Warrior
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Settler South-East
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(8)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=8 name=CameraPanDown
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(11)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=11 name=CameraPanUp
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu.OnShow: called (m_isClosing=false)
 InGameTopOptionsMenu: [CivViAccess][DEBUG] HandlerStack.push 'InGameTopOptionsMenu' (depth=1)
 InGameTopOptionsMenu: [CivViAccess][INFO ] BaseMenu.onActivate [InGameTopOptionsMenu]: called, _initialized=false
 InGameTopOptionsMenu: [CivViAccess][INFO ] buildPauseMenuItems: starting
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: ReturnButton hidden=false text='RETURN TO GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: QuickSaveButton hidden=false text='QUICK SAVE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: SaveGameButton hidden=false text='SAVE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: LoadGameButton hidden=false text='LOAD GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: OptionsButton hidden=false text='OPTIONS'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: RestartButton hidden=false text='RESTART'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: RetireButton hidden=false text='RETIRE'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: PBCDeleteButton hidden=true text='DELETE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: PBCQuitButton hidden=true text='QUIT GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: MainMenuButton hidden=false text='EXIT TO MAIN MENU'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: ExitGameButton hidden=false text='EXIT TO DESKTOP'
 InGameTopOptionsMenu: [CivViAccess][INFO ] buildPauseMenuItems: returning 9 items
 InGameTopOptionsMenu: [CivViAccess][INFO ] BaseMenu.onActivate [InGameTopOptionsMenu]: first-init, items count=9
 InGameTopOptionsMenu: #SCREENREADER[kind=picker] - Pause menu
 InGameTopOptionsMenu: #SCREENREADER[NOINTERRUPT,kind=status] - RETURN TO GAME
 InGameTopOptionsMenu: #SCREENREADER[kind=event] - Returned to game
 InGameTopOptionsMenu: [CivViAccess][DEBUG] HandlerStack.removeByName 'InGameTopOptionsMenu' (depth=0)
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(80)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=80 name=CIVVIACCESS_CursorNE
 HexCursorAddin: #SCREENREADER[kind=nav] - Plains. Plains Floodplains. Wheat
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(83)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=83 name=CIVVIACCESS_CursorSW
 HexCursorAddin: #SCREENREADER[kind=nav] - Plains. Plains Floodplains. Your Egyptian Empire Warrior
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(100)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=100 name=CIVVIACCESS_NotificationPrev
 HexCursorAddin: #SCREENREADER[kind=selection] - Notification 2 of 2. We have discovered a new continent. Our explorer is naming it Africa.
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(99)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=99 name=CIVVIACCESS_NotificationNext
 HexCursorAddin: #SCREENREADER[kind=selection] - Notification 1 of 2, blocker. Move a unit or have it perform an operation.
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
> LuaEvents.CivViAccess_DebugRaisePopup("ProjectBuilt")
 ProjectBuiltPopup: #SCREENREADER[kind=critical] - Project completed. Launch Earth Satellite. Space Race project which launches a small satellite into orbit. Reveals the geography of any unexplored corner of the world, and marks the first step towards the Science Victory.. Press Enter to dismiss
 ProjectBuiltPopup: [CivViAccess][INFO ] RevealPopupAccess.NotifyShow: open
 Diagnostics: [CivViAccess][INFO ] EVENT InterfaceModeChanged(-1615000917, 397393512)
 ProjectBuiltPopup: #SCREENREADER[kind=selection] - Project completed. Launch Earth Satellite. Space Race project which launches a small satellite into orbit. Reveals the geography of any unexplored corner of the world, and marks the first step towards the Science Victory.. Press Enter to dismiss
 Diagnostics: [CivViAccess][INFO ] EVENT InputActionTriggered(96)
 HexCursorAddin: [CivViAccess][INFO ] HexCursorAddin: action fired id=96 name=ActionID 96
 InGame: Request to BulkHide( false, Project ), Show on 0 = -1
 ProjectBuiltPopup: [CivViAccess][WARN ] RevealPopupAccess.HandleKey: onClose failed: C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Assets\UI\PopupManager.lua:90: attempt to index a nil value
stack traceback:
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Assets\UI\PopupManager.lua:90: in function 'Unlock'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:171: in function 'Close'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:125: in function '(anonymous)'
	[C]: in function 'pcall'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Accessibility\RevealPopupAccess.lua:184: in function 'RevealPopupAccess.HandleKey'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:233: in function 'OnInputHandler'
 Diagnostics: [CivViAccess][INFO ] EVENT InterfaceModeChanged(397393512, -1615000917)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 52, 32, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Settler
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Warrior North-West
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 51, 33, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Warrior
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Settler South-East
> LuaEvents.CivViAccess_DebugRaisePopup("BoostUnlocked")
 BoostUnlockedPopup: #SCREENREADER[kind=critical] - Eureka. Your knowledge of Pottery has advanced considerably.. Press Enter to dismiss
 BoostUnlockedPopup: [CivViAccess][INFO ] RevealPopupAccess.NotifyShow: open
> 
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 52, 32, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Settler
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Warrior North-West
 InGame: Request to BulkHide( false, Project ), Show on 0 = -1
 Runtime Error: C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Assets\UI\PopupManager.lua:90: attempt to index a nil value
stack traceback:
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Assets\UI\PopupManager.lua:90: in function 'Unlock'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:171: in function 'Close'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:226: in function 'KeyHandler'
	(tail call): ?
Lua callstack:
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu.OnShow: called (m_isClosing=false)
 InGameTopOptionsMenu: [CivViAccess][DEBUG] HandlerStack.push 'InGameTopOptionsMenu' (depth=1)
 InGameTopOptionsMenu: [CivViAccess][INFO ] BaseMenu.onActivate [InGameTopOptionsMenu]: called, _initialized=false
 InGameTopOptionsMenu: [CivViAccess][INFO ] buildPauseMenuItems: starting
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: ReturnButton hidden=false text='RETURN TO GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: QuickSaveButton hidden=false text='QUICK SAVE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: SaveGameButton hidden=false text='SAVE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: LoadGameButton hidden=false text='LOAD GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: OptionsButton hidden=false text='OPTIONS'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: RestartButton hidden=false text='RESTART'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: RetireButton hidden=false text='RETIRE'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: PBCDeleteButton hidden=true text='DELETE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: PBCQuitButton hidden=true text='QUIT GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: MainMenuButton hidden=false text='EXIT TO MAIN MENU'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: ExitGameButton hidden=false text='EXIT TO DESKTOP'
 InGameTopOptionsMenu: [CivViAccess][INFO ] buildPauseMenuItems: returning 9 items
 InGameTopOptionsMenu: [CivViAccess][INFO ] BaseMenu.onActivate [InGameTopOptionsMenu]: first-init, items count=9
 InGameTopOptionsMenu: #SCREENREADER[kind=picker] - Pause menu
 InGameTopOptionsMenu: #SCREENREADER[NOINTERRUPT,kind=status] - RETURN TO GAME
 InGameTopOptionsMenu: #SCREENREADER[kind=event] - Returned to game
 InGameTopOptionsMenu: [CivViAccess][DEBUG] HandlerStack.removeByName 'InGameTopOptionsMenu' (depth=0)
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
> LuaEvents.CivViAccess_DebugRaisePopup("TechCivic")
Runtime Error: C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\TechCivicCompletedPopup.lua:311: attempt to index a nil value
stack traceback:
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\TechCivicCompletedPopup.lua:311: in function 'RealizeNextPopup'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\TechCivicCompletedPopup.lua:283: in function 'OnShow'
Lua callstack:

 TechCivicCompletedPopup: #SCREENREADER[kind=critical] - Technology researched. POTTERY. Unlocked by this Tech (3):. Press Enter to dismiss
 TechCivicCompletedPopup: [CivViAccess][INFO ] RevealPopupAccess.NotifyShow: open
 TechCivicCompletedPopup: [CivViAccess][INFO ] RevealPopupAccess.NotifyClose
> 
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 51, 33, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Warrior
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Settler South-East
> LuaEvents.CivViAccess_DebugRaisePopup("EraComplete")
> 
> 
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 52, 32, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Settler
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Warrior North-West
> LuaEvents.CivViAccess_DebugRaisePopup("EraComplete")
 InGame: Request to BulkHide( false, Project ), Show on 0 = -1
 Runtime Error: C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Assets\UI\PopupManager.lua:90: attempt to index a nil value
stack traceback:
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\Base\Assets\UI\PopupManager.lua:90: in function 'Unlock'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:171: in function 'Close'
	C:\Program Files (x86)\Steam\steamapps\common\Sid Meier's Civilization VI\DLC\CivViAccessMod\Assets\UI\Popups\ProjectBuiltPopup.lua:226: in function 'KeyHandler'
	(tail call): ?
Lua callstack:
 InGameTopOptionsMenu: [CivViAccess][INFO ] InGameTopOptionsMenu.OnShow: called (m_isClosing=false)
 InGameTopOptionsMenu: [CivViAccess][DEBUG] HandlerStack.push 'InGameTopOptionsMenu' (depth=1)
 InGameTopOptionsMenu: [CivViAccess][INFO ] BaseMenu.onActivate [InGameTopOptionsMenu]: called, _initialized=false
 InGameTopOptionsMenu: [CivViAccess][INFO ] buildPauseMenuItems: starting
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: ReturnButton hidden=false text='RETURN TO GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: QuickSaveButton hidden=false text='QUICK SAVE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: SaveGameButton hidden=false text='SAVE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: LoadGameButton hidden=false text='LOAD GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: OptionsButton hidden=false text='OPTIONS'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: RestartButton hidden=false text='RESTART'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: RetireButton hidden=false text='RETIRE'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: PBCDeleteButton hidden=true text='DELETE GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: PBCQuitButton hidden=true text='QUIT GAME'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: MainMenuButton hidden=false text='EXIT TO MAIN MENU'
 InGameTopOptionsMenu: [CivViAccess][INFO ]   buildPauseMenuItems: ExitGameButton hidden=false text='EXIT TO DESKTOP'
 InGameTopOptionsMenu: [CivViAccess][INFO ] buildPauseMenuItems: returning 9 items
 InGameTopOptionsMenu: [CivViAccess][INFO ] BaseMenu.onActivate [InGameTopOptionsMenu]: first-init, items count=9
 InGameTopOptionsMenu: #SCREENREADER[kind=picker] - Pause menu
 InGameTopOptionsMenu: #SCREENREADER[NOINTERRUPT,kind=status] - RETURN TO GAME
 InGameTopOptionsMenu: #SCREENREADER[kind=event] - Returned to game
 InGameTopOptionsMenu: [CivViAccess][DEBUG] HandlerStack.removeByName 'InGameTopOptionsMenu' (depth=0)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 65536, 0, 0, 0, false, false)
 Diagnostics: [CivViAccess][INFO ] EVENT UnitSelectionChanged(0, 131073, 51, 33, 0, true, false)
 ScreenReaderEventHandlers: #SCREENREADER[kind=selection] - Warrior
 ScreenReaderEventHandlers: #SCREENREADER[NOINTERRUPT,kind=status] - Your Egyptian Empire Settler South-East
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
> LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
> 
> LuaEvents.CivViAccess_DebugRaisePopup("NaturalDisaster")
> LuaEvents.CivViAccess_DebugRaisePopup("RockBand")
 HexCursorAddin: #SCREENREADER[kind=meta] - 2 things to do
> LuaEvents.CivViAccess_DebugRaisePopup("Heroes")
> LuaEvents.CivViAccess_DebugRaisePopup("Heroes")
> LuaEvents.CivViAccess_DebugRaisePopup("SecretSociety")

