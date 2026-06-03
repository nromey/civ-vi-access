-- Registers Civ VI's engine-default hotkeys into HandlerStack's
-- commonHelpEntries so they appear in the ? help overlay everywhere
-- regardless of which screen / handler is on top. Sighted users can see
-- these in tooltips and the Options > Keybindings screen; blind users
-- need a discoverable surface, and ? is it.
--
-- Source of truth: Base/Assets/Configuration/Data/InputConfiguration.xml,
-- table InputActionDefaultGestures. Cross-check that table when Firaxis
-- patches.
--
-- Entries reflect the bindings AS THE PLAYER WILL EXPERIENCE THEM with
-- our mod loaded. That means Q/E/A/Z/C entries describe the HexCursor
-- bindings (the rebound versions are at Alt+letter, listed separately).
--
-- Loaded in both front-end and in-game contexts via modinfo ImportFiles
-- so ? help in either context shows the engine bindings (they fire only
-- in-game, but knowing they exist is useful at any time).

include("Log");
include("HandlerStack");

Log.info("EngineHotkeys.lua: registering Civ VI default keybindings into ? help");

-- ----------------------------------------------------------------------
-- UI category — opens screens / overlays
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "T",         description = "Open Tech Tree" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+C",     description = "Open Civics Tree (rebound from C)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F7",        description = "Open Government screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "L",         description = "Open Religion screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "O",         description = "Open Great People screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "W",         description = "Open Great Works screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F1",        description = "Open Rankings screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F2",        description = "Open City-States screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F3",        description = "Open Espionage screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F4",        description = "Open Trade Routes screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F9",        description = "Open Civilopedia" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "End",       description = "Open full-screen map" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Ctrl+F",    description = "Open map search (in-game only)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Shift+T",   description = "Say again (repeat the last announcement)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Shift+I",   description = "Read the full visual description of the last reveal popup (hero / society)" });

-- ----------------------------------------------------------------------
-- UNIT category — actions on the selected unit
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "B",         description = "Found city (with Settler selected)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "M",         description = "Move to" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F",         description = "Fortify selected unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Delete",    description = "Delete selected unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+A",     description = "Attack (rebound from A)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "R",         description = "Ranged attack" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+X",     description = "Auto-explore selected unit (eXplore)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Shift+B",   description = "Build recommended improvement (selected builder)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "H",         description = "Fortify until healed" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Space",     description = "Skip turn for selected unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+Z",     description = "Sleep selected unit (rebound from Z)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "V",         description = "Alert selected unit" });

-- ----------------------------------------------------------------------
-- GLOBAL category — turn / camera / UI toggles
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "Enter",     description = "End turn" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "G",         description = "Toggle hex grid overlay" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Home",      description = "Open pause menu" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F5",        description = "Quick save" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F6",        description = "Quick load" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Y",         description = "Toggle yield display" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Comma",     description = "Previous unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Period",    description = "Next unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Left bracket",  description = "Previous city" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Right bracket", description = "Next city" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+Q",     description = "Toggle resource display (rebound from Q)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Plus",      description = "Toggle 2D / 3D view" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Backslash", description = "Center on capital city" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Arrow keys", description = "Pan camera" });

-- ----------------------------------------------------------------------
-- LENSES category — colored overlays (numbers 1-7, 9)
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "1",         description = "Religion lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "2",         description = "Continent lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "3",         description = "Appeal lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "4",         description = "Settler lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "5",         description = "Government lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "6",         description = "Political lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "7",         description = "Tourism lens" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "9",         description = "Empire lens" });

-- ----------------------------------------------------------------------
-- ONLINE
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "P",         description = "Online pause (multiplayer)" });

Log.info("EngineHotkeys: registered " .. #HandlerStack.commonHelpEntries .. " entries");
