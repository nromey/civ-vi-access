-- BuildImprovementPicker — screen-reader navigable builder improvement picker.
--
-- Shift+B (HexCursorAddin) fires LuaEvents.CivViAccess_OpenBuildPicker(); we
-- resolve the selected Builder, enumerate the improvements valid for its tile,
-- and present them as a navigable list — RECOMMENDED first (Noel's design
-- 2026-06-02: recommended on top as the fast path, specifics below). Enter
-- builds the focused improvement.
--
-- Input model mirrors ProductionPickerAddin (the proven world-view modal
-- picker): a separate sandboxed Context, opened via UIManager:QueuePopup so the
-- engine makes us the active modal and routes raw KeyDown/Up to our
-- SetInputHandler; we dispatch KeyUp through the shared InputRouter/HandlerStack
-- (so ? help lists our keys and nothing below us fires while open). Closed via
-- DequeuePopup. This modal+input shell is the REUSABLE world-view picker pattern
-- future features (board-query list, routes, map pins) can follow.
--
-- Enumeration mirrors the base UnitPanel build branch: CanStartOperation with
-- PARAM_X/Y returns tResults[IMPROVEMENTS] + BEST_IMPROVEMENT; commit sets
-- PARAM_IMPROVEMENT_TYPE and RequestOperation(BUILD_IMPROVEMENT).

include("Log");
include("ScreenReader");
include("HandlerStack");
include("InputRouter");

BuildImprovementPicker = BuildImprovementPicker or {};

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

local _open  = false;
local _items = {};   -- { {label=, eImp=}, ... }
local _index = 1;

local function lp()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

