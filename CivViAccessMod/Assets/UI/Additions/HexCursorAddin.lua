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
-- user should call OutputMessageToScreenReader directly via
-- speakAlways() below.
local function speak(text)
    if not DIAGNOSTIC_SPEECH then return; end
    OutputMessageToScreenReader(text);
end

local function speakQueued(text)
    if not DIAGNOSTIC_SPEECH then return; end
    OutputMessageToScreenReader(text, true);
end

-- Bypasses the DIAGNOSTIC_SPEECH gate. Use for actions the user
-- genuinely needs audible confirmation of every time, regardless of
-- diagnostic mode (Tab → Next unit, Enter → End turn, etc.).
local function speakAlways(text)
    OutputMessageToScreenReader(text);
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
    FoundCity = "Found city",
    Sleep     = "Sleep",
    Fortify   = "Fortify",
    Alert     = "Alert",
    Attack    = "Attack",
    AutoExplore = "Auto explore",
    PauseMenu = "Pause menu",
    QuickSave = "Quick save",
    QuickLoad = "Quick load",
};

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
    local always = ALWAYS_ANNOUNCE_ACTIONS[name];
    if always ~= nil then
        speakAlways(always);
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
