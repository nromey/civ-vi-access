-- TechPickerAccess: screen-reader-driven technology picker.
--
-- Mirrors the shape of ProductionPickerAddin but simpler — a tech
-- pick has one tab (no Produce/Gold/Faith split), no tile placement,
-- and one commit API. Three groups by status:
--   Available — CanResearch returns true; player could start now.
--   Locked    — at least one prereq tech missing.
--   Researched — HasTech returns true.
--
-- Per-item label per docs/PICKER_DESIGN.md Section N:
--   {name} — {turns to research at current science yield} — {boost status}
--   {name} — researching now, {turns remaining}                (current research)
--   {name} — requires {prereq name(s)}                          (locked)
--   {name} — researched                                         (done)
--
-- Hotkey: Alt+T (CIVVIACCESS_OpenTechPicker). Notification-center
-- activation on NOTIFICATION_CHOOSE_TECH also opens the picker.
-- See NotificationPanel.lua for the dispatch.
--
-- Per [[project-sighted-mode-per-turn]] hotseat / MP-with-sighted-
-- partner support: when the local player is designated sighted, the
-- picker MUST NOT auto-open. Stage 1 ships single-player only; the
-- gate is a TODO until per-turn sighted/blind mode lands.

include("Log");
include("ScreenReader");
include("HandlerStack");

TechPicker = TechPicker or {};

-- ====================================================================
-- Constants
-- ====================================================================

local GROUP_AVAILABLE  = 1;
local GROUP_LOCKED     = 2;
local GROUP_RESEARCHED = 3;
local GROUP_NAMES = { "Available", "Locked", "Researched" };

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
--
-- items is a flat list with header rows between groups (same shape
-- ProductionPickerAddin uses for its group strip). itemIndex points
-- into this flat list. cursor starts at the first navigable choice
-- in the Available group.

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

-- Strip Civ VI text markup mirroring the picker's helper. [NEWLINE]
-- and [COLOR:*] don't reach Tolk cleanly; [ICON_*] gets stripped at
-- the speech gateway already but doing it here lets composeLongForm's
-- output be predictable for joins.
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

-- Find the index of the first navigable item at or after `from`. If
-- none after `from`, returns nil. Direction +1 goes forward; -1 back.
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
-- Tech entry construction
-- ====================================================================
--
-- Three-pass: walk GameInfo.Technologies, classify each into one of
-- Available / Locked / Researched, then emit a flat items list with
-- a header row between each non-empty group. Empty groups still get
-- a header announcing "Available, none" so the nav structure is
-- predictable regardless of game state.

local function safeLookup(key)
    if key == nil or key == "" then return ""; end
    local ok, v = pcall(Locale.Lookup, key);
    if not ok or v == nil then return ""; end
    return tostring(v);
end

-- Cost in science to complete a tech minus current progress. Returns
-- nil if cost can't be resolved.
local function remainingCost(pTechs, row)
    if pTechs == nil or row == nil or row.Cost == nil then return nil; end
    local progress = 0;
    local ok, p = pcall(function()
        return pTechs:GetResearchProgress(row.Index);
    end);
    if ok and p ~= nil then progress = p; end
    local remaining = row.Cost - progress;
    if remaining < 0 then remaining = 0; end
    return remaining;
end

-- Turns to research a specific tech. Uses the engine's canonical
-- pPlayerTechs:GetTurnsToResearch(index) — same call ResearchChooser
-- uses to populate its TurnsLeft label (Base/Assets/UI/TechAndCivic
-- Support.lua:574). Returns nil when the engine signals "no turns
-- available" (sentinel -1, typically pre-first-city / zero science).
local function turnsToResearch(pPlayer, pTechs, row)
    if pTechs == nil or row == nil then return nil; end
    if pTechs.GetTurnsToResearch == nil then return nil; end
    local ok, turns = pcall(function() return pTechs:GetTurnsToResearch(row.Index); end);
    if not ok or turns == nil or turns < 0 then return nil; end
    if turns == 0 then return 1; end
    return turns;
