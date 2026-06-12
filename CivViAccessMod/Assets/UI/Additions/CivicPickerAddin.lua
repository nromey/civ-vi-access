-- CivicPickerAccess: screen-reader-driven civic picker.
--
-- Mirror of TechPickerAddin. Civ VI's culture system parallels its
-- science system: civics gate cultural / governance unlocks the way
-- techs gate units / buildings. Three groups by status:
--   Available  — CanProgress returns true; player could start now.
--   Locked     — at least one prereq civic missing.
--   Researched — HasCivic returns true (kept the same group name as
--                tech picker so muscle memory carries over).
--
-- Per-item label per docs/PICKER_DESIGN.md Section O:
--   {name} — {turns to progress} — {boost status}
--   {name} — studying now, {turns remaining}                   (current)
--   {name} — requires {prereq name(s)}                          (locked)
--   {name} — completed                                          (done)
--
-- Hotkey: Alt+C (CIVVIACCESS_OpenCivicPicker). Notification-center
-- activation on NOTIFICATION_CHOOSE_CIVIC also opens the picker.
-- See NotificationPanel.lua for the dispatch.
--
-- Engine API surface (mirrors what CivicsChooser.lua uses):
--   pPlayer:GetCulture()                              culture state
--   pCulture:HasCivic(idx)                            completed?
--   pCulture:CanProgress(idx)                         can start now?
--   pCulture:GetProgressingCivic()                    current target
--   pCulture:GetTurnsToProgressCivic(idx)             turns at yield
--   pCulture:HasBoostBeenTriggered(idx)               inspiration met?
--   UI.RequestPlayerOperation(pid,
--       PlayerOperations.PROGRESS_CIVIC,
--       {PARAM_CIVIC_TYPE=hash, PARAM_INSERT_MODE=VALUE_EXCLUSIVE})
-- "Envoy on completion" suffix from PICKER_DESIGN.md Section O is
-- deferred — engine data path is Modifier-driven, not a simple column.
-- Add later if user asks.

include("Log");
include("ScreenReader");
include("HandlerStack");

CivicPicker = CivicPicker or {};

-- ====================================================================
-- Constants
-- ====================================================================

local GROUP_AVAILABLE  = 1;
local GROUP_LOCKED     = 2;
local GROUP_RESEARCHED = 3;
local GROUP_NAMES = { "Available", "Locked", "Completed" };

local ITEM_HEADER = "header";
local ITEM_CHOICE = "choice";
local ITEM_TEXT   = "text";

local VK_TAB     = (Keys ~= nil and Keys.VK_TAB)    or 0x09;
local VK_RETURN  = (Keys ~= nil and Keys.VK_RETURN) or 0x0D;
local VK_SPACE   = (Keys ~= nil and Keys.VK_SPACE)  or 0x20;
local VK_ESCAPE  = (Keys ~= nil and Keys.VK_ESCAPE) or 0x1B;
local VK_PRIOR   = (Keys ~= nil and Keys.VK_PRIOR)  or 0x21;
local VK_NEXT    = (Keys ~= nil and Keys.VK_NEXT)   or 0x22;
local VK_END     = (Keys ~= nil and Keys.VK_END)    or 0x23;
local VK_HOME    = (Keys ~= nil and Keys.VK_HOME)   or 0x24;
local VK_UP      = (Keys ~= nil and Keys.VK_UP)     or 0x26;
local VK_DOWN    = (Keys ~= nil and Keys.VK_DOWN)   or 0x28;
local VK_T       = (Keys ~= nil and Keys.T)         or 0x54;

local MOD_NONE  = 0;
local MOD_SHIFT = 1;
local MOD_CTRL  = 2;

-- ====================================================================
-- State
-- ====================================================================

local _state = {
    open      = false,
    items     = nil,
    itemIndex = 1,
};

local _handler = nil;

-- ====================================================================
-- Helpers
-- ====================================================================

local function localPlayerID()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    if not ok or id == nil then return -1; end
    return id;
end

local function localPlayer()
    local pid = localPlayerID();
    if pid < 0 then return nil; end
    return Players[pid];
end

