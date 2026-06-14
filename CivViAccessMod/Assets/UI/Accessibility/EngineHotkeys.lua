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
-- DO NOT list a key the WorldInput wrap reclaims (WorldInputAccessWrap.lua
-- SCANNER_KEYS / SCANNER_COMBOS) — pressing it does OUR action, not the
-- engine one, so advertising the engine function here would be a lie.
-- Reclaimed and therefore EXCLUDED: S, W, G, End, Home, F1, Backspace,
-- PageUp/Down, [ and ] (→ notifications; city cycle moved to Shift+[ / ]),
-- the bare Q/E/A/D/Z/C cluster, M, Ctrl+A, Shift/Ctrl+R, etc. Their mod
-- meanings are listed by the cursor handler + scanner help, not here.
-- (Noel 2026-06-14: "we turn off input, so only list what passes through.")
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
-- W (Great Works) and F1 (Rankings) are reclaimed by the wrap (where-am-I /
-- searchable help) — excluded; reach those screens another way.
HandlerStack.registerCommonHelpEntry({ keyLabel = "F2",        description = "Open City-States screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F3",        description = "Open Espionage screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F4",        description = "Open Trade Routes screen" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F9",        description = "Open Civilopedia" });
-- End (full-screen map) is the scanner ladder now — excluded.
HandlerStack.registerCommonHelpEntry({ keyLabel = "Ctrl+F",    description = "Open map search (in-game only)" });
-- Shift+T (verbose tile readout) and Shift+I (last-reveal visual description)
-- are MOD actions, listed by the cursor handler — not engine defaults. The old
-- "Shift+T = say again" here was stale (say-again moved to Shift+R 2026-06-01).

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
-- Shift+B is NOT an engine default — it's our CIVVIACCESS_BuildImprovement
-- (opens the builder's build menu). Listed by the cursor handler, not here.
HandlerStack.registerCommonHelpEntry({ keyLabel = "H",         description = "Fortify until healed" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Space",     description = "Skip turn for selected unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+Z",     description = "Sleep selected unit (rebound from Z)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "V",         description = "Alert selected unit" });

-- ----------------------------------------------------------------------
-- GLOBAL category — turn / camera / UI toggles
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "Enter",     description = "End turn" });
-- G (grid), Home (pause), and [ / ] (the wrap maps these to Government /
-- scanner / notification cycle) are reclaimed — excluded. City cycle is on
-- Shift+[ / Shift+] (a mod binding, listed elsewhere).
HandlerStack.registerCommonHelpEntry({ keyLabel = "F5",        description = "Quick save" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "F6",        description = "Quick load" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Comma",     description = "Previous unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Period",    description = "Next unit" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Alt+Q",     description = "Toggle resource display (rebound from Q)" });
HandlerStack.registerCommonHelpEntry({ keyLabel = "Backslash", description = "Center on capital city" });

-- VISUAL-ONLY engine bindings deliberately NOT listed: Y (yield display),
-- Plus (2D/3D view), Arrow keys (pan camera), and the colored map LENSES on
-- digits 1-7/9 (religion / continent / appeal / settler / government /
-- political / tourism / empire). They fire, but a blind player gains nothing,
-- and their key slots — the digits especially — are prime targets for a Civ V
-- key-continuation profile. The profile-aware key registry is the right home
-- for what Help shows per profile; listing dead-weight visual keys here would
-- just clutter the default profile and pre-claim slots Civ V mode wants
-- (Noel 2026-06-14). See [[project_keymap_profiles_civ_v_compat]].

-- ----------------------------------------------------------------------
-- ONLINE
-- ----------------------------------------------------------------------
HandlerStack.registerCommonHelpEntry({ keyLabel = "P",         description = "Online pause (multiplayer)" });

Log.info("EngineHotkeys: registered " .. #HandlerStack.commonHelpEntries .. " entries");
