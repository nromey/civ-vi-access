-- DiplomacyAccess — screen-reader first-contact / diplomacy overview.
--
-- When the vanilla DiplomacyActionView opens it fires
-- LuaEvents.DiploScene_SceneOpened(selectedPlayerID, liteMode) — a cross-context
-- LuaEvent we can hear from this VM. On that signal we:
--   1. announce who you're meeting,
--   2. extract the GREETING statement and its selectable options, and
--   3. present them as a navigable list; Enter commits the chosen option.
--
-- ARCHITECTURE (recon + source read 2026-06-03): the diplomacy screen's own
-- GetStatementHandler is NOT reachable from our VM (probe: false). BUT the
-- DiplomacyStatementSupport.lua helpers ARE (probe: RemoveInvalidSelections /
-- RemoveSelectionByKey / DiplomacyMoodTypes / DiplomacyInitiatorTypes all true),
-- and DiplomacySupport_ExtractStatement uses its `handler` arg only for
-- ParseStatement / ParseStatementSelection (the default globals). So we
-- synthesize a minimal handler and run the WHOLE extract → filter → present →
-- commit flow in our own VM — no fragile injection into DiplomacyActionView (and
-- no conflict with its Expansion1/Expansion2 replacements). Commit mirrors the
-- engine's OnSelectInitialDiplomacyStatement: DiplomacyManager.RequestSession(
-- localID, otherID, <choice key minus the CHOICE_ prefix>).
--
-- Input model mirrors BuildImprovementPicker (the proven world-view modal): a
-- separate sandboxed Context opened via UIManager:QueuePopup so the engine makes
-- us the active modal and routes raw KeyUp to SetInputHandler, dispatched through
-- the shared InputRouter/HandlerStack. We LAYER over the vanilla diplo screen
-- (the same "modal over vanilla" approach the reveal popups use). Closed via
-- DequeuePopup.
--
-- PASS 1 (2026-06-03): instrumented. Everything is heavily logged so the first
-- live meet confirms (a) extraction works from our VM, (b) the option/key shape,
-- and (c) that RequestSession commits cleanly. Aggressive/disabled options are
-- clearly labelled and read on focus, so Enter is always deliberate.

