-- HexCursor bootstrap.
--
-- Loaded by Civ VI's engine InGame.lua via <AddUserInterfaces> registration
-- pairing with HexCursorAddin.xml. See [[reference-addUserInterfaces-no-keyboard]]
-- for why we use Events.InputActionTriggered instead of ContextPtr:SetInputHandler.
--
-- Diagnostic speech mode disabled 2026-05-23 (round 4) — HexCursor bindings
-- confirmed firing in round 3. Logging stays for traceability; spoken
-- chatter ("Action CameraPanUp" on every arrow press, "Your turn", "Load
-- screen closed", etc.) is silenced because it overlapped real announces
-- and confused the user. To re-enable for debugging, flip
-- DIAGNOSTIC_SPEECH below to true.

include("Log");
include("HandlerStack");
include("InputRouter");
include("ScreenReader");
include("Report");
include("EmpireStatus");
include("EotReport");
include("GoodyHutAnnounce");
include("ScreenReaderPlotUtils");
include("Help");
include("HexGeom");
include("HexCursor");
-- Scanner runs in THIS VM (next to the cursor): loads the scanner stack, wires
-- Scanner.cursor to HexCursor, and listens for keys forwarded from the WorldInput
-- capture-all wrap (LuaEvents.CivViAccess_ScannerInput).
include("ScannerAddinGlue");
include("UnitMovement");
include("UnitCombat");
include("BetweenTurns");
include("NavKeys");
include("UnitInfo");
include("CityProduction");
include("Notifications");
-- Verbosity drives the Alt+V toggle handler below. Without this include the
-- module is nil in this VM and Alt+V reported "Verbosity unavailable" (Noel
-- 2026-06-01). BaseMenu includes it for the menu screens; the world/cursor
-- context needs its own include.
include("Verbosity");
include("LeaderMeetAnnounce");

-- Flip to true to re-enable the verbose diagnostic speech (every action
-- firing announced via Tolk + interface-mode changes + popup show/hide
-- events). Default false: speech path stays clean for real announces.
local DIAGNOSTIC_SPEECH :boolean = false;

Log.info("HexCursorAddin.lua: file loaded (diagnostic speech="
         .. tostring(DIAGNOSTIC_SPEECH) .. ")");
Log.info("HexCursorAddin: ContextPtr=" .. tostring(ContextPtr));

-- ---------------------------------------------------------------------------
-- Action name <-> ID lookup. Built at startup so InputActionTriggered events
-- can be spoken with their human name instead of just a number.
-- ---------------------------------------------------------------------------

local _idToName = {};
local _actionHandlers = {};

local DIR_NW = DirectionTypes.DIRECTION_NORTHWEST;
local DIR_NE = DirectionTypes.DIRECTION_NORTHEAST;
local DIR_W  = DirectionTypes.DIRECTION_WEST;
local DIR_E  = DirectionTypes.DIRECTION_EAST;
local DIR_SW = DirectionTypes.DIRECTION_SOUTHWEST;
local DIR_SE = DirectionTypes.DIRECTION_SOUTHEAST;

local function lookupAction(name, handler)
    local id = Input.GetActionId(name);
    if id == nil or id == -1 then
        Log.warn("HexCursorAddin: action '" .. name .. "' not registered");
        return;
    end
    _idToName[id] = name;
    if handler ~= nil then
        _actionHandlers[id] = handler;
    end
    Log.info("HexCursorAddin: bound " .. name .. " -> id " .. tostring(id));
end

-- ---------------------------------------------------------------------------
-- Speech helpers — short, terse, interrupting (so rapid actions don't pile up)
-- ---------------------------------------------------------------------------

-- speak() and speakQueued() route through the DIAGNOSTIC_SPEECH gate
-- so the verbose announcer can be silenced without changing every
-- call site. Real (non-diagnostic) speech that must always reach the
-- user should go through speakAlways() below.
local function speak(text)
    if not DIAGNOSTIC_SPEECH then return; end
    Speech.emit(text, "status");
end

local function speakQueued(text)
    if not DIAGNOSTIC_SPEECH then return; end
    Speech.emit(text, "status");
end

-- Bypasses the DIAGNOSTIC_SPEECH gate. Use for actions the user
-- genuinely needs audible confirmation of every time, regardless of
-- diagnostic mode (Tab → Next unit, Enter → End turn, etc.).
-- meta tier: brief keypress-feedback that yields to game-state events
-- like the city-founded announce immediately following B.
local function speakAlways(text)
    Speech.emit(text, "meta");
end

-- Curated map: actions that should ALWAYS speak their human-readable
-- name when they fire, even with DIAGNOSTIC_SPEECH off. Used as
-- audible confirmation that the engine received the keypress
-- (especially useful for diagnosing Tab → NextUnit on Noel's machine
-- — if Tab keypress is reaching Civ VI, "Next unit" speaks; if
-- silent, key was intercepted before Civ VI saw it).
local ALWAYS_ANNOUNCE_ACTIONS = {
    NextUnit  = "Next unit",
    PrevUnit  = "Previous unit",
    -- Cycle-all variants get the same header speech as bare period so
    -- Ctrl+./, produces the IDENTICAL 3-line pattern bare period does
    -- ("Next unit" + unit name + POI). Bug #25b diagnosis 2026-05-24:
    -- CAMM log showed bare period audible, Ctrl+. silent despite same
    -- speech pipeline. Matching the pattern exactly to isolate any
    -- remaining audibility difference to deeper than Lua speech.
    CIVVIACCESS_NextUnitAll = "Next unit",
    CIVVIACCESS_PrevUnitAll = "Previous unit",
    EndTurn   = "End turn",
    SkipTurn  = "Skip turn",
    -- FoundCity speaks an IMMEDIATE confirmation so the user knows
    -- their B keypress took effect. The richer
    -- "City of [name] founded at [x, y]. Population [N]. ..." speech
    -- fires moments later via CityAddedToMap and INTERRUPTs this
    -- short message — net effect: user hears "Founding city" the
    -- instant they press B, then the full info as the engine
    -- finishes processing. Earlier we removed FoundCity entirely
    -- assuming the SREH speech would arrive in time; in practice
    -- the SREH speech got NOINTERRUPT-queued behind plot tooltip /
    -- notification speech and arrived AFTER the user had already
    -- pressed Enter to dismiss the engine modal.
    FoundCity = "Founding city. Press Enter to confirm.",
    Sleep     = "Sleep",
    Fortify   = "Fortify",
    Alert     = "Alert",
    Attack    = "Attack",
    AutoExplore = "Auto explore",
    PauseMenu = "Pause menu",
    QuickSave = "Quick save",
    QuickLoad = "Quick load",
};

-- Cycle-to-self detection v3 (2026-05-26 evening).
-- Earlier attempts:
--   v1 — "expecting change" flag, cleared by UnitSelectionChanged,
--        checked on GameCoreEventPublishComplete. False-fired because
--        GameCoreEventPublishComplete sometimes ran BEFORE
--        UnitSelectionChanged in the engine's dispatch order, leaving
--        the flag set even when the cycle succeeded.
--   v2 — unit ID snapshot pre-cycle vs post-cycle (UI.GetHeadSelectedUnit).
--        Failed because UI.GetHeadSelectedUnit in the UI VM lags
--        behind UnitSelectionChanged — the cached selection still
--        read as the old unit even after the engine processed the
--        cycle.
--
-- v3 — countdown over 2 GameCoreEventPublishComplete firings. Sets
-- _cycleBatchesUntilCheck=2 on PrevUnit/NextUnit trigger.
-- UnitSelectionChanged for own player clears it to 0. Each
-- GameCoreEventPublishComplete decrements. If it reaches 0 by
-- decrement (not by clear), the cycle didn't change selection
-- within 2 engine batches → speak "Only one ready unit".
-- The 2-batch window gives UnitSelectionChanged time to arrive even
-- if it lags a batch behind the input event.
local _cycleBatchesUntilCheck = 0;

-- DIAGNOSTIC 2026-05-26: capture the first InputAction fired within
-- ~5 seconds AFTER FoundCity, plus the current UI state, so we can
-- identify what the "press Enter to dismiss" engine modal is after
-- city founding. Set on FoundCity trigger; cleared after one fire.
local _postFoundCityCapture = 0;

-- ---------------------------------------------------------------------------
-- Input dispatch — every action firing is spoken
-- ---------------------------------------------------------------------------

-- HelpAddin lives in a separate UI VM. Civ VI's InputAction events
-- fire globally regardless of which context owns the modal popup,
-- so without an explicit lockout the cursor still moves and units
-- still respond to letter keys while help is open. HelpAddin
-- broadcasts CivViAccess_HelpOpened / _HelpClosed; we track the
-- flag and bail out of OnInputActionTriggered while help is up so
-- the user's filter typing doesn't double-fire as cursor / unit
-- nav. Confirmed Noel 2026-05-27 — filter typing was previously
-- captured by Q/E/A/D/Z/C cursor handlers.
local _helpOpen = false;

-- Mod-wide "say again" (Ctrl+T): the last clean text any VM emitted via
-- Speech.emit, received over the cross-VM CivViAccess_SpeechEmitted event.
-- Lets the repeat key re-speak announces that originated in OTHER VMs (e.g. a
-- reveal-popup announce from the RevealListeners VM), which this VM's own
-- Speech state would never see. Updated on every emit; re-speaking just
-- re-stamps the same text, so no feedback loop.
local _lastSpoken = nil;

-- The LONG visual description of the most recent reveal popup (hero / secret
-- society), published by the RevealListeners addin over CivViAccess_RevealLongDesc.
-- Spoken on demand by Shift+I. Empty string = current reveal has no long desc
-- (cinematic/abstract reveals), so Shift+I reports "no description".
local _lastRevealLong = nil;

local function OnInputActionTriggered(actionId)
    if _helpOpen then return; end
    local name = _idToName[actionId] or ("ActionID " .. tostring(actionId));
    Log.info("HexCursorAddin: action fired id=" .. tostring(actionId) .. " name=" .. name);
    speak("Action " .. name);

    -- Always-on audible confirmation for the small set of actions
    -- the user needs to know fired (Tab/Enter/B/etc.). This is the
    -- "did the engine see my keypress" signal — silence means the
    -- key was intercepted before reaching Civ VI.
    --
    -- FoundCity pre-check: Civ VI silently refuses to found a city
    -- when the Settler has 0 moves remaining (the action propagates
    -- to the engine but no CityAddedToMap fires). Without this
    -- guard, our speakAlways("Founding city. Press Enter to confirm.")
    -- misleads the user — they hear the prompt, press Enter, hear
    -- the engine error click, and have no idea why nothing happened.
    -- Confirmed via Lua.log 2026-05-26: Trajan Settler moved SE
    -- (out of moves), B pressed, no city ever created.
    if name == "FoundCity" then
        local pUnit = (UI ~= nil and UI.GetHeadSelectedUnit ~= nil)
                      and UI.GetHeadSelectedUnit() or nil;
        if pUnit ~= nil and pUnit.GetMovesRemaining ~= nil then
            local mpOk, mp = pcall(function() return pUnit:GetMovesRemaining(); end);
            if mpOk and mp ~= nil and mp <= 0 then
                Speech.emit("Cannot found city, no moves remaining. End the turn first.",
                            "meta");
                return;
            end
        end
    end
    local always = ALWAYS_ANNOUNCE_ACTIONS[name];
    if always ~= nil then
        speakAlways(always);
    end

    -- Engine cycle: arm the 2-batch deferred check for cycle-to-self.
    if name == "PrevUnit" or name == "NextUnit" then
        _cycleBatchesUntilCheck = 2;
    end

    -- DIAGNOSTIC: post-FoundCity action capture. Arm on FoundCity;
    -- log the NEXT action after that with full UI state context so
    -- we can identify the "press Enter" engine modal.
    if name == "FoundCity" then
        _postFoundCityCapture = 5;  -- capture up to next 5 actions
        local mode = "?";
        local prodHidden = "?";
        pcall(function()
            if UI ~= nil and UI.GetInterfaceMode ~= nil then
                mode = tostring(UI.GetInterfaceMode());
            end
            if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
                local prod = ContextPtr:LookUpControl("/InGame/ProductionPanel");
                if prod ~= nil and prod.IsHidden ~= nil then
                    prodHidden = tostring(prod:IsHidden());
                end
            end
        end);
        Log.info("POSTFOUND_DIAG: FoundCity fired. InterfaceMode=" .. mode
                 .. " ProductionPanel:IsHidden=" .. prodHidden);
    elseif _postFoundCityCapture > 0 and name ~= "FoundCity" then
        _postFoundCityCapture = _postFoundCityCapture - 1;
        local mode = "?";
        pcall(function()
            if UI ~= nil and UI.GetInterfaceMode ~= nil then
                mode = tostring(UI.GetInterfaceMode());
            end
        end);
        Log.info("POSTFOUND_DIAG: next action after FoundCity = " .. name
                 .. " (id=" .. tostring(actionId) .. ") InterfaceMode=" .. mode);
    end

    local handler = _actionHandlers[actionId];
    if handler ~= nil then
        local ok, err = pcall(handler);
        if not ok then
            Log.error("HexCursorAddin: handler for " .. name .. " threw: " .. tostring(err));
            speak("Handler error");
        end
    end
end

-- ---------------------------------------------------------------------------
-- State-change announcers — speak when interface mode shifts, leader/popup
-- shows or hides, etc. Tells us what state the game is in.
-- ---------------------------------------------------------------------------

local function speakInterfaceMode()
    if UI ~= nil and UI.GetInterfaceMode ~= nil then
        local mode = UI.GetInterfaceMode();
        speakQueued("Interface mode " .. tostring(mode));
    end
end

local function OnInterfaceModeChanged(oldMode, newMode)
    speak("Interface mode changed: " .. tostring(oldMode) .. " to " .. tostring(newMode));
end

local function OnLoadScreenClose()
    speak("Load screen closed");
end

local function OnShowLeaderScreen(leaderName, isLocalPlayer)
    speak("Leader screen shown");   -- diagnostic (silenced unless DIAGNOSTIC_SPEECH)
    -- Make the otherwise-silent leader screen readable: who + mood-as-expression
    -- + Escape-to-leave (2026-06-01). Greeting text deferred to the full build.
    if LeaderMeetAnnounce ~= nil and LeaderMeetAnnounce.OnLeaderScreen ~= nil then
        local ok, err = pcall(LeaderMeetAnnounce.OnLeaderScreen, leaderName, isLocalPlayer);
        if not ok then Log.warn("OnShowLeaderScreen: announce failed: " .. tostring(err)); end
    end
end

local function OnHideLeaderScreen()
    speak("Leader screen hidden");
end

local function OnLocalPlayerTurnBegin()
    speakQueued("Your turn");
end

-- Set true just before a programmatic re-grab (UI.SelectUnit) so the resulting
-- UnitSelectionChanged doesn't double-announce "Unit selected".
local _suppressSelectAnnounce = false;

local function OnUnitSelectionChanged(playerId, unitId, hexI, hexJ, hexK, isSelected, isEditable)
    if Game == nil or playerId ~= Game.GetLocalPlayer() then return; end
    if isSelected then
        if _suppressSelectAnnounce then
            _suppressSelectAnnounce = false;   -- silent re-grab after a move
        else
            speakQueued("Unit selected at " .. tostring(hexI) .. " " .. tostring(hexJ));
        end
        -- Cycle succeeded — clear the pending cycle-to-self check.
        _cycleBatchesUntilCheck = 0;
    else
        -- The engine auto-deselects a unit after a move (even with moves left),
        -- stranding a keyboard player on "No unit selected". If UnitMovement
        -- flagged this unit as still-actionable, re-grab it. Clear the flag
        -- FIRST so a second engine deselect can't loop us; suppress the
        -- re-grab's own announce. (Noel 2026-06-01.)
        if UnitMovement ~= nil and UnitMovement.shouldKeepSelected ~= nil
           and UnitMovement.shouldKeepSelected(playerId, unitId) then
            UnitMovement.clearKeepSelected();
            local pPlayer = Players[playerId];
            local pUnit = (pPlayer ~= nil and pPlayer.GetUnits ~= nil)
                          and pPlayer:GetUnits():FindID(unitId) or nil;
            if pUnit ~= nil and pUnit:GetMovesRemaining() > 0
               and UI ~= nil and UI.SelectUnit ~= nil then
                _suppressSelectAnnounce = true;
                UI.SelectUnit(pUnit);
            end
        end
    end
end

-- Fires after each engine event batch. If the cycle-to-self counter
-- was armed (PrevUnit/NextUnit pressed), decrement once per batch.
-- If we reach 0 by decrement (not by UnitSelectionChanged clearing
-- it), the cycle didn't change selection within 2 batches → speak
-- "Only one ready unit" NOINTERRUPT so it queues behind the
-- action-name announce. Resilient against the UI-VM selection lag
-- that v1/v2 hit.
local function OnGameCoreEventPublishComplete()
    if _cycleBatchesUntilCheck <= 0 then return; end
    _cycleBatchesUntilCheck = _cycleBatchesUntilCheck - 1;
    if _cycleBatchesUntilCheck ~= 0 then return; end

    -- The cycle didn't land on a NEW ready unit. Find the unit to land on and
    -- SELECT it, so "only one unit" is actionable instead of a dead end (Noel
    -- 2026-06-11). The case that bit us: the only unit was busy auto-moving, so
    -- the engine deselected it AND dropped it from the ready cycle — leaving
    -- nothing selected and a nameless "only one ready unit". So prefer the
    -- selected unit, else the player's single unit (busy or not), re-select it
    -- (the user can then cancel its move / inspect), and announce it richly via
    -- StringifyUnit (which carries the "moving to X" status); W gives coordinates.
    local unit = (UI ~= nil and UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil;
    if unit == nil then
        local lp = Game.GetLocalPlayer();
        if lp ~= -1 and Players[lp] ~= nil and Players[lp].GetUnits ~= nil then
            local count, only = 0, nil;
            for _, u in Players[lp]:GetUnits():Members() do count = count + 1; only = u; end
            if count == 1 then unit = only; end
        end
    end
    if unit == nil then
        Speech.emit("No units ready", "meta");
        return;
    end
    if UI ~= nil and UI.SelectUnit ~= nil then
        local cur = (UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil;
        if cur ~= unit then pcall(function() UI.SelectUnit(unit); end); end
    end
    -- Snap the cursor onto the unit so it's positioned to move/inspect — even when
    -- selection DIDN'T change (single already-selected unit), where the UnitInfo
    -- cursor-follow never fires because no UnitSelectionChanged event is raised.
    -- (Noel 2026-06-11: pressed comma on his lone Warrior, cursor stayed on the city.)
    if HexCursor ~= nil and HexCursor.jumpTo ~= nil then
        pcall(function() HexCursor.jumpTo(unit:GetX(), unit:GetY()); end);
    end
    local name = (StringifyUnit ~= nil) and StringifyUnit(unit) or "unit";
    Speech.emit("Only one unit, " .. name, "meta");
end

-- LuaEvents fired by various popup screens — tells us which popup is up
local function makeLuaEventLogger(name)
    return function(...)
        speakQueued("Lua event " .. name);
    end
end

-- ---------------------------------------------------------------------------
-- Initialization
-- ---------------------------------------------------------------------------

local function Initialize()
    Log.info("HexCursorAddin.Initialize: starting");

    -- Our own CivViAccess actions (with handlers)
    lookupAction("CIVVIACCESS_CursorNW", function() HexCursor.move(DIR_NW); end);
    lookupAction("CIVVIACCESS_CursorNE", function() HexCursor.move(DIR_NE); end);
    lookupAction("CIVVIACCESS_CursorW",  function() HexCursor.move(DIR_W);  end);
    lookupAction("CIVVIACCESS_CursorE",  function() HexCursor.move(DIR_E);  end);
    lookupAction("CIVVIACCESS_CursorSW", function() HexCursor.move(DIR_SW); end);
    lookupAction("CIVVIACCESS_CursorSE", function() HexCursor.move(DIR_SE); end);
    -- Where-am-I + rich locate MIGRATED to the capture-all wrap (2026-06-09):
    -- W = quick where-am-I, Shift+W = rich locate (HexCursor.speakWhereAmI /
    -- speakSurvey, routed by ScannerSurvey.dispatch). This frees bare S for the
    -- radius SURVEY (S) + sonify (Alt+S). The old S / Shift+S InputActions
    -- (CIVVIACCESS_WhereAmICenter / _WhereAmI) are left DEFINED but UNWIRED so that
    -- even if the wrap doesn't suppress a mod InputAction, pressing S can't
    -- double-fire the old where-am-I. See docs/HOTKEY_REFERENCE.md.
    --   lookupAction("CIVVIACCESS_WhereAmI",       HexCursor.speakSurvey);
    --   lookupAction("CIVVIACCESS_WhereAmICenter", HexCursor.speakWhereAmI);
    lookupAction("CIVVIACCESS_OpenHelp",    function()
        if HexCursor.openHelp ~= nil then HexCursor.openHelp(); end
    end);

    -- 0.5.0 unit direct-move. UnitMovement.directMove handles selection,
    -- enemy check, MP gate, and the engine's own MoveUnitToPlot commit.
    lookupAction("CIVVIACCESS_MoveNW", function() UnitMovement.directMove(DIR_NW); end);
    lookupAction("CIVVIACCESS_MoveNE", function() UnitMovement.directMove(DIR_NE); end);
    lookupAction("CIVVIACCESS_MoveW",  function() UnitMovement.directMove(DIR_W);  end);
    lookupAction("CIVVIACCESS_MoveE",  function() UnitMovement.directMove(DIR_E);  end);
    lookupAction("CIVVIACCESS_MoveSW", function() UnitMovement.directMove(DIR_SW); end);
    lookupAction("CIVVIACCESS_MoveSE", function() UnitMovement.directMove(DIR_SE); end);

    -- 0.5.0 unit info readout + cursor-on-unit recenter. Bare / and
    -- Ctrl+/ — Civ V Access parity per CivVAccess_UnitControlSelection.
    lookupAction("CIVVIACCESS_UnitInfo",       UnitInfo.speakInfo);
    lookupAction("CIVVIACCESS_RecenterOnUnit", UnitInfo.recenterOnUnit);
    lookupAction("CIVVIACCESS_NextUnitAll",    function() UnitInfo.cycleAllUnits(true);  end);
    lookupAction("CIVVIACCESS_PrevUnitAll",    function() UnitInfo.cycleAllUnits(false); end);

    -- 0.5.2 city production unblock (Alt+P). Workaround for
    -- ENDTURN_BLOCKING_PRODUCTION until the full picker lands. Queues
    -- Monument / Warrior / cheapest-available into every blocked city.
    lookupAction("CIVVIACCESS_UnblockProduction", CityProduction.unblockAll);

    -- 0.5.2 Rest (R) = smart cascade. Civilians sleep, military
    -- fortifies; ALERT/HEAL/SKIP_TURN as fallbacks. Civ V Access
    -- parity for "one key to rest a unit."
    lookupAction("CIVVIACCESS_Rest", UnitMovement.rest);
    -- 0.5.2 strict Sleep (Alt+Z) = sleep-only with educational
    -- redirect to R for military units (Civ V muscle-memory catch).
    lookupAction("CIVVIACCESS_Sleep", UnitMovement.sleepStrict);
    -- Auto-explore (Alt+X). Issues UNITOPERATION_AUTOMATE_EXPLORE directly;
    -- can't use Alt+E (bare-E cursor pan intercepts it — see RemapForHexCursor).
    lookupAction("CIVVIACCESS_AutoExplore", function()
        if UnitMovement == nil or UnitMovement.autoExplore == nil then
            Speech.emit("Auto explore unavailable", "meta");
            return;
        end
        UnitMovement.autoExplore();
    end);

    -- Build improvement with selected Builder (Shift+B). Opens the navigable
    -- BuildImprovementPicker (a separate modal Context) via LuaEvent — the
    -- picker resolves the selected unit, lists the tile's improvements
    -- recommended-first, and issues BUILD_IMPROVEMENT on commit. Cross-context
    -- (sandboxed Lua states) so it's a LuaEvent fire, like the production picker.
    -- (UnitMovement.buildImprovement remains as the v1 auto-build / enumeration
    -- reference; not bound now that the picker supersedes it.)
    lookupAction("CIVVIACCESS_BuildImprovement", function()
        if LuaEvents == nil then
            Speech.emit("LuaEvents unavailable", "meta");
            return;
        end
        local ok, err = pcall(function()
            LuaEvents.CivViAccess_OpenBuildPicker();
        end);
        if not ok then
            Log.error("HexCursorAddin: build picker LuaEvent fire failed: " .. tostring(err));
            Speech.emit("Build picker dispatch failed", "meta");
        end
    end);

    -- 0.5.1 production picker open (Shift+P). Stage-1 test hotkey;
    -- Stage 2 makes notification activation the canonical entry.
    -- Picker lives in its own UI Context (ProductionPickerAddin) with
    -- a SEPARATE Lua VM — globals aren't shared. Cross-VM via
    -- LuaEvents.CivViAccess_OpenProductionPicker(ownerID, cityID). The
    -- picker Context subscribes and resolves the city on its end.
    -- Resolves city to open against: head-selected city, else capital,
    -- else first city in iteration order.
    lookupAction("CIVVIACCESS_OpenProductionPicker", function()
        local localPlayerID = Game.GetLocalPlayer();
        if localPlayerID == -1 then return; end
        local pPlayer = Players[localPlayerID];
        if pPlayer == nil then return; end
        local pCity = nil;
        -- City under the CURSOR wins (Noel 2026-06-12: with two cities,
        -- Shift+P always opened the capital — scan to the other city, Home,
        -- Shift+P should manage it without travel). Cursor = universal pointer.
        if Cities ~= nil and Cities.GetCityInPlot ~= nil
           and HexCursor ~= nil and HexCursor.position ~= nil then
            local cx, cy = HexCursor.position();
            if cx ~= nil then
                local c = Cities.GetCityInPlot(cx, cy);
                if c ~= nil and c:GetOwner() == localPlayerID then pCity = c; end
            end
        end
        if pCity == nil and UI ~= nil and UI.GetHeadSelectedCity ~= nil then
            pCity = UI.GetHeadSelectedCity();
        end
        if pCity == nil then
            pCity = pPlayer:GetCities():GetCapitalCity();
        end
        if pCity == nil then
            for _, c in pPlayer:GetCities():Members() do
                pCity = c;
                break;
            end
        end
        if pCity == nil then
            Speech.emit("No city to manage", "meta");
            return;
        end
        Log.info("HexCursorAddin: firing LuaEvent CivViAccess_OpenProductionPicker for owner="
                 .. tostring(pCity:GetOwner()) .. " cityID=" .. tostring(pCity:GetID()));
        if LuaEvents == nil then
            Speech.emit("LuaEvents unavailable", "meta");
            return;
        end
        -- Civ VI auto-creates LuaEvent slots on first access. No nil
        -- check needed; fire unconditionally and let the subscriber
        -- side handle it. If no subscriber (different VM, not yet
        -- loaded), this is a silent no-op — we'd see no follow-up in
        -- the log and Noel hears nothing.
        local ok, err = pcall(function()
            LuaEvents.CivViAccess_OpenProductionPicker(pCity:GetOwner(), pCity:GetID());
        end);
        if not ok then
            Log.error("HexCursorAddin: LuaEvent fire failed: " .. tostring(err));
            Speech.emit("Picker dispatch failed", "meta");
        end
    end);

    -- 0.5.4 tech picker open (Alt+T). Lives in TechPickerAddin's
    -- separate UI VM, same cross-VM LuaEvent dispatch shape as the
    -- production picker. The picker doesn't need a city — research
    -- is civilization-wide — so no fallback resolution is required
    -- here, just a no-arg LuaEvent fire.
    lookupAction("CIVVIACCESS_OpenTechPicker", function()
        if LuaEvents == nil then
            Speech.emit("LuaEvents unavailable", "meta");
            return;
        end
        Log.info("HexCursorAddin: firing LuaEvent CivViAccess_OpenTechPicker");
        local ok, err = pcall(function()
            LuaEvents.CivViAccess_OpenTechPicker();
        end);
        if not ok then
            Log.error("HexCursorAddin: tech picker LuaEvent fire failed: " .. tostring(err));
            Speech.emit("Tech picker dispatch failed", "meta");
        end
    end);

    -- 0.5.4 civic picker open (Alt+L). Civ-wide same as tech. L for
    -- "law" — bare C in cursor mode is CursorSE, and Civ VI's gesture
    -- parser ignored the Alt modifier on Alt+C, firing CursorSE. Alt+L
    -- mirrors the Alt+letter safe-modifier pattern.
    lookupAction("CIVVIACCESS_OpenCivicPicker", function()
        if LuaEvents == nil then
            Speech.emit("LuaEvents unavailable", "meta");
            return;
        end
        Log.info("HexCursorAddin: firing LuaEvent CivViAccess_OpenCivicPicker");
        local ok, err = pcall(function()
            LuaEvents.CivViAccess_OpenCivicPicker();
        end);
        if not ok then
            Log.error("HexCursorAddin: civic picker LuaEvent fire failed: " .. tostring(err));
            Speech.emit("Civic picker dispatch failed", "meta");
        end
    end);

    -- Verbosity toggle (chatty / terse) on Shift+V — consistent with the menus
    -- (BaseMenu uses Shift+V too). Shift+ doesn't collide with the bare-V engine
    -- Alert the way Alt+V did (same proven rail as the Shift+QAZEDC moves), and
    -- it sidesteps the menu type-ahead that bare V would trigger. Noel 2026-06-03.
    lookupAction("CIVVIACCESS_VerbosityToggle", function()
        if Verbosity == nil or Verbosity.toggle == nil then
            Speech.emit("Verbosity unavailable", "meta");
            return;
        end
        local on = Verbosity.toggle();
        Speech.emit(on and "Verbose on" or "Verbose off", "event");
    end);

    -- WebView2 report bridge smoke test (Alt+K). Streams a sample HTML
    -- report to the launcher's WebView2 window via Report.show. Temporary
    -- trigger to prove the bridge end-to-end; the real report-open key is
    -- Noel's call once it's validated.
    lookupAction("CIVVIACCESS_ShowReportTest", function()
        if Report == nil or Report.showTest == nil then
            Speech.emit("Report bridge unavailable", "meta");
            return;
        end
        Speech.emit("Opening test report", "meta");
        Report.showTest();
    end);

    -- Empire status report (bare U). First real consumer of the report
    -- bridge: yields, research/civic ETA, cities, idle units, city-states,
    -- and an end-turn "needs attention" checklist, rendered in the WebView2
    -- window. Provisional key — Noel confirms/renames alongside the EOT report.
    lookupAction("CIVVIACCESS_EmpireStatus", function()
        if EmpireStatus == nil or EmpireStatus.show == nil then
            Speech.emit("Empire status unavailable", "meta");
            return;
        end
        EmpireStatus.show();
    end);

    -- End-of-turn report (bare N). Second real consumer of the report bridge:
    -- "what happened last turn" delta. Auto-announces availability at each
    -- turn-begin; this key opens the report. Provisional key.
    lookupAction("CIVVIACCESS_EotReport", function()
        if EotReport == nil or EotReport.show == nil then
            Speech.emit("End of turn report unavailable", "meta");
            return;
        end
        EotReport.show();
    end);

    -- DEBUG meet-leader (Alt+M). Opens diplomacy with the first met major civ
    -- so we can test the leader-meet announce + lock in the greeting control
    -- path without waiting for a natural first contact. Dev convenience over
    -- the FireTuner CivViAccess_DebugMeetLeader line; remove/guard before a
    -- public release.
    lookupAction("CIVVIACCESS_DebugMeetLeader", function()
        if LeaderMeetAnnounce == nil or LeaderMeetAnnounce.DebugMeet == nil then
            Speech.emit("Debug meet unavailable", "meta");
            return;
        end
        LeaderMeetAnnounce.DebugMeet();
    end);

    -- Mod-wide "say again" (Ctrl+T): re-speak the last announcement from ANY
    -- VM. Works over the vanilla DLC reveal popups (engine actions fire while
    -- those Low-priority popups are up). _lastSpoken is fed by the cross-VM
    -- CivViAccess_SpeechEmitted broadcast (subscribed just below).
    lookupAction("CIVVIACCESS_RepeatAnnounce", function()
        if _lastSpoken == nil or _lastSpoken == "" then
            Speech.emit("Nothing to repeat", "meta");
            return;
        end
        Speech.emit(_lastSpoken, "selection");
    end);
    if LuaEvents.CivViAccess_SpeechEmitted ~= nil then
        LuaEvents.CivViAccess_SpeechEmitted.Add(function(text, kind)
            if text ~= nil and text ~= "" then _lastSpoken = text; end
        end);
    end

    -- Shift+T: verbose tile readout (full mechanics — yields, defense bonus,
    -- appeal, fresh water, movement cost, continent) for the hex under the
    -- cursor. The deep layer the terse nav announce omits. Repeat-announce
    -- moved to Shift+R to free the "T = Tile" mnemonic (2026-06-01).
    lookupAction("CIVVIACCESS_DescribeTile", function()
        if HexCursor == nil or HexCursor.DescribeVerbose == nil then
            Speech.emit("Tile readout unavailable", "meta");
            return;
        end
        HexCursor.DescribeVerbose();
    end);

    -- Shift+I: read the full (long) visual description of the last reveal
    -- popup. Fed by the RevealListeners addin via CivViAccess_RevealLongDesc.
    lookupAction("CIVVIACCESS_RevealLongDesc", function()
        if _lastRevealLong == nil or _lastRevealLong == "" then
            Speech.emit("No full description available", "meta");
            return;
        end
        Speech.emit(_lastRevealLong, "selection");
    end);
    if LuaEvents.CivViAccess_RevealLongDesc ~= nil then
        LuaEvents.CivViAccess_RevealLongDesc.Add(function(text)
            _lastRevealLong = text;  -- "" clears it for no-long reveals
        end);
    end

    -- 0.5.2 notifications center: bare [ / ] walk pending, Alt+N
    -- toggles the idle reminder. Notifications module is loaded via
    -- AddGameplayScripts and exposes the global Notifications.* API.
    if Notifications ~= nil then
        lookupAction("CIVVIACCESS_NotificationPrev",            Notifications.cyclePrev);
        lookupAction("CIVVIACCESS_NotificationNext",            Notifications.cycleNext);
        lookupAction("CIVVIACCESS_NotificationReminderToggle",  Notifications.toggleReminder);
    end



    -- Built-in engine actions (no handlers — just announce by name when triggered)
    local engineActions = {
        "PauseMenu", "QuickSave", "QuickLoad", "EndTurn", "SkipTurn",
        "FoundCity", "MoveTo", "Fortify", "FortifyUntilHeal", "DeleteUnit",
        "Attack", "RangedAttack", "AutoExplore", "Sleep", "Alert",
        "ToggleTechTree", "ToggleCivicsTree", "ToggleGovernment", "ToggleReligion",
        "ToggleGreatPeople", "ToggleGreatWorks", "ToggleRankings", "ToggleCityStates",
        "ToggleEspionage", "ToggleTradeRoutes", "OpenCivilopedia",
        "CivilopediaBack", "CivilopediaForward", "ToggleFSMap", "OpenMapSearch",
        "ToggleGrid", "ToggleYield", "ToggleResources", "Toggle2DView",
        "PrevUnit", "NextUnit", "PrevCity", "NextCity", "CapitalCity",
        "OnlinePause", "CameraPanUp", "CameraPanDown", "CameraPanLeft", "CameraPanRight",
        "LensReligion", "LensContinent", "LensAppeal", "LensSettler",
        "LensGovernment", "LensPolitical", "LensTourism", "LensEmpire",
    };
    for _, name in ipairs(engineActions) do
        lookupAction(name, nil);
    end

    Events.InputActionTriggered.Add(OnInputActionTriggered);

    -- Interface-mode / state events
    if Events.InterfaceModeChanged ~= nil then Events.InterfaceModeChanged.Add(OnInterfaceModeChanged); end
    if Events.LoadScreenClose ~= nil then Events.LoadScreenClose.Add(OnLoadScreenClose); end
    if Events.ShowLeaderScreen ~= nil then Events.ShowLeaderScreen.Add(OnShowLeaderScreen); end
    if Events.HideLeaderScreen ~= nil then Events.HideLeaderScreen.Add(OnHideLeaderScreen); end
    if Events.LocalPlayerTurnBegin ~= nil then Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBegin); end
    if Events.UnitSelectionChanged ~= nil then Events.UnitSelectionChanged.Add(OnUnitSelectionChanged); end
    if Events.GameCoreEventPublishComplete ~= nil then
        Events.GameCoreEventPublishComplete.Add(OnGameCoreEventPublishComplete);
    end

    -- LuaEvents — popup / advisor signals
    if LuaEvents ~= nil then
        local luaEventsToWatch = {
            "AdvisorPopup_ShowAdvisorPopup",
            "AdvisorPopup_ClearActiveAdvisor",
            "InGame_OpenInGameOptionsMenu",
            "InGameTopOptionsMenu_Show",
            "InGameTopOptionsMenu_Close",
            "PlayerChange_Show",
            "PlayerChange_Close",
            "NotificationPanel_ShowNotificationContent",
            "Tutorial_TutorialEnd",
        };
        for _, name in ipairs(luaEventsToWatch) do
            local ev = LuaEvents[name];
            if ev ~= nil and ev.Add ~= nil then
                local ok = pcall(function() ev.Add(makeLuaEventLogger(name)); end);
                if ok then Log.info("HexCursorAddin: subscribed LuaEvent " .. name); end
            end
        end

        -- Help open/close: lock out our InputAction handler while
        -- help is up so cursor / unit keys don't fire underneath
        -- HelpAddin's filter input.
        if LuaEvents.CivViAccess_HelpOpened ~= nil then
            LuaEvents.CivViAccess_HelpOpened.Add(function()
                _helpOpen = true;
                Log.info("HexCursorAddin: _helpOpen=true");
            end);
        end
        if LuaEvents.CivViAccess_HelpClosed ~= nil then
            LuaEvents.CivViAccess_HelpClosed.Add(function()
                _helpOpen = false;
                Log.info("HexCursorAddin: _helpOpen=false");
            end);
        end
    end

    Log.info("HexCursorAddin.Initialize: complete. diagnostic speech="
             .. tostring(DIAGNOSTIC_SPEECH));
    speak("HexCursor diagnostic mode active");
end
Initialize();