local function stripPickerFormatting(text)
    if text == nil then return ""; end
    text = tostring(text);
    text = text:gsub("%[NEWLINE%]", ". ");
    text = text:gsub("%[COLOR:[^%]]+%]", "");
    text = text:gsub("%[COLOR_[^%]]+%]", "");
    text = text:gsub("%[ENDCOLOR%]", "");
    text = text:gsub("%s+", " ");
    text = text:gsub("%.%s*%.", ".");
    return text;
end

local function currentItem()
    if _state.items == nil or #_state.items == 0 then return nil; end
    local idx = _state.itemIndex;
    if idx < 1 then idx = 1; end
    if idx > #_state.items then idx = #_state.items; end
    return _state.items[idx];
end

local function isNavigable(item)
    return item ~= nil and item.kind == ITEM_CHOICE;
end

local function firstNavigable(from, direction)
    if _state.items == nil then return nil; end
    local idx = from;
    while idx >= 1 and idx <= #_state.items do
        if isNavigable(_state.items[idx]) then
            return idx;
        end
        idx = idx + direction;
    end
    return nil;
end

-- ====================================================================
-- Civic entry construction
-- ====================================================================

local function safeLookup(key)
    if key == nil or key == "" then return ""; end
    local ok, v = pcall(Locale.Lookup, key);
    if not ok or v == nil then return ""; end
    return tostring(v);
end

-- Engine sentinel: GetTurnsToProgressCivic returns -1 when no culture
-- yield. Mirror's TechPicker's turnsToResearch shape.
local function turnsToProgress(pPlayer, pCulture, row)
    if pCulture == nil or row == nil then return nil; end
    if pCulture.GetTurnsToProgressCivic == nil then return nil; end
    local ok, turns = pcall(function()
        return pCulture:GetTurnsToProgressCivic(row.Index);
    end);
    if not ok or turns == nil or turns < 0 then return nil; end
    if turns == 0 then return 1; end
    return turns;
end