include("Log");
include("ScreenReader");
include("HandlerStack");
include("InputRouter");
-- Pull the engine's diplomacy statement helpers into THIS context's VM. Each Civ
-- VI UI Context is a separate Lua state, so the support globals reachable in the
-- HexCursorAddin VM are NOT inherited here. The probe (LeaderMeetAnnounce) proved
-- this exact include brings DiplomacySupport_ExtractStatement / ParseStatement /
-- ParseStatementSelection / RemoveInvalidSelections / RemoveSelectionByKey /
-- GetPlayerMood into a mod context (GetStatementHandler stays absent — it lives
-- in DiplomacyActionView, which we deliberately don't touch). pcall-guarded so a
-- missing base file can't break our load.
pcall(function() include("DiplomacyStatementSupport"); end);

DiplomacyAccess = DiplomacyAccess or {};

local bind     = HandlerStack.bind;
local MOD_NONE = InputRouter.MOD_NONE;
local MOD_CTRL = InputRouter.MOD_CTRL;

local VK_RETURN = (Keys ~= nil and Keys.VK_RETURN) or 0x0D;
local VK_SPACE  = (Keys ~= nil and Keys.VK_SPACE)  or 0x20;
local VK_ESCAPE = (Keys ~= nil and Keys.VK_ESCAPE) or 0x1B;
local VK_END    = (Keys ~= nil and Keys.VK_END)    or 0x23;
local VK_HOME   = (Keys ~= nil and Keys.VK_HOME)   or 0x24;
local VK_UP     = (Keys ~= nil and Keys.VK_UP)     or 0x26;
local VK_DOWN   = (Keys ~= nil and Keys.VK_DOWN)   or 0x28;
local VK_T      = (Keys ~= nil and Keys.VK_T)      or 0x54;

local _open     = false;
local _items    = {};     -- { {label=, key=, disabled=}, ... }
local _index    = 1;
local _localID  = -1;
local _otherID  = -1;
local _greeting = nil;    -- full greeting text for Ctrl+T re-read

local function lp()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

-- "Cleopatra of Egypt" for a player id, best-effort.
local function leaderCivPhrase(playerID)
    if PlayerConfigurations == nil or PlayerConfigurations[playerID] == nil then
        return "an unknown leader";
    end
    local cfg = PlayerConfigurations[playerID];
    local leader, civ = nil, nil;
    if cfg.GetLeaderName ~= nil then
        local ok, v = pcall(function() return cfg:GetLeaderName(); end);
        if ok and v ~= nil then leader = Locale.Lookup(v); end
    end
    if cfg.GetCivilizationShortDescription ~= nil then
        local ok, v = pcall(function() return cfg:GetCivilizationShortDescription(); end);
        if ok and v ~= nil then civ = Locale.Lookup(v); end
    end
    if leader ~= nil and civ ~= nil then return leader .. " of " .. civ; end
    return leader or civ or "an unknown leader";
end

-- The default statement handler, synthesized — we don't have GetStatementHandler
-- in this VM, but ExtractStatement only needs these two parse callbacks.
local function makeHandler()
    return {
        ParseStatement          = DiplomacySupport_ParseStatement,
        ParseStatementSelection = DiplomacySupport_ParseStatementSelection,
    };
end

-- Run the engine's own extract → filter pipeline in our VM. Returns the parsed
-- statement table (with .Selections) or nil + reason.
local function extractGreeting(localID, otherID)
    if DiplomacySupport_ExtractStatement == nil
       or DiplomacySupport_ParseStatement == nil
       or DiplomacySupport_ParseStatementSelection == nil then
        return nil, "diplomacy support functions not reachable in this VM";
    end

    local mood = (DiplomacyMoodTypes ~= nil) and DiplomacyMoodTypes.ANY or nil;
    if Players ~= nil and Players[otherID] ~= nil and DiplomacySupport_GetPlayerMood ~= nil then
        local ok, m = pcall(function() return DiplomacySupport_GetPlayerMood(Players[otherID], localID); end);
        if ok and m ~= nil then mood = m; end
    end
    local initiator = (DiplomacyInitiatorTypes ~= nil) and DiplomacyInitiatorTypes.HUMAN or nil;

    local handler = makeHandler();
    local ok, kParsed = pcall(function()
        return DiplomacySupport_ExtractStatement(handler, "GREETING", "NONE", localID, mood, initiator);
    end);
    if not ok or kParsed == nil then
        return nil, "ExtractStatement failed: " .. tostring(kParsed);
    end
    pcall(function() DiplomacySupport_RemoveInvalidSelections(kParsed, localID, otherID); end);
    pcall(function() DiplomacySupport_RemoveSelectionByKey(kParsed, "CHOICE_EXIT"); end);
    return kParsed;
end

local function buildItems(kParsed)
    local items = {};
    local sel = kParsed and kParsed.Selections or nil;
    if sel == nil then return items; end
    for _, s in ipairs(sel) do
        local label = (s.Text ~= nil) and Locale.Lookup(s.Text) or (s.Key or "option");
        if s.IsDisabled then
            local reasons = {};
            if s.FailureReasons ~= nil then
                for _, r in ipairs(s.FailureReasons) do reasons[#reasons + 1] = Locale.Lookup(r); end
            end
            label = label .. ", unavailable"
                    .. ((#reasons > 0) and (": " .. table.concat(reasons, "; ")) or "");
        end
        items[#items + 1] = { label = label, key = s.Key, disabled = s.IsDisabled == true };
        Log.info("DiplomacyAccess: option key=" .. tostring(s.Key)
            .. " disabled=" .. tostring(s.IsDisabled == true)
            .. " action=" .. tostring(s.DiplomaticActionType));
    end
    return items;
end

local function announceCurrent()
    local item = _items[_index];
    if item == nil then return; end
    Speech.emit(item.label .. ". " .. _index .. " of " .. #_items, "status");
end

local function navTo(i)
    if #_items == 0 then return; end
    if i < 1 then i = 1; end
    if i > #_items then i = #_items; end
    _index = i;
    announceCurrent();
end

local function rereadGreeting()
    if _greeting ~= nil and _greeting ~= "" then
        Speech.emit(_greeting, "status");
    else
        announceCurrent();
    end
end

local function commit()
    local item = _items[_index];
    if item == nil then return; end
    if item.disabled then
        Speech.emit(item.label, "meta");  -- label already carries the reason
        return;
    end
    if item.key == nil then
        Speech.emit("That option can't be selected.", "meta");
        return;
    end
    -- Engine maps the CHOICE_ key to a statement name; for the common cases that
    -- is the key minus the CHOICE_ prefix (CHOICE_MAKE_DEAL -> MAKE_DEAL). The
    -- war/submenu cases are richer and handled in a later pass — logged here.
    local statement = string.gsub(item.key, "^CHOICE_", "");
    Log.info("DiplomacyAccess: commit key=" .. tostring(item.key)
        .. " -> statement=" .. tostring(statement)
        .. " local=" .. tostring(_localID) .. " other=" .. tostring(_otherID));
    local ok, err = pcall(function()
        DiplomacyManager.RequestSession(_localID, _otherID, statement);
    end);
    if ok then
        Speech.emit("Selecting " .. item.label, "event");
    else
        Speech.emit("Couldn't complete that selection.", "meta");
        Log.error("DiplomacyAccess: RequestSession failed: " .. tostring(err));
    end
    DiplomacyAccess.close();
end

local function cancel()
    Speech.emit("Closing diplomacy options", "meta");
    DiplomacyAccess.close();
end

local _handler = {
    name = "DiplomacyAccess",
    capturesAllInput = true,
    bindings = {
        bind(VK_UP,     MOD_NONE, function() navTo(_index - 1); end, "Previous option"),
        bind(VK_DOWN,   MOD_NONE, function() navTo(_index + 1); end, "Next option"),
        bind(VK_HOME,   MOD_NONE, function() navTo(1); end,          "First option"),
        bind(VK_END,    MOD_NONE, function() navTo(#_items); end,    "Last option"),
        bind(VK_RETURN, MOD_NONE, commit, "Choose this option"),
        bind(VK_SPACE,  MOD_NONE, commit, "Choose this option"),
        bind(VK_ESCAPE, MOD_NONE, cancel, "Close diplomacy options"),
        bind(VK_T,      MOD_CTRL, rereadGreeting, "Re-read the greeting"),
    },
    helpEntries = {
        { keyLabel = "Up/Down", description = "Previous / next diplomatic option" },
        { keyLabel = "Home/End", description = "First / last option" },
        { keyLabel = "Enter", description = "Choose the selected option" },
        { keyLabel = "Ctrl+T", description = "Re-read the leader's greeting" },
        { keyLabel = "Escape", description = "Close the options list" },
    },
};

function DiplomacyAccess.open(otherID)
    if _open then return; end
    _localID = lp();
    _otherID = otherID;
    if _otherID == nil or _otherID < 0 or _otherID == _localID then
        Log.warn("DiplomacyAccess.open: invalid otherID " .. tostring(otherID));
        return;
    end

    local who = leaderCivPhrase(_otherID);

    local kParsed, reason = extractGreeting(_localID, _otherID);
    if kParsed == nil then
        -- Still tell the user who they're dealing with even if extraction fails.
        Speech.emit("Diplomacy with " .. who .. ". Options unavailable.", "critical");
        Log.warn("DiplomacyAccess.open: " .. tostring(reason));
        return;
    end
    _greeting = (kParsed.StatementText ~= nil) and Locale.Lookup(kParsed.StatementText) or nil;
    _items = buildItems(kParsed);
    _index = 1;

    if #_items == 0 then
        Speech.emit("Diplomacy with " .. who .. ". No options available right now.", "critical");
        return;
    end

    _open = true;
    if UIManager ~= nil and UIManager.QueuePopup ~= nil and PopupPriority ~= nil then
        UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
    end
    HandlerStack.push(_handler);
    Speech.emit("Diplomacy with " .. who .. ". " .. #_items .. " options.", "critical");
    announceCurrent();
end

function DiplomacyAccess.close()
    if not _open then return; end
    _open = false;
    HandlerStack.removeByName("DiplomacyAccess");
    if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
        UIManager:DequeuePopup(ContextPtr);
    end
end

-- Raw input only matters while open; dispatch KeyUp through the shared stack.
local function onInput(pInputStruct)
    if not _open or pInputStruct == nil then return false; end
    local msgType = pInputStruct.GetMessageType and pInputStruct:GetMessageType();
    local keyUp = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257;
    if msgType ~= keyUp then return false; end
    local key  = pInputStruct:GetKey();
    local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);
    return InputRouter.dispatch(key, mods);
end

-- The vanilla diplo screen opened: layer our options list over it. liteMode is
-- the engine's read-only/ribbon variant — we still read who and the greeting.
local function OnSceneOpened(selectedPlayerID, liteMode)
    Log.info("DiplomacyAccess: DiploScene_SceneOpened other=" .. tostring(selectedPlayerID)
        .. " lite=" .. tostring(liteMode));
    local ok, err = pcall(function() DiplomacyAccess.open(selectedPlayerID); end);
    if not ok then Log.error("DiplomacyAccess.open failed: " .. tostring(err)); end
end

-- Vanilla screen closed underneath us — make sure our overlay is gone too.
local function OnSceneClosed()
    if _open then DiplomacyAccess.close(); end
end

local function Initialize()
    if ContextPtr == nil then
        Log.warn("DiplomacyAccess.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.DiploScene_SceneOpened.Add(OnSceneOpened);
        LuaEvents.DiploScene_SceneClosed.Add(OnSceneClosed);
        Log.info("DiplomacyAccess: subscribed to DiploScene_SceneOpened / _SceneClosed");
    end
end
Initialize();

Log.info("DiplomacyAccess.lua: loaded");