local function headUnit()
    return (UI ~= nil and UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil;
end

local function buildOpHash()
    local row = GameInfo.UnitOperations
                and GameInfo.UnitOperations["UNITOPERATION_BUILD_IMPROVEMENT"] or nil;
    return (UnitOperationTypes ~= nil and UnitOperationTypes.BUILD_IMPROVEMENT)
        or (row ~= nil and row.Hash) or nil;
end

local function impName(eImp)
    local r = GameInfo.Improvements and GameInfo.Improvements[eImp] or nil;
    return (r ~= nil and r.Name ~= nil) and Locale.Lookup(r.Name) or "an improvement";
end

local function hasTech(techType)
    if techType == nil then return true; end
    local t = GameInfo.Technologies and GameInfo.Technologies[techType] or nil;
    local p = (Players ~= nil) and Players[lp()] or nil;
    if t == nil or p == nil or p.GetTechs == nil then return true; end
    local ok, has = pcall(function() return p:GetTechs():HasTech(t.Index); end);
    return ok and has == true;
end

local function hasCivic(civicType)
    if civicType == nil then return true; end
    local c = GameInfo.Civics and GameInfo.Civics[civicType] or nil;
    local p = (Players ~= nil) and Players[lp()] or nil;
    if c == nil or p == nil or p.GetCulture == nil then return true; end
    local ok, has = pcall(function() return p:GetCulture():HasCivic(c.Index); end);
    return ok and has == true;
end

-- Improvement TYPE strings the given builder unit can ever construct.
-- Trait-gated uniques (Inca Terrace Farm etc.) are excluded unless THIS
-- player's civ/leader carries the trait — without the gate every civ's
-- unique cluttered the locked list (Noel 2026-06-12).
local function builderImprovementTypes(pUnit)
    local set = {};
    if GameInfo.Improvement_ValidBuildUnits == nil then return set; end
    local uRow = GameInfo.Units and GameInfo.Units[pUnit:GetUnitType()] or nil;
    local uType = uRow and uRow.UnitType or nil;
    if uType == nil then return set; end
    local playerTraits = {};
    pcall(function()
        local cfg = PlayerConfigurations[lp()];
        local civType = cfg:GetCivilizationTypeName();
        local leaderType = cfg:GetLeaderTypeName();
        for r in GameInfo.CivilizationTraits() do
            if r.CivilizationType == civType then playerTraits[r.TraitType] = true; end
        end
        for r in GameInfo.LeaderTraits() do
            if r.LeaderType == leaderType then playerTraits[r.TraitType] = true; end
        end
    end);
    for row in GameInfo.Improvement_ValidBuildUnits() do
        if row.UnitType == uType then
            local impRow = GameInfo.Improvements[row.ImprovementType];
            if impRow ~= nil
               and (impRow.TraitType == nil or playerTraits[impRow.TraitType]) then
                set[row.ImprovementType] = true;
            end
        end
    end
    return set;
end

-- Short "where it can go" hint from an improvement's valid terrains / features /
-- resources (first few, de-duped). Used when an improvement is gated by tile
-- type rather than tech/civic.
local function terrainHint(impType)
    local out, seen = {}, {};
    local function add(name)
        if name ~= nil and name ~= "" and not seen[name] and #out < 3 then
            seen[name] = true; out[#out + 1] = name;
        end
    end
    if GameInfo.Improvement_ValidTerrains ~= nil then
        for row in GameInfo.Improvement_ValidTerrains() do
            if row.ImprovementType == impType then
                local r = GameInfo.Terrains[row.TerrainType];
                if r then add(Locale.Lookup(r.Name)); end
            end
        end
    end
    if GameInfo.Improvement_ValidFeatures ~= nil then
        for row in GameInfo.Improvement_ValidFeatures() do
            if row.ImprovementType == impType then
                local r = GameInfo.Features[row.FeatureType];
                if r then add(Locale.Lookup(r.Name)); end
            end
        end
    end
    if GameInfo.Improvement_ValidResources ~= nil then
        for row in GameInfo.Improvement_ValidResources() do
            if row.ImprovementType == impType then
                local r = GameInfo.Resources[row.ResourceType];
                if r then add(Locale.Lookup(r.Name)); end
            end
        end
    end
    if #out == 0 then return nil; end
    return table.concat(out, " or ");
end

-- Why is this improvement not buildable here right now? Tech/civic gate takes
-- priority (it's the "what unlocks it" answer the user wants); otherwise a
-- tile-type hint ("requires Hills") so they know where to move the builder.
local function lockReason(impRow)
    -- Terrain hint is appended to the tech/civic gate, not only used as a
    -- fallback (Noel 2026-06-03: a water improvement like the Offshore Oil Rig
    -- should still say "Coast or Ocean", not just the tech) — so you know both
    -- what to research/adopt AND where the builder has to be.
    local hint = terrainHint(impRow.ImprovementType);
    -- ", and needs" not ";" — spoken, the semicolon ran the two separate gates
    -- (research vs terrain) together into one mushy clause (detail audit
    -- 2026-06-12).
    local where = (hint ~= nil) and (", and needs " .. hint .. " terrain") or "";
    if impRow.PrereqTech ~= nil and not hasTech(impRow.PrereqTech) then
        local t = GameInfo.Technologies[impRow.PrereqTech];
        return "needs " .. (t and Locale.Lookup(t.Name) or "a technology") .. where;
    end
    if impRow.PrereqCivic ~= nil and not hasCivic(impRow.PrereqCivic) then
        local c = GameInfo.Civics[impRow.PrereqCivic];
        return "needs civic " .. (c and Locale.Lookup(c.Name) or "") .. where;
    end
    if hint ~= nil then return "requires " .. hint; end
    return "not available on this tile";
end

-- Build the ordered item list for the selected builder's tile. Buildable-now
-- first (recommended flagged), then LOCKED improvements the builder could make
-- elsewhere/later, each with its unlock reason (Noel 2026-06-02: show locked too
-- so you know where to move the builder and what tech/resource you still need).
-- Returns items, reasonString, validCount.
local function buildItems()
    local pUnit = headUnit();
    if pUnit == nil then return nil, "No unit selected"; end
    if pUnit:GetOwner() ~= lp() then return nil, "Not your unit"; end
    local op = buildOpHash();
    if op == nil then return nil, "Build operation not found"; end

    local tParameters = {};
    tParameters[UnitOperationTypes.PARAM_X] = pUnit:GetX();
    tParameters[UnitOperationTypes.PARAM_Y] = pUnit:GetY();
    local ok, tResults = UnitManager.CanStartOperation(pUnit, op, nil, tParameters, true);
    local improvements = (ok and tResults ~= nil) and tResults[UnitOperationResults.IMPROVEMENTS] or nil;
    local best = (ok and tResults ~= nil) and tResults[UnitOperationResults.BEST_IMPROVEMENT] or nil;

    local items, validTypes = {}, {};
    -- Buildable now, recommended first.
    if improvements ~= nil then
        if best ~= nil and best ~= -1 then
            for _, e in ipairs(improvements) do
                if e == best then
                    items[#items + 1] = { label = impName(e) .. ", recommended", eImp = e };
                    local r = GameInfo.Improvements[e];
                    if r ~= nil then validTypes[r.ImprovementType] = true; end
                    break;
                end
            end
        end
        for _, e in ipairs(improvements) do
            local r = GameInfo.Improvements[e];
            local t = r and r.ImprovementType or "";
            if not validTypes[t] then
                items[#items + 1] = { label = impName(e), eImp = e };
                validTypes[t] = true;
            end
        end
    end
    local nValid = #items;

    -- Locked: builder-buildable improvements not valid here, with reasons.
    local locked = {};
    for impType in pairs(builderImprovementTypes(pUnit)) do
        if not validTypes[impType] then
            local r = GameInfo.Improvements[impType];
            if r ~= nil then
                local reason = lockReason(r);
                locked[#locked + 1] = {
                    label  = impName(r.Index) .. ", locked, " .. reason,
                    eImp   = r.Index,
                    locked = true,
                    reason = reason,
                };
            end
        end
    end
    table.sort(locked, function(a, b) return a.label < b.label; end);
    for _, it in ipairs(locked) do items[#items + 1] = it; end

    if #items == 0 then
        return nil, "Nothing to build on this tile.";
    end
    return items, nil, nValid;
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

-- Ctrl+T: what the improvement actually DOES (Noel 2026-06-12: items spoke
-- only their names — "no extended data"). Description comes from GameInfo;
-- Speech.emit strips the [ICON_*] markers on its own.
local function describeCurrent()
    local item = _items[_index];
    if item == nil then return; end
    local parts = { impName(item.eImp) };
    local r = GameInfo.Improvements[item.eImp];
    if r ~= nil and r.Description ~= nil then
        local ok, d = pcall(function() return Locale.Lookup(r.Description); end);
        if ok and d ~= nil and d ~= "" then parts[#parts + 1] = d; end
    end
    if item.locked and item.reason ~= nil then
        parts[#parts + 1] = "Locked, " .. item.reason;
    end
    Speech.emit(table.concat(parts, ". "), "status");
end

local function commit()
    local item = _items[_index];
    if item == nil then return; end
    if item.locked then
        -- Locked entries are informational — explain what's missing, stay open.
        Speech.emit("Can't build that here yet. " .. (item.reason or ""), "meta");
        return;
    end
    local pUnit = headUnit();
    if pUnit == nil then
        Speech.emit("No unit selected", "meta");
        BuildImprovementPicker.close();
        return;
    end
    local op = buildOpHash();
    local tParameters = {};
    tParameters[UnitOperationTypes.PARAM_X] = pUnit:GetX();
    tParameters[UnitOperationTypes.PARAM_Y] = pUnit:GetY();
    tParameters[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = item.eImp;
    -- Charges read BEFORE the operation: counts the one being spent now.
    local charges = nil;
    pcall(function() charges = pUnit:GetBuildCharges(); end);
    UnitManager.RequestOperation(pUnit, op, tParameters);
    -- Builders work INSTANTLY in Civ VI (no build turns — unlike Civ V
    -- workers) and spend one of their charges. Say where it landed and what's
    -- left (Noel 2026-06-12: "no way to tell where it put it and how long").
    local msg = "Built " .. impName(item.eImp) .. " on this tile";
    if charges ~= nil then
        local left = charges - 1;
        if left <= 0 then
            msg = msg .. ". That was the Builder's last charge";
        else
            msg = msg .. ". Builder has " .. left
                .. ((left == 1) and " charge" or " charges") .. " left";
        end
    end
    Speech.emit(msg, "event");
    BuildImprovementPicker.close();
end

local function cancel()
    Speech.emit("Cancelled", "meta");
    BuildImprovementPicker.close();
end

local _handler = {
    name = "BuildImprovementPicker",
    capturesAllInput = true,
    bindings = {
        bind(VK_UP,     MOD_NONE, function() navTo(_index - 1); end, "Previous improvement"),
        bind(VK_DOWN,   MOD_NONE, function() navTo(_index + 1); end, "Next improvement"),
        bind(VK_HOME,   MOD_NONE, function() navTo(1); end,          "First improvement"),
        bind(VK_END,    MOD_NONE, function() navTo(#_items); end,    "Last improvement"),
        bind(VK_RETURN, MOD_NONE, commit, "Build selected improvement"),
        bind(VK_SPACE,  MOD_NONE, commit, "Build selected improvement"),
        bind(VK_ESCAPE, MOD_NONE, cancel, "Cancel"),
        bind(VK_T,      MOD_CTRL, describeCurrent, "What the improvement does"),
    },
    helpEntries = {
        { keyLabel = "Up/Down", description = "Previous / next improvement (available ones first, then locked)" },
        { keyLabel = "Home/End", description = "First / last improvement" },
        { keyLabel = "Ctrl+T", description = "What the selected improvement does (yields, effects)" },
        { keyLabel = "Enter", description = "Build the selected improvement; on a locked one, explain what it needs" },
        { keyLabel = "Escape", description = "Cancel without building" },
    },
};

function BuildImprovementPicker.open()
    if _open then return; end
    local items, reason, nValid = buildItems();
    if items == nil then
        Speech.emit(reason or "Cannot build here.", "meta");
        return;
    end
    _items = items;
    _index = 1;
    _open  = true;
    if UIManager ~= nil and UIManager.QueuePopup ~= nil and PopupPriority ~= nil then
        UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
    end
    HandlerStack.push(_handler);
    nValid = nValid or #items;
    local nLocked = #items - nValid;
    local summary;
    if nValid > 0 and nLocked > 0 then
        summary = nValid .. " available, " .. nLocked .. " locked";
    elseif nValid > 0 then
        summary = nValid .. " available";
    else
        summary = nLocked .. " locked";
    end
    Speech.emit("Build improvement. " .. summary .. ".", "critical");
    announceCurrent();
end

function BuildImprovementPicker.close()
    if not _open then return; end
    _open = false;
    HandlerStack.removeByName("BuildImprovementPicker");
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

local function OnOpenEvent()
    local ok, err = pcall(BuildImprovementPicker.open);
    if not ok then Log.error("BuildImprovementPicker.open failed: " .. tostring(err)); end
end

local function Initialize()
    if ContextPtr == nil then
        Log.warn("BuildImprovementPicker.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_OpenBuildPicker.Add(OnOpenEvent);
        Log.info("BuildImprovementPicker: subscribed to CivViAccess_OpenBuildPicker");
    end
end
Initialize();

Log.info("BuildImprovementPicker.lua: loaded");