local function prereqsForCivic(row)
    if GameInfo.CivicPrereqs == nil then return ""; end
    local names = {};
    for prereq in GameInfo.CivicPrereqs() do
        if prereq.Civic == row.CivicType then
            local prereqRow = GameInfo.Civics[prereq.PrereqCivic];
            if prereqRow ~= nil and prereqRow.Name ~= nil then
                names[#names + 1] = safeLookup(prereqRow.Name);
            end
        end
    end
    if #names == 0 then return ""; end
    if #names == 1 then return names[1]; end
    if #names == 2 then return names[1] .. " and " .. names[2]; end
    return names[1] .. ", " .. names[2] .. " and "
           .. tostring(#names - 2) .. " others";
end

-- Civic inspirations (the civic-side equivalent of tech eurekas).
-- Same HasBoostBeenTriggered shape as tech.
local function boostSuffix(pCulture, row)
    if pCulture == nil or row == nil then return ""; end
    local triggered = false;
    local ok, t = pcall(function()
        return pCulture:HasBoostBeenTriggered(row.Index);
    end);
    if ok and t == true then triggered = true; end
    if triggered then return " — inspired"; end
    return "";
end

local function composeLabel(pPlayer, pCulture, row, status, isCurrent)
    local name = safeLookup(row.Name);
    if name == "" then name = row.CivicType or "(unknown civic)"; end
    if status == GROUP_RESEARCHED then
        return name .. " — completed";
    end
    if status == GROUP_LOCKED then
        local prereq = prereqsForCivic(row);
        if prereq ~= "" then
            return name .. " — requires " .. prereq;
        end
        return name .. " — locked";
    end
    -- Available
    local turns = turnsToProgress(pPlayer, pCulture, row);
    local base;
    if isCurrent then
        if turns ~= nil then
            base = name .. " — studying now, " .. tostring(turns)
                   .. " turns remaining";
        else
            base = name .. " — studying now";
        end
    else
        if turns ~= nil then
            base = name .. " — " .. tostring(turns) .. " turns";
        else
            base = name .. " — turns unavailable";
        end
    end
    return base .. boostSuffix(pCulture, row);
end

-- Ctrl+T long-form: description + prereqs + inspiration trigger text.
-- GameInfo.Boosts is the same table for techs and civics; rows are
-- distinguished by which of TechnologyType / CivicType is non-null.
-- What the civic actually GETS you (Noel 2026-06-12, same gap as techs):
-- civics mostly pay out in policy cards, governments, buildings, districts —
-- the icons on the sighted tree. Enumerate everything gated on this civic.
local function unlocksList(civicType)
    local names = {};
    pcall(function()
        for _, tblName in ipairs({ "Policies", "Governments", "Units",
                                   "Buildings", "Districts", "Improvements" }) do
            local t = GameInfo[tblName];
            if t ~= nil then
                for r in t() do
                    if r.PrereqCivic == civicType then
                        local n = (r.Name ~= nil) and Locale.Lookup(r.Name) or nil;
                        if n ~= nil and n ~= "" then names[#names + 1] = n; end
                    end
                end
            end
        end
    end);
    return names;
end

local function composeLongForm(pPlayer, pCulture, row, status)
    local parts = {};
    -- Unlocks FIRST — the "what does this actually do" answer.
    local unlocks = unlocksList(row.CivicType);
    if #unlocks > 0 then
        parts[#parts + 1] = "Unlocks " .. table.concat(unlocks, ", ");
    end
    if row.Description ~= nil and row.Description ~= "" then
        local desc = safeLookup(row.Description);
        if desc ~= "" then
            parts[#parts + 1] = stripPickerFormatting(desc);
        end
    end
    if status == GROUP_LOCKED then
        local prereq = prereqsForCivic(row);
        if prereq ~= "" then
            parts[#parts + 1] = "Requires " .. prereq;
        end
    end
    if status == GROUP_AVAILABLE then
        local turns = turnsToProgress(pPlayer, pCulture, row);
        if turns ~= nil then
            parts[#parts + 1] = tostring(turns) .. " turns at current culture";
        end
        if row.Cost ~= nil then
            parts[#parts + 1] = tostring(row.Cost) .. " culture total";
        end
    end
    -- Inspiration description (civic equivalent of a Eureka boost).
    if GameInfo.Boosts ~= nil then
        for boost in GameInfo.Boosts() do
            if boost.CivicType == row.CivicType then
                if boost.TriggerDescription ~= nil and boost.TriggerDescription ~= "" then
                    local trig = safeLookup(boost.TriggerDescription);
                    if trig ~= "" then
                        local triggered = false;
                        local ok, t = pcall(function()
                            return pCulture:HasBoostBeenTriggered(row.Index);
                        end);
                        if ok and t == true then triggered = true; end
                        -- Phrase the CONDITION as a condition (Noel 2026-06-12
                        -- heard Craftsmanship's "Improve 3 tiles" as an effect
                        -- of studying it). boost.Boost = the percent granted.
                        local pct = (boost.Boost ~= nil) and (tostring(boost.Boost) .. " percent") or nil;
                        if triggered then
                            parts[#parts + 1] = "Inspiration earned"
                                .. (pct ~= nil and (", " .. pct .. " saved") or "")
                                .. " (" .. stripPickerFormatting(trig) .. ")";
                        else
                            parts[#parts + 1] = "Inspiration boost"
                                .. (pct ~= nil and (", saves " .. pct) or "")
                                .. " — to earn it: " .. stripPickerFormatting(trig);
                        end
                        break;
                    end
                end
            end
        end
    end
    if #parts == 0 then return nil; end
    return table.concat(parts, ". ");
end

local function buildItems()
    local items = {};
    local pPlayer = localPlayer();
    if pPlayer == nil then
        items[#items + 1] = { kind = ITEM_TEXT, label = "No active player" };
        return items;
    end
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil then
        items[#items + 1] = { kind = ITEM_TEXT, label = "No culture state" };
        return items;
    end
    local currentCivicIdx = -1;
    local okCur, cur = pcall(function() return pCulture:GetProgressingCivic(); end);
    if okCur and cur ~= nil then currentCivicIdx = cur; end

    local available  = {};
    local locked     = {};
    local researched = {};

    for row in GameInfo.Civics() do
        local has = false;
        local can = false;
        local okH, h = pcall(function() return pCulture:HasCivic(row.Index); end);
        if okH and h == true then has = true; end
        if not has then
            local okC, c = pcall(function() return pCulture:CanProgress(row.Index); end);
            if okC and c == true then can = true; end
        end
        local target = has and researched or (can and available or locked);
        target[#target + 1] = row;
    end

    local function sortByName(a, b)
        return safeLookup(a.Name) < safeLookup(b.Name);
    end
    table.sort(available,  sortByName);
    table.sort(locked,     sortByName);
    table.sort(researched, sortByName);

    items[#items + 1] = {
        kind  = ITEM_HEADER,
        label = "Available, " .. tostring(#available) .. " items",
    };
    for _, row in ipairs(available) do
        local isCur = (row.Index == currentCivicIdx);
        items[#items + 1] = {
            kind     = ITEM_CHOICE,
            row      = row,
            status   = GROUP_AVAILABLE,
            isCurrent= isCur,
            label    = composeLabel(pPlayer, pCulture, row, GROUP_AVAILABLE, isCur),
        };
    end

    items[#items + 1] = {
        kind  = ITEM_HEADER,
        label = "Locked, " .. tostring(#locked) .. " items",
    };
    for _, row in ipairs(locked) do
        items[#items + 1] = {
            kind   = ITEM_CHOICE,
            row    = row,
            status = GROUP_LOCKED,
            label  = composeLabel(pPlayer, pCulture, row, GROUP_LOCKED, false),
        };
    end

    items[#items + 1] = {
        kind  = ITEM_HEADER,
        label = "Completed, " .. tostring(#researched) .. " items",
    };
    for _, row in ipairs(researched) do
        items[#items + 1] = {
            kind   = ITEM_CHOICE,
            row    = row,
            status = GROUP_RESEARCHED,
            label  = composeLabel(pPlayer, pCulture, row, GROUP_RESEARCHED, false),
        };
    end

    return items;
end

-- ====================================================================
-- Commit
-- ====================================================================

local function commitProgress(row)
    if row == nil then return; end
    local pid = localPlayerID();
    if pid < 0 then return; end
    local name = safeLookup(row.Name);
    if name == "" then name = row.CivicType or "(unknown civic)"; end
    local tParameters = {};
    tParameters[PlayerOperations.PARAM_CIVIC_TYPE]  = row.Hash;
    tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
    local ok, err = pcall(function()
        UI.RequestPlayerOperation(pid, PlayerOperations.PROGRESS_CIVIC, tParameters);
    end);
    if not ok then
        Log.error("CivicPicker.commit: RequestPlayerOperation failed: " .. tostring(err));
        Speech.emit("Could not start " .. name, "meta");
        return;
    end
    Speech.emit("Studying " .. name, "event");
    -- Don't suppress the close announce — same pattern as tech picker.
    CivicPicker.close();
end

-- ====================================================================
-- Speech
-- ====================================================================

local function announceItemAtCursor(detailKind)
    local item = currentItem();
    if item == nil then
        Speech.emit("No civic selected", "picker");
        return;
    end
    Speech.emit(item.label, detailKind or "picker");
end

local function announcePreamble()
    local parts = { "Civic picker" };
    local pPlayer = localPlayer();
    if pPlayer ~= nil then
        local pCulture = pPlayer:GetCulture();
        if pCulture ~= nil then
            local okCur, curIdx = pcall(function() return pCulture:GetProgressingCivic(); end);
            if okCur and curIdx ~= nil and curIdx >= 0 then
                local row = GameInfo.Civics[curIdx];
                if row ~= nil then
                    local turns = turnsToProgress(pPlayer, pCulture, row);
                    local name = safeLookup(row.Name);
                    if turns ~= nil then
                        parts[#parts + 1] = "Currently studying " .. name
                                            .. ", " .. tostring(turns) .. " turns remaining";
                    else
                        parts[#parts + 1] = "Currently studying " .. name;
                    end
                end
            else
                parts[#parts + 1] = "Nothing currently studying";
            end
        end
    end
    Speech.emit(table.concat(parts, ". ") .. ".", "picker");
end

-- ====================================================================
-- Input
-- ====================================================================

local function modifierMask(pInputStruct)
    local m = MOD_NONE;
    local okS, isShift = pcall(function() return pInputStruct:IsShiftDown(); end);
    if okS and isShift then m = m + MOD_SHIFT; end
    local okC, isCtrl = pcall(function() return pInputStruct:IsControlDown(); end);
    if okC and isCtrl then m = m + MOD_CTRL; end
    return m;
end

local function handleKeyDown(key, mods)
    if key == VK_ESCAPE then
        CivicPicker.close();
        return true;
    end
    if key == VK_UP then
        local from = _state.itemIndex - 1;
        local target = firstNavigable(from, -1);
        if target == nil then
            target = firstNavigable(#_state.items, -1);
        end
        if target ~= nil then
            _state.itemIndex = target;
            announceItemAtCursor("picker");
        end
        return true;
    end
    if key == VK_DOWN then
        local from = _state.itemIndex + 1;
        local target = firstNavigable(from, 1);
        if target == nil then
            target = firstNavigable(1, 1);
        end
        if target ~= nil then
            _state.itemIndex = target;
            announceItemAtCursor("picker");
        end
        return true;
    end
    if key == VK_HOME then
        local target = firstNavigable(1, 1);
        if target ~= nil then
            _state.itemIndex = target;
            announceItemAtCursor("picker");
        end
        return true;
    end
    if key == VK_END then
        local target = firstNavigable(#_state.items, -1);
        if target ~= nil then
            _state.itemIndex = target;
            announceItemAtCursor("picker");
        end
        return true;
    end
    if (key == VK_PRIOR or key == VK_NEXT) and (mods == MOD_SHIFT or mods == MOD_NONE) then
        local direction = (key == VK_NEXT) and 1 or -1;
        if direction == 1 then
            local idx = _state.itemIndex + 1;
            while idx <= #_state.items do
                if _state.items[idx].kind == ITEM_HEADER then
                    local choice = firstNavigable(idx + 1, 1);
                    if choice ~= nil then
                        _state.itemIndex = choice;
                        Speech.emit(_state.items[idx].label, "picker");
                        Speech.emit(_state.items[choice].label, "status");
                        return true;
                    end
                end
                idx = idx + 1;
            end
            Speech.emit("Last group", "meta");
        else
            local currentHeader = nil;
            local idx = _state.itemIndex - 1;
            while idx >= 1 do
                if _state.items[idx].kind == ITEM_HEADER then
                    currentHeader = idx;
                    break;
                end
                idx = idx - 1;
            end
            local prevHeader = nil;
            if currentHeader ~= nil then
                idx = currentHeader - 1;
                while idx >= 1 do
                    if _state.items[idx].kind == ITEM_HEADER then
                        prevHeader = idx;
                        break;
                    end
                    idx = idx - 1;
                end
            end
            if prevHeader ~= nil then
                local choice = firstNavigable(prevHeader + 1, 1);
                if choice ~= nil then
                    _state.itemIndex = choice;
                    Speech.emit(_state.items[prevHeader].label, "picker");
                    Speech.emit(_state.items[choice].label, "status");
                    return true;
                end
            end
            Speech.emit("First group", "meta");
        end
        return true;
    end
    if key == VK_RETURN or key == VK_SPACE then
        local item = currentItem();
        if item == nil or item.kind ~= ITEM_CHOICE then return true; end
        if item.status == GROUP_RESEARCHED then
            Speech.emit(item.label, "picker");
            return true;
        end
        if item.status == GROUP_LOCKED then
            Speech.emit(item.label, "picker");
            return true;
        end
        if item.isCurrent then
            Speech.emit("Already studying " .. safeLookup(item.row.Name), "picker");
            return true;
        end
        commitProgress(item.row);
        return true;
    end
    if key == VK_T and mods == MOD_CTRL then
        local item = currentItem();
        if item == nil or item.kind ~= ITEM_CHOICE then
            announceItemAtCursor("picker");
            return true;
        end
        local pPlayer = localPlayer();
        local pCulture = pPlayer ~= nil and pPlayer:GetCulture() or nil;
        local long = composeLongForm(pPlayer, pCulture, item.row, item.status);
        if long ~= nil then
            Speech.emit(long, "status");
        else
            announceItemAtCursor("picker");
        end
        return true;
    end
    return false;
end

local function onInput(pInputStruct)
    if not _state.open then return false; end
    if pInputStruct == nil then return false; end
    local uiMsg = pInputStruct:GetMessageType();
    if uiMsg ~= KeyEvents.KeyDown then return false; end
    local key = pInputStruct:GetKey();
    local mods = modifierMask(pInputStruct);
    return handleKeyDown(key, mods);
end

-- ====================================================================
-- Handler
-- ====================================================================

local function ensureHandler()
    if _handler ~= nil then return _handler; end
    _handler = {
        name = "CivicPicker",
        helpEntries = {
            { keyLabel = "Up / Down",   description = "Move between civics" },
            { keyLabel = "Home / End",  description = "First / last civic" },
            { keyLabel = "Shift+PgUp / PgDn", description = "Jump to previous / next group" },
            { keyLabel = "Enter",       description = "Start studying" },
            { keyLabel = "Ctrl+T",      description = "Long-form: description, prereqs, inspiration" },
            { keyLabel = "Esc",         description = "Close picker" },
        },
        bindings = {},
    };
    return _handler;
end

-- ====================================================================
-- Open / close
-- ====================================================================

function CivicPicker.open()
    Log.info("CivicPicker.open: entry");
    if _state.open then
        Log.info("CivicPicker.open: already open; rebuilding");
    end

    local ok, err = pcall(function()
        _state.items = buildItems();
        local first = firstNavigable(1, 1);
        _state.itemIndex = first or 1;
        _state.open      = true;
    end);
    if not ok then
        Log.error("CivicPicker.open: buildItems failed: " .. tostring(err));
        return;
    end
    Log.info("CivicPicker.open: items built, count="
             .. tostring(#_state.items) .. " cursor=" .. tostring(_state.itemIndex));

    ok, err = pcall(function() HandlerStack.push(ensureHandler()); end);
    if not ok then
        Log.error("CivicPicker.open: HandlerStack.push failed: " .. tostring(err));
        return;
    end

    -- Suppress engine CivicsTree slide-out while ours is up.
    ok, err = pcall(function()
        if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
            local tree = ContextPtr:LookUpControl("/InGame/CivicsTree");
            if tree ~= nil and tree.SetHide ~= nil then tree:SetHide(true); end
        end
    end);
    if not ok then
        Log.warn("CivicPicker.open: engine CivicsTree suppress failed (non-fatal): " .. tostring(err));
    end

    ok, err = pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
    end);
    if not ok then
        Log.error("CivicPicker.open: QueuePopup failed: " .. tostring(err));
    end

    ok, err = pcall(function()
        announcePreamble();
        local item = currentItem();
        if item ~= nil then
            Speech.emit(item.label, "status");
        end
    end);
    if not ok then
        Log.error("CivicPicker.open: preamble/announce failed: " .. tostring(err));
    end
    Log.info("CivicPicker.open: complete");
end

function CivicPicker.close()
    if not _state.open then return; end
    local closingSilently = _state.closingSilently == true;
    _state.closingSilently = false;
    _state.open = false;

    HandlerStack.removeByName("CivicPicker");

    pcall(function()
        if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
            UIManager:DequeuePopup(ContextPtr);
        end
    end);

    -- InterfaceMode reset (same as TechPicker close) so Enter reaches
    -- the engine's EndTurn action after committing.
    pcall(function()
        if UI ~= nil and UI.SetInterfaceMode ~= nil
           and InterfaceModeTypes ~= nil and InterfaceModeTypes.SELECTION ~= nil then
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        end
    end);

    pcall(function()
        if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then
            ContextPtr:SetHide(true);
        end
    end);

    pcall(function()
        if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
            local tree = ContextPtr:LookUpControl("/InGame/CivicsTree");
            if tree ~= nil and tree.SetHide ~= nil then tree:SetHide(false); end
        end
    end);

    if not closingSilently then
        Speech.emit("Civic picker closed", "event");
    end
    Log.info("CivicPicker.close: closed (silent=" .. tostring(closingSilently) .. ")");
end

local function OnLuaEventOpenPicker()
    Log.info("CivicPickerAddin: OnLuaEventOpenPicker called");
    CivicPicker.open();
end

-- ====================================================================
-- Init
-- ====================================================================

local function Initialize()
    if ContextPtr == nil then
        Log.warn("CivicPicker.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_OpenCivicPicker.Add(OnLuaEventOpenPicker);
        Log.info("CivicPickerAddin: subscribed to CivViAccess_OpenCivicPicker");
    end
    Log.info("CivicPickerAddin.Initialize: input handler installed");
end

Initialize();