end

-- Prereq tech names for the locked-tech label. Joins multi-prereq
-- with " and ". Limit to first 2 for readability; rest collapse to
-- "and N others".
local function prereqsForTech(row)
    if GameInfo.TechnologyPrereqs == nil then return ""; end
    local names = {};
    for prereq in GameInfo.TechnologyPrereqs() do
        if prereq.Technology == row.TechnologyType then
            local prereqRow = GameInfo.Technologies[prereq.PrereqTech];
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

-- Boost text suffix. Civ VI Eureka boosts grant ~50% progress on a
-- tech when a specific in-game action is performed. Reading the
-- current boost state lets us tell the user "Pottery — boosted"
-- so they can prioritize cheap-boost picks.
local function boostSuffix(pTechs, row)
    if pTechs == nil or row == nil then return ""; end
    local triggered = false;
    local ok, t = pcall(function()
        return pTechs:HasBoostBeenTriggered(row.Index);
    end);
    if ok and t == true then triggered = true; end
    if triggered then return " — boosted"; end
    return "";
end

-- Compose the label for a navigable tech entry. Status-shape varies:
--   researched:   "Astrology — researched"
--   currently researching: "Mining — researching now, 4 turns remaining"
--   available:    "Pottery — 5 turns — boosted"  (boost optional)
--   locked:       "Astronomy — requires Mathematics"
local function composeLabel(pPlayer, pTechs, row, status, isCurrent)
    local name = safeLookup(row.Name);
    if name == "" then name = row.TechnologyType or "(unknown tech)"; end
    if status == GROUP_RESEARCHED then
        return name .. " — researched";
    end
    if status == GROUP_LOCKED then
        local prereq = prereqsForTech(row);
        if prereq ~= "" then
            return name .. " — requires " .. prereq;
        end
        return name .. " — locked";
    end
    -- Available
    local turns = turnsToResearch(pPlayer, pTechs, row);
    local base;
    if isCurrent then
        if turns ~= nil then
            base = name .. " — researching now, " .. tostring(turns)
                   .. " turns remaining";
        else
            base = name .. " — researching now";
        end
    else
        if turns ~= nil then
            base = name .. " — " .. tostring(turns) .. " turns";
        else
            -- Engine returns -1 / nil for turns when research isn't
            -- progressing — typically pre-first-city or zero science
            -- yield. Tell the user why rather than silently omitting.
            base = name .. " — turns unavailable";
        end
    end
    return base .. boostSuffix(pTechs, row);
end

