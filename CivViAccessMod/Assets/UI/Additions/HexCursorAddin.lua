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
include("ScreenReaderPlotUtils");
include("Help");
include("HexGeom");
include("HexCursor");
include("UnitMovement");
include("UnitInfo");
include("CityProduction");
include("Notifications");

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

local function OnInputActionTriggered(actionId)
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

local function OnShowLeaderScreen()
    speak("Leader screen shown");
end

local function OnHideLeaderScreen()
    speak("Leader screen hidden");
end

local function OnLocalPlayerTurnBegin()
    speakQueued("Your turn");
end

local function OnUnitSelectionChanged(playerId, unitId, hexI, hexJ, hexK, isSelected, isEditable)
    if Game ~= nil and playerId == Game.GetLocalPlayer() and isSelected then
        speakQueued("Unit selected at " .. tostring(hexI) .. " " .. tostring(hexJ));
        -- Cycle succeeded — clear the pending cycle-to-self check.
        _cycleBatchesUntilCheck = 0;
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
    if _cycleBatchesUntilCheck == 0 then
        -- Include the current unit's name so the user knows what
        -- they're still on, not just that nothing changed.
        local msg = "Only one ready unit";
        if UI ~= nil and UI.GetHeadSelectedUnit ~= nil then
            local sel = UI.GetHeadSelectedUnit();
            if sel ~= nil then
                local row = GameInfo.Units[sel:GetUnitType()];
                if row ~= nil and row.Name ~= nil then
                    local nm = Locale.Lookup(row.Name);
                    if nm ~= nil and nm ~= "" then
                        msg = msg .. ". " .. nm;
                    end
                end
            end
        end
        Speech.emit(msg, "meta");
    end
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
    lookupAction("CIVVIACCESS_WhereAmI",    HexCursor.speakWhereAmI);
    lookupAction("CIVVIACCESS_WhereAmIAbs", HexCursor.speakWhereAmIAbs);
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
        if UI ~= nil and UI.GetHeadSelectedCity ~= nil then
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
    end

    Log.info("HexCursorAddin.Initialize: complete. diagnostic speech="
             .. tostring(DIAGNOSTIC_SPEECH));
    speak("HexCursor diagnostic mode active");
end
Initialize();