-- Ctrl+T long-form: full description + prereqs + boost description
-- (what action completes the boost). Engine ResearchChooser builds
-- this surface piecewise; we replicate the readable subset.
local function composeLongForm(pPlayer, pTechs, row, status)
    local parts = {};
    if row.Description ~= nil and row.Description ~= "" then
        local desc = safeLookup(row.Description);
        if desc ~= "" then
            parts[#parts + 1] = stripPickerFormatting(desc);
        end
    end
    if status == GROUP_LOCKED then
        local prereq = prereqsForTech(row);
        if prereq ~= "" then
            parts[#parts + 1] = "Requires " .. prereq;
        end
    end
    if status == GROUP_AVAILABLE then
        local turns = turnsToResearch(pPlayer, pTechs, row);
        if turns ~= nil then
            parts[#parts + 1] = tostring(turns) .. " turns at current science";
        end
        if row.Cost ~= nil then
            parts[#parts + 1] = tostring(row.Cost) .. " science total";
        end
    end
    -- Boost description tells the user how to TRIGGER the boost (e.g.
    -- "Build a Mine" for Bronze Working). GameInfo.Boosts row joined
    -- by Technology=row.TechnologyType.
    if GameInfo.Boosts ~= nil then
        for boost in GameInfo.Boosts() do
            if boost.TechnologyType == row.TechnologyType then
                if boost.TriggerDescription ~= nil and boost.TriggerDescription ~= "" then
                    local trig = safeLookup(boost.TriggerDescription);
                    if trig ~= "" then
                        local triggered = false;
                        local ok, t = pcall(function()
                            return pTechs:HasBoostBeenTriggered(row.Index);
                        end);
                        if ok and t == true then triggered = true; end
                        if triggered then
                            parts[#parts + 1] = "Boosted: " .. stripPickerFormatting(trig);
                        else
                            parts[#parts + 1] = "Boost: " .. stripPickerFormatting(trig);
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
    local pTechs = pPlayer:GetTechs();
    if pTechs == nil then
        items[#items + 1] = { kind = ITEM_TEXT, label = "No tech state" };
        return items;
    end
    local currentTechIdx = -1;
    local okCur, cur = pcall(function() return pTechs:GetResearchingTech(); end);
    if okCur and cur ~= nil then currentTechIdx = cur; end

    -- Three buckets, sort by name within each so the user can find
    -- a specific tech without remembering iteration order.
    local available  = {};
    local locked     = {};
    local researched = {};

    for row in GameInfo.Technologies() do
        local has = false;
        local can = false;
        local okH, h = pcall(function() return pTechs:HasTech(row.Index); end);
        if okH and h == true then has = true; end
        if not has then
            local okC, c = pcall(function() return pTechs:CanResearch(row.Index); end);
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

    -- Group: Available
    items[#items + 1] = {
        kind  = ITEM_HEADER,
        label = "Available, " .. tostring(#available) .. " items",
    };
    for _, row in ipairs(available) do
        local isCur = (row.Index == currentTechIdx);
        items[#items + 1] = {
            kind     = ITEM_CHOICE,
            row      = row,
            status   = GROUP_AVAILABLE,
            isCurrent= isCur,
            label    = composeLabel(pPlayer, pTechs, row, GROUP_AVAILABLE, isCur),
        };
    end

    -- Group: Locked
    items[#items + 1] = {
        kind  = ITEM_HEADER,
        label = "Locked, " .. tostring(#locked) .. " items",
    };
    for _, row in ipairs(locked) do
        items[#items + 1] = {
            kind   = ITEM_CHOICE,
            row    = row,
            status = GROUP_LOCKED,
            label  = composeLabel(pPlayer, pTechs, row, GROUP_LOCKED, false),
        };
    end

    -- Group: Researched
    items[#items + 1] = {
        kind  = ITEM_HEADER,
        label = "Researched, " .. tostring(#researched) .. " items",
    };
    for _, row in ipairs(researched) do
        items[#items + 1] = {
            kind   = ITEM_CHOICE,
            row    = row,
            status = GROUP_RESEARCHED,
            label  = composeLabel(pPlayer, pTechs, row, GROUP_RESEARCHED, false),
        };
    end

    return items;
end

-- ====================================================================
-- Commit
-- ====================================================================

local function commitResearch(row)
    if row == nil then return; end
    local pid = localPlayerID();
    if pid < 0 then return; end
    local name = safeLookup(row.Name);
    if name == "" then name = row.TechnologyType or "(unknown tech)"; end
    local tParameters = {};
    tParameters[PlayerOperations.PARAM_TECH_TYPE]   = row.Hash;
    tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
    local ok, err = pcall(function()
        UI.RequestPlayerOperation(pid, PlayerOperations.RESEARCH, tParameters);
    end);
    if not ok then
        Log.error("TechPicker.commit: RequestPlayerOperation failed: " .. tostring(err));
        Speech.emit("Could not start " .. name, "meta");
        return;
    end
    Speech.emit("Researching " .. name, "event");
    -- Don't suppress the close announce — Noel 2026-05-27: "Probably
    -- be a good idea after selecting production to say, when it's
    -- dismissed 'dismissing production picker'." Both event-tier
    -- emits queue cleanly: "Researching Pottery" then closure.
    TechPicker.close();
end

-- ====================================================================
-- Speech
-- ====================================================================

local function announceItemAtCursor(detailKind)
    local item = currentItem();
    if item == nil then
        Speech.emit("No tech selected", "picker");
        return;
    end
    Speech.emit(item.label, detailKind or "picker");
end

local function announcePreamble()
    local parts = { "Technology picker" };
    local pPlayer = localPlayer();
    if pPlayer ~= nil then
        local pTechs = pPlayer:GetTechs();
        if pTechs ~= nil then
            local okCur, curIdx = pcall(function() return pTechs:GetResearchingTech(); end);
            if okCur and curIdx ~= nil and curIdx >= 0 then
                local row = GameInfo.Technologies[curIdx];
                if row ~= nil then
                    local turns = turnsToResearch(pPlayer, pTechs, row);
                    local name = safeLookup(row.Name);
                    if turns ~= nil then
                        parts[#parts + 1] = "Currently researching " .. name
                                            .. ", " .. tostring(turns) .. " turns remaining";
                    else
                        parts[#parts + 1] = "Currently researching " .. name;
                    end
                end
            else
                parts[#parts + 1] = "Nothing currently researching";
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
        TechPicker.close();
        return true;
    end
    if key == VK_UP then
        local from = _state.itemIndex - 1;
        local target = firstNavigable(from, -1);
        if target == nil then
            -- Wrap: last navigable
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
    -- Group nav via Shift+PgUp / Shift+PgDn — jump to first nav item
    -- of the next or previous group. Forward case: walk forward until
    -- we cross a header, then land on its first nav item. Backward
    -- case: walk back to the header for the CURRENT group, then back
    -- once more to the header for the PREVIOUS group, then forward
    -- from there to its first nav item. Without the two-step back,
    -- the cursor lands on the current group's own header and re-
    -- bounces to where it already was (the unreliable behavior Noel
    -- reported 2026-05-27).
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
            -- Past the last group already.
            Speech.emit("Last group", "meta");
        else
            -- Find the header bounding the CURRENT group first.
            local currentHeader = nil;
            local idx = _state.itemIndex - 1;
            while idx >= 1 do
                if _state.items[idx].kind == ITEM_HEADER then
                    currentHeader = idx;
                    break;
                end
                idx = idx - 1;
            end
            -- Then find the header BEFORE that — the previous group.
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
            Speech.emit("Already researching " .. safeLookup(item.row.Name), "picker");
            return true;
        end
        commitResearch(item.row);
        return true;
    end
    if key == VK_T and mods == MOD_CTRL then
        local item = currentItem();
        if item == nil or item.kind ~= ITEM_CHOICE then
            announceItemAtCursor("picker");
            return true;
        end
        local pPlayer = localPlayer();
        local pTechs = pPlayer ~= nil and pPlayer:GetTechs() or nil;
        local long = composeLongForm(pPlayer, pTechs, item.row, item.status);
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
        name = "TechPicker",
        helpEntries = {
            { keyLabel = "Up / Down",   description = "Move between techs" },
            { keyLabel = "Home / End",  description = "First / last tech" },
            { keyLabel = "Shift+PgUp / PgDn", description = "Jump to previous / next group" },
            { keyLabel = "Enter",       description = "Start research" },
            { keyLabel = "Ctrl+T",      description = "Long-form: description, prereqs, boost" },
            { keyLabel = "Esc",         description = "Close picker" },
        },
        bindings = {},
    };
    return _handler;
end

-- ====================================================================
-- Open / close
-- ====================================================================

function TechPicker.open()
    Log.info("TechPicker.open: entry");
    if _state.open then
        Log.info("TechPicker.open: already open; rebuilding");
    end

    local ok, err = pcall(function()
        _state.items = buildItems();
        local first = firstNavigable(1, 1);
        _state.itemIndex = first or 1;
        _state.open      = true;
    end);
    if not ok then
        Log.error("TechPicker.open: buildItems failed: " .. tostring(err));
        return;
    end
    Log.info("TechPicker.open: items built, count="
             .. tostring(#_state.items) .. " cursor=" .. tostring(_state.itemIndex));

    ok, err = pcall(function() HandlerStack.push(ensureHandler()); end);
    if not ok then
        Log.error("TechPicker.open: HandlerStack.push failed: " .. tostring(err));
        return;
    end

    -- Suppress engine TechTree slide-out while ours is up. Mirrors
    -- ProductionPicker's ProductionPanel suppression.
    ok, err = pcall(function()
        if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
            local tree = ContextPtr:LookUpControl("/InGame/TechTree");
            if tree ~= nil and tree.SetHide ~= nil then tree:SetHide(true); end
        end
    end);
    if not ok then
        Log.warn("TechPicker.open: engine TechTree suppress failed (non-fatal): " .. tostring(err));
    end

    ok, err = pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
        end
    end);
    if not ok then
        Log.error("TechPicker.open: QueuePopup failed: " .. tostring(err));
    end

    ok, err = pcall(function()
        announcePreamble();
        local item = currentItem();
        if item ~= nil then
            Speech.emit(item.label, "status");
        end
    end);
    if not ok then
        Log.error("TechPicker.open: preamble/announce failed: " .. tostring(err));
    end
    Log.info("TechPicker.open: complete");
end

function TechPicker.close()
    if not _state.open then return; end
    local closingSilently = _state.closingSilently == true;
    _state.closingSilently = false;
    _state.open = false;

    HandlerStack.removeByName("TechPicker");

    pcall(function()
        if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
            UIManager:DequeuePopup(ContextPtr);
        end
    end);

    -- InterfaceMode reset: engine's RESEARCH operation can leave the
    -- interface in a non-SELECTION state that captures Enter (Noel
    -- 2026-05-27: "after doing tech, I haven't been able to end with
    -- enter"). Force back to SELECTION so End Turn key reaches the
    -- engine action. Mirror of ProductionPicker's Hotel-California fix.
    pcall(function()
        if UI ~= nil and UI.SetInterfaceMode ~= nil
           and InterfaceModeTypes ~= nil and InterfaceModeTypes.SELECTION ~= nil then
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        end
    end);

    -- Hide our context explicitly so it's out of the z-order and not
    -- holding any latent focus.
    pcall(function()
        if ContextPtr ~= nil and ContextPtr.SetHide ~= nil then
            ContextPtr:SetHide(true);
        end
    end);

    -- Unhide engine TechTree (sighted UI). If a sighted partner is
    -- on turn next, the engine UI takes over normally.
    pcall(function()
        if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
            local tree = ContextPtr:LookUpControl("/InGame/TechTree");
            if tree ~= nil and tree.SetHide ~= nil then tree:SetHide(false); end
        end
    end);

    if not closingSilently then
        Speech.emit("Technology picker closed", "event");
    end
    Log.info("TechPicker.close: closed (silent=" .. tostring(closingSilently) .. ")");
end

-- Cross-VM open trigger from HexCursorAddin / NotificationPanel.
-- Same dispatch shape ProductionPickerAddin uses.
local function OnLuaEventOpenPicker()
    Log.info("TechPickerAddin: OnLuaEventOpenPicker called");
    TechPicker.open();
end

-- ====================================================================
-- Init
-- ====================================================================

local function Initialize()
    if ContextPtr == nil then
        Log.warn("TechPicker.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_OpenTechPicker.Add(OnLuaEventOpenPicker);
        Log.info("TechPickerAddin: subscribed to CivViAccess_OpenTechPicker");
    end
    Log.info("TechPickerAddin.Initialize: input handler installed");
end

Initialize();
