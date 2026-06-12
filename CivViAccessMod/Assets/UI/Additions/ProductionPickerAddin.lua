-- ProductionPickerAccess: screen-reader-driven city production picker.
--
-- Stage 1 shell (2026-05-26). Implements the modal shell + nav per
-- docs/PICKER_DESIGN.md:
--   - 3 tabs (Produce / Gold / Faith) — tabs that have zero items
--     auto-hide; for Stage 1 all three show empty.
--   - 6 flat-with-headers groups per tab (Units / Districts /
--     Buildings / Wonders / Projects / Queue).
--   - Tab + PgUp + PgDn switch tabs.
--   - Shift+PgUp / Shift+PgDn jump to prev/next group header within
--     the tab.
--   - Up/Down step through items including headers; Home/End jump.
--   - Enter / Space activate a choice (Stage 1: no choices yet).
--   - Esc closes picker.
--   - Ctrl+T re-reads current item with longer detail (Stage 1: just
--     re-reads label).
--   - Comma / Period prev / next city (Stage 1: stubs that speak
--     "city cycle not wired yet").
--
-- Entry construction (H), label composition (I), commit paths (J),
-- queue editing (J'), tile placement (K, L) come in subsequent
-- stages.
--
-- Opens via UIManager:QueuePopup which makes the Context the active
-- modal and routes raw KeyDown to our SetInputHandler. Closes via
-- UIManager:DequeuePopup.
--
-- IMPORTANT: when the local player is designated SIGHTED (e.g.
-- hotseat with a sighted partner — see [[project-sighted-mode-per-turn]]),
-- the picker MUST NOT auto-open and the engine's ProductionPanel
-- MUST stay visible. Stage 2 wires the per-turn check before
-- ProductionPicker.open() is allowed to proceed. For Stage 1 single-
-- player blind testing, the gate is "open() is callable; sighted
-- check is a TODO."

include("Log");
include("ScreenReader");
include("HandlerStack");
include("InputRouter");

ProductionPicker = ProductionPicker or {};

-- ====================================================================
-- Constants
-- ====================================================================

local TAB_PRODUCE  = 1;
local TAB_GOLD     = 2;
local TAB_FAITH    = 3;
local TAB_NAMES    = { "Produce", "Gold", "Faith" };

local GROUP_NAMES = {
    "Units", "Districts", "Buildings", "Wonders", "Projects", "Queue"
};

local ITEM_HEADER = "header";
local ITEM_CHOICE = "choice";
local ITEM_TEXT   = "text";

-- Key + modifier constants. Civ VI uses Keys.* enum.
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
local VK_COMMA   = 188;  -- Keys.VK_OEM_COMMA not exposed; Civ V Access uses literal
local VK_PERIOD  = 190;

local MOD_NONE  = 0;
local MOD_SHIFT = 1;
local MOD_CTRL  = 2;

-- ====================================================================
-- State
-- ====================================================================

local _state = {
    open       = false,
    city       = nil,     -- pCity userdata; re-resolved fresh on each access
    cityOwner  = -1,
    cityID     = -1,
    tabIndex   = TAB_PRODUCE,
    itemIndex  = { 1, 1, 1 },  -- per-tab cursor
    tabs       = nil,    -- built on open; tabs[i].items = {entry, entry, ...}
};

local _handler = nil;  -- HandlerStack entry; set on first open

-- ====================================================================
-- Helpers
-- ====================================================================

local function currentCity()
    if _state.cityOwner < 0 or _state.cityID < 0 then return nil; end
    local p = Players[_state.cityOwner];
    if p == nil then return nil; end
    -- pPlayer:GetCityByID is gameplay-VM-only; UI VM throws on it.
    -- Iterate Members() and match by ID. Same pattern as
    -- OnLuaEventOpenPicker.
    local cities = p:GetCities();
    if cities == nil then return nil; end
    for _, c in cities:Members() do
        if c:GetID() == _state.cityID then return c; end
    end
    return nil;
end

local function currentTab()
    if _state.tabs == nil then return nil; end
    return _state.tabs[_state.tabIndex];
end

local function currentItems()
    local tab = currentTab();
    if tab == nil then return {}; end
    return tab.items or {};
end

local function currentItem()
    local items = currentItems();
    if #items == 0 then return nil; end
    local idx = _state.itemIndex[_state.tabIndex] or 1;
    if idx < 1 then idx = 1; end
    if idx > #items then idx = #items; end
    return items[idx];
end

-- ====================================================================
-- Tab construction — Stage 2 (real entries)
-- ====================================================================
--
-- Iterate GameInfo per kind, filter via pCity:GetBuildQueue():CanProduce
-- (mirroring engine ProductionPanel.lua:1911). For items the city can
-- start producing right now, build a Choice entry whose activate fn
-- calls CityManager.RequestOperation(BUILD) with the right PARAM_*_TYPE.
--
-- Wonders vs Buildings split: BuildingClasses with MaxGlobalInstances > 0
-- (true world wonders) or MaxPlayerInstances == 1 (national wonders) go
-- in Wonders; everything else in Buildings.
--
-- Placement-required items (most districts + most wonders) commit OK at
-- the engine level but the engine then drops the player into a
-- placement interface mode that has no keyboard-accessible UI in Stage 2.
-- We mark these items with a placement-needed suffix so the user knows
-- what they're committing to; Stage K/L will wire the placement sub-flow.

local function isWonderBuilding(buildingRow)
    if buildingRow == nil then return false; end
    local bclass = GameInfo.BuildingClasses and GameInfo.BuildingClasses[buildingRow.BuildingClass];
    if bclass == nil then
        -- Civ VI doesn't use BuildingClasses the same way Civ V does;
        -- fall back to per-building flags.
        return buildingRow.IsWonder == true
            or (buildingRow.MaxPlayerInstances ~= nil and buildingRow.MaxPlayerInstances == 1)
            or (buildingRow.MaxWorldInstances ~= nil and buildingRow.MaxWorldInstances > 0);
    end
    return (bclass.MaxGlobalInstances ~= nil and bclass.MaxGlobalInstances > 0)
        or (bclass.MaxPlayerInstances == 1)
        or (bclass.MaxTeamInstances ~= nil and bclass.MaxTeamInstances > 0);
end

-- Strip Civ VI text-markup that Tolk can't pronounce. [NEWLINE] → ". ",
-- [COLOR:...] / [ENDCOLOR] → "". [ICON_*] markers are stripped
-- automatically by OutputMessageToScreenReader so we leave them alone.
-- Collapses runs of whitespace.
local function stripPickerFormatting(text)
    if text == nil then return ""; end
    text = tostring(text);
    text = text:gsub("%[NEWLINE%]", ". ");
    text = text:gsub("%[COLOR:[^%]]+%]", "");
    text = text:gsub("%[COLOR_[^%]]+%]", "");
    text = text:gsub("%[ENDCOLOR%]", "");
    text = text:gsub("%s+", " ");
    -- Collapse "... . ." artifacts from joining NEWLINE-separated lines.
    text = text:gsub("%.%s*%.", ".");
    return text;
end

-- Ctrl+T long-form: read the engine's own tooltip for this item.
-- Engine ToolTipHelper.* return rich, fully-localized strings with
-- yields, ability lists, prereqs, etc — same content the sighted UI
-- shows on hover. Strip the formatting for speech, then speak.
--
-- Per-kind dispatch matches the engine UI's own usage:
--   Units:     ToolTipHelper.GetUnitToolTip(hash, formation, buildQueue)
--   Buildings: ToolTipHelper.GetBuildingToolTip(hash, playerID, city)
--   Districts: ToolTipHelper.GetDistrictToolTip(hash)
--   Projects:  ToolTipHelper.GetProjectToolTip(hash)
local function composeLongForm(row, kind, pCity, pQueue)
    if row == nil then return nil; end
    local parts = {};

    -- Description (LOC key on the row, if present).
    if row.Description ~= nil and row.Description ~= "" then
        local desc = Locale.Lookup(row.Description);
        if desc ~= nil and desc ~= "" then
            parts[#parts + 1] = stripPickerFormatting(desc);
        end
    end

    if ToolTipHelper ~= nil and row.Hash ~= nil then
        local playerID = Game.GetLocalPlayer();
        local tooltip = nil;
        local ok = false;
        if kind == "unit" and ToolTipHelper.GetUnitToolTip ~= nil then
            ok, tooltip = pcall(ToolTipHelper.GetUnitToolTip,
                row.Hash, MilitaryFormationTypes.STANDARD_MILITARY_FORMATION, pQueue);
        elseif (kind == "building" or kind == "wonder")
                and ToolTipHelper.GetBuildingToolTip ~= nil then
            ok, tooltip = pcall(ToolTipHelper.GetBuildingToolTip,
                row.Hash, playerID, pCity);
        elseif kind == "district" and ToolTipHelper.GetDistrictToolTip ~= nil then
            ok, tooltip = pcall(ToolTipHelper.GetDistrictToolTip, row.Hash);
        elseif kind == "project" and ToolTipHelper.GetProjectToolTip ~= nil then
            ok, tooltip = pcall(ToolTipHelper.GetProjectToolTip, row.Hash);
        end
        if ok and tooltip ~= nil and tooltip ~= "" then
            local stripped = stripPickerFormatting(tooltip);
            if stripped ~= "" then
                parts[#parts + 1] = stripped;
            end
        end
    end

    if #parts == 0 then return nil; end
    return table.concat(parts, ". ");
end

-- Verb chosen by param key so commit speech reads naturally:
--   Unit       → "Training Warrior"
--   Building   → "Building Granary"
--   District   → "Building Holy Site"
--   Wonder     → (Building, comes through PARAM_BUILDING_TYPE)
--   Project    → "Starting project Spaceport"
-- Civ V Access uses "Train" / "Construct" similarly; Civ VI's sighted
-- UI tooltips use the same verbs. Noel 2026-05-26 flagged that one
-- uniform "Producing" felt off.
local COMMIT_VERB_BY_PARAM = {
    [CityOperationTypes.PARAM_UNIT_TYPE]     = "Training",
    [CityOperationTypes.PARAM_BUILDING_TYPE] = "Building",
    [CityOperationTypes.PARAM_DISTRICT_TYPE] = "Building",
    [CityOperationTypes.PARAM_PROJECT_TYPE]  = "Starting project",
};

-- Resolve a production-type hash to (localized name, type string). Used by
-- the replace-confirmation to name what's currently building.
local function hashToNameAndType(hash)
    if hash == nil or hash == 0 then return nil, nil; end
    local name, typeString = nil, nil;
    pcall(function()
        local tables = {
            { t = "Units",     f = "UnitType" },
            { t = "Buildings", f = "BuildingType" },
            { t = "Districts", f = "DistrictType" },
            { t = "Projects",  f = "ProjectType" },
        };
        for _, spec in ipairs(tables) do
            local t = GameInfo[spec.t];
            if t ~= nil then
                for row in t() do
                    if row.Hash == hash then
                        if row.Name ~= nil then name = Locale.Lookup(row.Name); end
                        typeString = row[spec.f];
                        return;
                    end
                end
            end
        end
    end);
    return name, typeString;
end

-- Replace-confirmation latch (Noel 2026-06-12): committing while another
-- build is IN PROGRESS discards its accumulated production — warn first
-- ("Granary is in progress, 2 turns to complete. Press Enter again to
-- replace it with Builder."); a second activation of the SAME item commits.
-- Keyed by city+item; any other activation re-arms for that item instead,
-- and close() clears it so a stale arm can't auto-commit a later session.
-- Same preview->confirm idiom as combat's Ctrl+A.
local _replaceArm = nil;

function ProductionPicker.clearReplaceArm()
    _replaceArm = nil;
end

local function commitBuild(pCity, paramKey, hash, displayName, turnsStr)
    local curHash = nil;
    pcall(function()
        local q = pCity:GetBuildQueue();
        if q ~= nil and q.GetCurrentProductionTypeHash ~= nil then
            local h = q:GetCurrentProductionTypeHash();
            if h ~= nil and h ~= 0 then curHash = h; end
        end
    end);
    if curHash ~= nil and curHash == hash then
        _replaceArm = nil;
        Speech.emit(displayName .. " is already building.", "status");
        return;
    end
    if curHash ~= nil then
        local armKey = tostring(pCity:GetID()) .. ":" .. tostring(hash);
        if _replaceArm ~= armKey then
            _replaceArm = armKey;
            local curName, curType = hashToNameAndType(curHash);
            local msg = (curName or "Another build") .. " is in progress";
            -- Turns left INLINE — the shared turnsString local is defined
            -- BELOW this function, so it's not in scope here (calling it was
            -- a silent nil — Noel heard no turns, Lua.log 2026-06-12).
            local left = nil;
            pcall(function()
                local t = pCity:GetBuildQueue():GetTurnsLeft(curType);
                if t ~= nil and t > 0 then
                    left = (t == 1) and "1 turn" or (tostring(t) .. " turns");
                end
            end);
            if left ~= nil then msg = msg .. ", " .. left .. " to complete"; end
            Speech.emit(msg .. ". Press Enter again to replace it with "
                .. displayName .. ".", "status");
            return;
        end
        _replaceArm = nil;
    end
    local tParameters = {};
    tParameters[paramKey] = hash;
    -- REPLACE the current build, don't append (Noel 2026-06-12: picking
    -- Granary mid-Warrior silently QUEUED it behind the Warrior — the
    -- engine's default insert mode appends). The vanilla ProductionPanel
    -- sends exactly this pair for a normal pick with the queue UI closed
    -- (GetBuildInsertMode): replace at queue slot 0. An explicit
    -- queue-append gesture can come later with real queue support.
    if CityOperationTypes.PARAM_INSERT_MODE ~= nil
       and CityOperationTypes.VALUE_REPLACE_AT ~= nil then
        tParameters[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_REPLACE_AT;
        tParameters[CityOperationTypes.PARAM_QUEUE_DESTINATION_LOCATION] = 0;
    end
    local ok, err = pcall(function()
        CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters);
    end);
    if not ok then
        Log.error("ProductionPicker.commit: RequestOperation failed: " .. tostring(err));
        Speech.emit("Could not start " .. displayName, "meta");
        return;
    end
    local verb = COMMIT_VERB_BY_PARAM[paramKey] or "Building";
    -- Include turns-to-complete in the commit announce so the user
    -- knows how many turns to expect ("Training Builder, 8 turns to
    -- complete"). Per Noel 2026-05-27: "for the production queue, it
    -- doesn't actually tell how long we have until ... the builder
    -- will be done."
    local msg = verb .. " " .. displayName;
    if turnsStr ~= nil and turnsStr ~= "" then
        msg = msg .. ", " .. turnsStr .. " to complete";
    end
    Speech.emit(msg, "event");
    ProductionPicker.close();
end

-- Compose failure reasons from a strict CanProduce results table.
-- Reasons are LOC keys (e.g. "LOC_BUILDING_PREREQ_TECH_NEEDED") that
-- Locale.Lookup resolves to user-facing text.
--
-- Civ VI returns results under different namespaces depending on the
-- production kind. Buildings/districts use UnitOperationResults
-- (legacy naming from when there was no separate result namespace
-- for production). Units may use UnitOperationResults OR
-- CityOperationResults. Try both for robustness — confirmed via
-- diagnostic 2026-05-26 that units came back with "disabled" but no
-- text because we only checked UnitOperationResults.
local function composeFailureReasons(results)
    if results == nil then return nil; end
    local function gather(reasonsTable, label)
        if reasonsTable == nil then return {}; end
        local out = {};
        for _, key in ipairs(reasonsTable) do
            local resolved = Locale.Lookup(key);
            if resolved ~= nil and resolved ~= "" then
                out[#out + 1] = resolved;
            end
        end
        return out;
    end
    local parts = {};
    if UnitOperationResults ~= nil and UnitOperationResults.FAILURE_REASONS ~= nil then
        for _, p in ipairs(gather(results[UnitOperationResults.FAILURE_REASONS])) do
            parts[#parts + 1] = p;
        end
    end
    if CityOperationResults ~= nil and CityOperationResults.FAILURE_REASONS ~= nil
       and CityOperationResults.FAILURE_REASONS ~= UnitOperationResults.FAILURE_REASONS then
        for _, p in ipairs(gather(results[CityOperationResults.FAILURE_REASONS])) do
            parts[#parts + 1] = p;
        end
    end
    if #parts == 0 then return nil; end
    return table.concat(parts, "; ");
end

-- Compute "N turns" string for an item given its type string. Uses
-- pQueue:GetTurnsLeft(typeString) — engine's per-item turns-to-
-- complete calc (accounts for current production yield + existing
-- progress on that item). Returns nil if the engine can't compute
-- turns (e.g., the city has 0 production output).
local function turnsString(pQueue, typeString)
    if typeString == nil or typeString == "" then return nil; end
    local ok, turns = pcall(function() return pQueue:GetTurnsLeft(typeString); end);
    if not ok or turns == nil or turns <= 0 then return nil; end
    if turns == 1 then return "1 turn"; end
    return tostring(turns) .. " turns";
end

-- Build a Choice entry given strict-check results. If isCanStart is
-- false, the entry is disabled — label appends "disabled, [reasons]"
-- and activation speaks the same line instead of committing.
local function makeChoiceWithState(pCity, paramKey, hash, displayName,
                                    requiresPlacement, isCanStart, results, turnsStr)
    local label = displayName;
    -- Turns token comes right after the name, per
    -- docs/PICKER_DESIGN.md label-token order. Only shown when the
    -- item is producible right now (a disabled item doesn't have
    -- meaningful turns-to-complete since you can't start it).
    if isCanStart and turnsStr ~= nil then
        label = label .. " — " .. turnsStr;
    end
    if requiresPlacement then
        label = label .. " — placement needed (coming soon)";
    end
    if not isCanStart then
        local reasons = composeFailureReasons(results);
        if reasons ~= nil then
            label = label .. " — disabled, " .. reasons;
        else
            label = label .. " — disabled";
        end
    end
    return {
        kind     = ITEM_CHOICE,
        label    = label,
        disabled = not isCanStart,
        activate = function()
            if not isCanStart then
                Speech.emit(label, "picker");
                return;
            end
            if requiresPlacement then
                Speech.emit(
                    displayName .. " requires tile placement, not yet keyboard-accessible. "
                    .. "Skipping for now.", "meta");
                return;
            end
            commitBuild(pCity, paramKey, hash, displayName, turnsStr);
        end,
    };
end

-- Loose check: "could this item EVER be built in this city" (filters
-- out fundamentally-impossible items like Lighthouse in landlocked
-- cities). Strict check: "can it be built RIGHT NOW" + reasons table.
-- We list any item passing loose; ones failing strict get
-- disabled-with-reason. Mirrors engine ProductionPanel.lua lines
-- 2026/2038 pattern.
--
-- row + kind passed through so Ctrl+T can compose long-form text
-- (description + engine tooltip) on demand without re-iterating.
local function makeChoiceFromRow(pCity, pQueue, hash, paramKey, displayName,
                                  requiresPlacement, typeString, row, kind)
    if not pQueue:CanProduce(hash, true) then return nil; end
    local isCanStart, results = pQueue:CanProduce(hash, false, true);
    local turnsStr = turnsString(pQueue, typeString);
    local entry = makeChoiceWithState(
        pCity, paramKey, hash, displayName, requiresPlacement, isCanStart, results, turnsStr);
    if entry ~= nil then
        entry.longFn = function() return composeLongForm(row, kind, pCity, pQueue); end
    end
    return entry;
end

local function buildUnitEntries(pCity)
    local entries = {};
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return entries; end
    for row in GameInfo.Units() do
        local hash = row.Hash;
        if hash ~= nil then
            local name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.UnitType);
            local entry = makeChoiceFromRow(
                pCity, pQueue, hash, CityOperationTypes.PARAM_UNIT_TYPE, name, false,
                row.UnitType, row, "unit");
            if entry ~= nil then entries[#entries + 1] = entry; end
        end
    end
    return entries;
end

local function buildDistrictEntries(pCity)
    local entries = {};
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return entries; end
    for row in GameInfo.Districts() do
        local hash = row.Hash;
        if hash ~= nil then
            local name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.DistrictType);
            local needsPlacement = (row.RequiresPlacement == true);
            local entry = makeChoiceFromRow(
                pCity, pQueue, hash, CityOperationTypes.PARAM_DISTRICT_TYPE, name, needsPlacement,
                row.DistrictType, row, "district");
            if entry ~= nil then entries[#entries + 1] = entry; end
        end
    end
    return entries;
end

local function buildBuildingAndWonderEntries(pCity)
    local buildings, wonders = {}, {};
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return buildings, wonders; end
    for row in GameInfo.Buildings() do
        local hash = row.Hash;
        if hash ~= nil then
            local name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.BuildingType);
            local needsPlacement = (row.RequiresPlacement == true);
            local isWonder = isWonderBuilding(row);
            local entry = makeChoiceFromRow(
                pCity, pQueue, hash, CityOperationTypes.PARAM_BUILDING_TYPE, name, needsPlacement,
                row.BuildingType, row, isWonder and "wonder" or "building");
            if entry ~= nil then
                if isWonder then
                    wonders[#wonders + 1] = entry;
                else
                    buildings[#buildings + 1] = entry;
                end
            end
        end
    end
    return buildings, wonders;
end

local function buildProjectEntries(pCity)
    local entries = {};
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return entries; end
    if GameInfo.Projects == nil then return entries; end
    for row in GameInfo.Projects() do
        local hash = row.Hash;
        if hash ~= nil then
            local name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.ProjectType);
            local entry = makeChoiceFromRow(
                pCity, pQueue, hash, CityOperationTypes.PARAM_PROJECT_TYPE, name, false,
                row.ProjectType, row, "project");
            if entry ~= nil then entries[#entries + 1] = entry; end
        end
    end
    return entries;
end

local function buildQueueEntries(pCity)
    local entries = {};
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return entries; end
    -- Use dot-access for existence check (colon-syntax requires call
    -- parens). If the method doesn't exist on this build, return empty.
    if pQueue.GetCurrentProductionTypeHash == nil then return entries; end
    local currentHash = pQueue:GetCurrentProductionTypeHash();
    if currentHash == nil or currentHash == 0 then return entries; end
    -- Resolve hash to a human-readable name + type string (the type string
    -- feeds GetTurnsLeft so the line carries time remaining — Noel 2026-06-12:
    -- "I don't hear how much time is left for the current build").
    local name = "current production";
    local typeString = nil;
    for row in GameInfo.Units() do
        if row.Hash == currentHash then
            name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.UnitType);
            typeString = row.UnitType;
            break;
        end
    end
    if typeString == nil then
        for row in GameInfo.Buildings() do
            if row.Hash == currentHash then
                name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.BuildingType);
                typeString = row.BuildingType;
                break;
            end
        end
    end
    if typeString == nil then
        for row in GameInfo.Districts() do
            if row.Hash == currentHash then
                name = (row.Name ~= nil) and Locale.Lookup(row.Name) or tostring(row.DistrictType);
                typeString = row.DistrictType;
                break;
            end
        end
    end
    local label = "Currently building " .. name;
    local left = turnsString(pQueue, typeString);
    if left ~= nil then label = label .. " — " .. left .. " left"; end
    entries[#entries + 1] = {
        kind  = ITEM_TEXT,
        label = label,
    };
    return entries;
end

-- Append a group header + its choice entries to the flat-with-headers
-- item list. Per docs/PICKER_DESIGN.md, every group announces its
-- header even when empty ("Units, none available") so the nav
-- structure stays uniform.
local function appendGroup(items, groupName, entries)
    local count = #entries;
    local headerLabel = groupName;
    if count == 0 then
        headerLabel = groupName .. ", none available";
    elseif count == 1 then
        headerLabel = groupName .. ", 1 item";
    else
        headerLabel = groupName .. ", " .. tostring(count) .. " items";
    end
    items[#items + 1] = { kind = ITEM_HEADER, label = headerLabel };
    for _, e in ipairs(entries) do
        items[#items + 1] = e;
    end
end

local function buildProduceTab(pCity)
    -- Use the UI-selected city (post-SelectCity in open()) instead of
    -- the iteration-resolved object. Theory: GetBuildQueue() on a
    -- non-UI-selected city returns a sentinel that fails all
    -- CanProduce calls. Engine ProductionPanel always uses
    -- UI.GetHeadSelectedCity().
    if UI ~= nil and UI.GetHeadSelectedCity ~= nil then
        local selCity = UI.GetHeadSelectedCity();
        if selCity ~= nil then
            Log.info("buildProduceTab: using UI-selected city id=" .. tostring(selCity:GetID())
                     .. " (was iter-resolved id=" .. tostring(pCity:GetID()) .. ")");
            pCity = selCity;
        else
            Log.warn("buildProduceTab: UI.GetHeadSelectedCity returned nil; using iter city");
        end
    end
    local items = {};
    local units = buildUnitEntries(pCity);
    local districts = buildDistrictEntries(pCity);
    local buildings, wonders = buildBuildingAndWonderEntries(pCity);
    local projects = buildProjectEntries(pCity);
    local queue = buildQueueEntries(pCity);
    appendGroup(items, "Units",     units);
    appendGroup(items, "Districts", districts);
    appendGroup(items, "Buildings", buildings);
    appendGroup(items, "Wonders",   wonders);
    appendGroup(items, "Projects",  projects);
    appendGroup(items, "Queue",     queue);
    return { name = "Produce", items = items };
end

-- Stage 2 placeholder: Gold + Faith tabs stay empty until the purchase
-- API wiring lands. Per docs/PICKER_DESIGN.md, those tabs eventually
-- use pCity:Purchase(YieldTypes.YIELD_GOLD / YIELD_FAITH, hash); for
-- now they show "none available" everywhere.
local function buildPurchaseTabStub(tabName)
    local items = {};
    for _, groupName in ipairs(GROUP_NAMES) do
        items[#items + 1] = {
            kind  = ITEM_HEADER,
            label = groupName .. ", none available",
        };
    end
    return { name = tabName, items = items };
end

local function buildTabs()
    local pCity = currentCity();
    local tabs = {};
    if pCity ~= nil then
        tabs[1] = buildProduceTab(pCity);
    else
        tabs[1] = buildPurchaseTabStub("Produce");
    end
    tabs[2] = buildPurchaseTabStub("Gold");
    tabs[3] = buildPurchaseTabStub("Faith");
    return tabs;
end

-- ====================================================================
-- Speech
-- ====================================================================

-- Local picker-speech wrapper. Always emits as "picker" kind so item
-- nav (arrow-mash) coalesces — only the most recently-focused item
-- speaks. The legacy `nointerrupt` arg is now ignored: same-kind
-- back-to-back in picker tier already replaces in flight via
-- coalesce. Preamble + first-item sequences use Speech.emit directly
-- with kind="status" for the follow-up line so it queues behind the
-- preamble rather than clobbering it.
local function speak(text, nointerrupt)
    Speech.emit(text, "picker");
end

local function announcePreamble()
    local city = currentCity();
    if city == nil then
        speak("Production picker. No city selected.");
        return;
    end
    local parts = {};
    parts[#parts + 1] = "Production picker for " .. Locale.Lookup(city:GetName());
    parts[#parts + 1] = "Population " .. tostring(city:GetPopulation());
    local tab = currentTab();
    if tab ~= nil then
        parts[#parts + 1] = tab.name .. " tab";
    end
    speak(table.concat(parts, ". ") .. ".");
end

local function announceItem(item)
    if item == nil then
        speak("No items.");
        return;
    end
    speak(item.label);
end

local function announceCurrentItem()
    announceItem(currentItem());
end

local function announceTab()
    local tab = currentTab();
    if tab == nil then return; end
    local items = tab.items or {};
    -- Skim count: how many CHOICE items (real production options) exist
    -- in this tab. For Stage 1, that's always 0.
    local choiceCount = 0;
    for _, e in ipairs(items) do
        if e.kind == ITEM_CHOICE then choiceCount = choiceCount + 1; end
    end
    speak(tab.name .. " tab, " .. tostring(choiceCount) .. " items.");
end

-- ====================================================================
-- Navigation
-- ====================================================================

local function moveItemIndex(delta)
    local items = currentItems();
    if #items == 0 then return; end
    local idx = _state.itemIndex[_state.tabIndex] or 1;
    idx = idx + delta;
    if idx < 1 then idx = #items; end
    if idx > #items then idx = 1; end
    _state.itemIndex[_state.tabIndex] = idx;
    announceCurrentItem();
end

local function setItemIndex(idx)
    local items = currentItems();
    if #items == 0 then return; end
    if idx < 1 then idx = 1; end
    if idx > #items then idx = #items; end
    _state.itemIndex[_state.tabIndex] = idx;
    announceCurrentItem();
end

local function moveTab(delta)
    if _state.tabs == nil then return; end
    local n = #_state.tabs;
    if n == 0 then return; end
    local idx = _state.tabIndex + delta;
    if idx < 1 then idx = n; end
    if idx > n then idx = 1; end
    _state.tabIndex = idx;
    announceTab();
    -- Land on the first item in the new tab; queue the follow-up
    -- (NOINTERRUPT) so the tab header speech finishes first instead of
    -- being clobbered. Same fix as the open() preamble path.
    _state.itemIndex[idx] = 1;
    local item = currentItem();
    if item ~= nil then
        -- status kind: lower priority than picker, so the gateway
        -- queues this behind the preamble / tab-header speech (which
        -- emitted as picker tier moments earlier) instead of
        -- coalesce-clobbering it.
        Speech.emit(item.label, "status");
    end
end

local function jumpToGroupHeader(direction)
    -- direction: -1 = previous header (or current if we're past it),
    -- +1 = next header. Headers are item.kind == ITEM_HEADER.
    local items = currentItems();
    if #items == 0 then return; end
    local idx = _state.itemIndex[_state.tabIndex] or 1;
    local n = #items;
    local target = nil;
    if direction > 0 then
        for i = idx + 1, n do
            if items[i].kind == ITEM_HEADER then target = i; break; end
        end
        -- Wrap to first header.
        if target == nil then
            for i = 1, idx do
                if items[i].kind == ITEM_HEADER then target = i; break; end
            end
        end
    else
        for i = idx - 1, 1, -1 do
            if items[i].kind == ITEM_HEADER then target = i; break; end
        end
        if target == nil then
            for i = n, idx, -1 do
                if items[i].kind == ITEM_HEADER then target = i; break; end
            end
        end
    end
    if target ~= nil then
        setItemIndex(target);
    end
end

-- ====================================================================
-- Actions
-- ====================================================================

local function activateCurrent()
    local item = currentItem();
    if item == nil then
        speak("Nothing to activate.");
        return;
    end
    if item.kind == ITEM_HEADER or item.kind == ITEM_TEXT then
        -- Re-read on activation; group headers aren't activatable.
        speak(item.label);
        return;
    end
    if item.kind == ITEM_CHOICE then
        if type(item.activate) == "function" then
            item.activate();
        else
            speak("No action wired yet.");
        end
    end
end

local function readLongForm()
    local item = currentItem();
    if item == nil then return; end
    local long = nil;
    if type(item.longFn) == "function" then
        local ok, result = pcall(item.longFn);
        if ok then long = result; end
    elseif item.long ~= nil then
        long = item.long;
    end
    if long ~= nil and long ~= "" then
        speak(item.label .. ". " .. long);
    else
        speak(item.label);
    end
end

-- Walk the player's cities in iteration order, find the current
-- city's index, advance forward or backward (wrapping). Update
-- _state to target the new city, rebuild tabs against it, re-speak
-- the preamble + first item. Mirrors the cycle pattern from
-- CivVAccess_ChooseProductionPopupAccess.lua's cityStep / cycleCity.
local function cycleCity(direction)
    if Game == nil then return; end
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID < 0 then return; end
    local pPlayer = Players[localPlayerID];
    if pPlayer == nil then return; end
    local pCities = pPlayer:GetCities();
    if pCities == nil then return; end

    local list = {};
    for _, c in pCities:Members() do
        list[#list + 1] = c;
    end
    if #list == 0 then
        speak("No cities");
        return;
    end
    if #list == 1 then
        speak("Only one city");
        return;
    end

    -- Find current city's position in the iteration list.
    local curIdx = nil;
    for i, c in ipairs(list) do
        if c:GetID() == _state.cityID and c:GetOwner() == _state.cityOwner then
            curIdx = i;
            break;
        end
    end
    if curIdx == nil then
        -- Current city not found in iteration (race condition?
        -- Snapshotted city was razed?). Land on the first city.
        curIdx = 1;
    end

    local nextIdx = curIdx + ((direction > 0) and 1 or -1);
    if nextIdx < 1 then nextIdx = #list; end
    if nextIdx > #list then nextIdx = 1; end
    local newCity = list[nextIdx];
    if newCity == nil then return; end

    _state.cityOwner = newCity:GetOwner();
    _state.cityID    = newCity:GetID();
    if UI ~= nil and UI.SelectCity ~= nil then
        pcall(function() UI.SelectCity(newCity); end);
    end
    _state.tabs      = buildTabs();
    _state.tabIndex  = TAB_PRODUCE;
    _state.itemIndex = { 1, 1, 1 };

    announcePreamble();
    local item = currentItem();
    if item ~= nil then
        -- status kind: lower priority than picker, so the gateway
        -- queues this behind the preamble / tab-header speech (which
        -- emitted as picker tier moments earlier) instead of
        -- coalesce-clobbering it.
        Speech.emit(item.label, "status");
    end
end

-- ====================================================================
-- Open / Close
-- ====================================================================

local function ensureHandler()
    if _handler ~= nil then return _handler; end
    local bind = HandlerStack.bind;
    _handler = {
        name             = "ProductionPicker",
        capturesAllInput = true,
        bindings = {
            bind(VK_TAB,    MOD_NONE,  function() moveTab(1);  end, "Next tab"),
            bind(VK_PRIOR,  MOD_NONE,  function() moveTab(-1); end, "Previous tab"),
            bind(VK_NEXT,   MOD_NONE,  function() moveTab(1);  end, "Next tab"),
            bind(VK_PRIOR,  MOD_SHIFT, function() jumpToGroupHeader(-1); end, "Previous group"),
            bind(VK_NEXT,   MOD_SHIFT, function() jumpToGroupHeader(1);  end, "Next group"),
            bind(VK_UP,     MOD_NONE,  function() moveItemIndex(-1); end, "Previous item"),
            bind(VK_DOWN,   MOD_NONE,  function() moveItemIndex(1);  end, "Next item"),
            bind(VK_HOME,   MOD_NONE,  function() setItemIndex(1); end, "First item"),
            bind(VK_END,    MOD_NONE,  function() setItemIndex(#currentItems()); end, "Last item"),
            bind(VK_RETURN, MOD_NONE,  function() activateCurrent(); end, "Activate"),
            bind(VK_SPACE,  MOD_NONE,  function() activateCurrent(); end, "Activate"),
            bind(VK_ESCAPE, MOD_NONE,  function() ProductionPicker.close(); end, "Close picker"),
            bind(VK_T,      MOD_CTRL,  function() readLongForm(); end, "Long-form detail"),
            bind(VK_COMMA,  MOD_NONE,  function() cycleCity(-1); end, "Previous city"),
            bind(VK_PERIOD, MOD_NONE,  function() cycleCity(1);  end, "Next city"),
        },
        helpEntries = {
            { keyLabel = "Tab",             description = "Next tab" },
            { keyLabel = "PageUp/PageDown", description = "Previous / next tab" },
            { keyLabel = "Shift+PageUp/PageDown", description = "Previous / next group" },
            { keyLabel = "Up/Down",         description = "Previous / next item" },
            { keyLabel = "Home/End",        description = "First / last item" },
            { keyLabel = "Enter or Space",  description = "Activate" },
            { keyLabel = "Escape",          description = "Close picker" },
            { keyLabel = "Ctrl+T",          description = "Long-form detail" },
            { keyLabel = "Comma/Period",    description = "Previous / next city" },
        },
        onActivate = function() Log.info("ProductionPicker: handler activated"); end,
        onDeactivate = function() Log.info("ProductionPicker: handler deactivated"); end,
    };
    return _handler;
end

function ProductionPicker.isOpen()
    return _state.open == true;
end

function ProductionPicker.open(pCity)
    Log.info("ProductionPicker.open: entry");
    if pCity == nil then
        Log.warn("ProductionPicker.open: nil city");
        return;
    end
    if _state.open then
        Log.info("ProductionPicker.open: already open; re-targeting");
    end

    -- Snapshot city ref. Re-resolve fresh in currentCity() each access
    -- (engine may invalidate userdata across frames per Civ V Access pattern).
    local ok, err = pcall(function()
        _state.cityOwner = pCity:GetOwner();
        _state.cityID    = pCity:GetID();
    end);
    if not ok then
        Log.error("ProductionPicker.open: city snapshot failed: " .. tostring(err));
        return;
    end
    Log.info("ProductionPicker.open: city snapshot OK owner="
             .. tostring(_state.cityOwner) .. " id=" .. tostring(_state.cityID));

    -- Engine ProductionPanel.Open() does three things before iterating:
    --   1. UI.GetHeadSelectedCity() -> m_pCity
    --   2. LuaEvents.ProductionPanel_Open() — broadcasts "panel opening"
    --   3. UI.SetInterfaceMode(InterfaceModeTypes.SELECTION)
    -- Our picker only did (1) via UI.SelectCity. CanProduce still
    -- returned false for buildings. Try the other two before iterating.
    ok, err = pcall(function()
        if UI ~= nil and UI.SelectCity ~= nil then
            UI.SelectCity(pCity);
        end
        if LuaEvents ~= nil and LuaEvents.ProductionPanel_Open ~= nil then
            LuaEvents.ProductionPanel_Open();
        end
        if UI ~= nil and UI.SetInterfaceMode ~= nil
           and InterfaceModeTypes ~= nil and InterfaceModeTypes.SELECTION ~= nil then
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        end
    end);
    if not ok then
        Log.warn("ProductionPicker.open: pre-iterate priming failed (non-fatal): " .. tostring(err));
    end

    ok, err = pcall(function()
        _state.tabs      = buildTabs();
        _state.tabIndex  = TAB_PRODUCE;
        _state.itemIndex = { 1, 1, 1 };
        _state.open      = true;
    end);
    if not ok then
        Log.error("ProductionPicker.open: buildTabs failed: " .. tostring(err));
        return;
    end
    Log.info("ProductionPicker.open: tabs built");

    ok, err = pcall(function()
        HandlerStack.push(ensureHandler());
    end);
    if not ok then
        Log.error("ProductionPicker.open: HandlerStack.push failed: " .. tostring(err));
        return;
    end
    Log.info("ProductionPicker.open: handler pushed");

    -- Suppress engine's ProductionPanel (sighted UI) while ours is up.
    -- See [[project-sighted-mode-per-turn]] — when sighted partner is
    -- on turn, our picker should not open at all, and engine UI stays.
    ok, err = pcall(function()
        if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
            local engineProd = ContextPtr:LookUpControl("/InGame/ProductionPanel");
            if engineProd ~= nil and engineProd.SetHide ~= nil then
                engineProd:SetHide(true);
            end
        end
    end);
    if not ok then
        Log.warn("ProductionPicker.open: ProductionPanel suppress failed (non-fatal): " .. tostring(err));
    end
    Log.info("ProductionPicker.open: engine panel suppress attempted");

    ok, err = pcall(function()
        if UIManager ~= nil and UIManager.QueuePopup ~= nil then
            UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
            Log.info("ProductionPicker.open: queued popup");
        else
            Log.warn("ProductionPicker.open: UIManager.QueuePopup unavailable");
        end
    end);
    if not ok then
        Log.error("ProductionPicker.open: QueuePopup failed: " .. tostring(err));
    end

    Log.info("ProductionPicker.open: about to speak preamble");
    ok, err = pcall(function()
        announcePreamble();
        -- First-item as status (pri 2). Preamble emits as picker
        -- (pri 6) and its shield queues status behind it instead of
        -- coalesce-replacing the preamble. Noel 2026-05-26 reported
        -- not hearing the preamble; log showed it spoke but was cut
        -- off by this immediate follow-up.
        local item = currentItem();
        if item ~= nil then
            Speech.emit(item.label, "status");
        end
    end);
    if not ok then
        Log.error("ProductionPicker.open: preamble/announce failed: " .. tostring(err));
    end
    Log.info("ProductionPicker.open: complete");
end

function ProductionPicker.close()
    if not _state.open then return; end
    ProductionPicker.clearReplaceArm();
    local closingSilently = _state.closingSilently == true;
    _state.closingSilently = false;
    _state.open = false;

    HandlerStack.removeByName("ProductionPicker");

    if UIManager ~= nil and UIManager.DequeuePopup ~= nil then
        UIManager:DequeuePopup(ContextPtr);
    end

    -- Exit city view ("Hotel California" fix). UI.SelectCity in open()
    -- put the engine into city mode (engine ProductionPanel + city
    -- banner up); without explicit deselect the user is stuck there
    -- after picker closes. UI.DeselectAllCities + InterfaceMode reset
    -- returns to the normal map / unit-control mode.
    pcall(function()
        if UI ~= nil and UI.DeselectAllCities ~= nil then
            UI.DeselectAllCities();
        end
        if UI ~= nil and UI.SetInterfaceMode ~= nil
           and InterfaceModeTypes ~= nil and InterfaceModeTypes.SELECTION ~= nil then
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        end
    end);

    -- Restore engine ProductionPanel visibility (stays hidden by other
    -- engine logic if nothing's selected; we just clear our hide).
    if ContextPtr ~= nil and ContextPtr.LookUpControl ~= nil then
        local engineProd = ContextPtr:LookUpControl("/InGame/ProductionPanel");
        if engineProd ~= nil and engineProd.SetHide ~= nil then
            engineProd:SetHide(false);
        end
    end

    if not closingSilently then
        speak("Production picker closed.");
    end
    Log.info("ProductionPicker.close: closed (silent=" .. tostring(closingSilently) .. ")");
end

-- ====================================================================
-- Input handler
-- ====================================================================

local function onInput(pInputStruct)
    if not _state.open then return false; end
    if pInputStruct == nil then return false; end
    local msgType = pInputStruct.GetMessageType and pInputStruct:GetMessageType();
    -- Only handle KeyUp (consistent with OptionsAccess pattern).
    local keyUp = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257;
    if msgType ~= keyUp then return false; end

    local key = pInputStruct:GetKey();
    local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);

    return InputRouter.dispatch(key, mods);
end

-- Cross-VM open trigger. HexCursorAddin runs in a different Lua VM
-- (separate Context) so it can't call ProductionPicker.open directly.
-- Instead it fires LuaEvents.CivViAccess_OpenProductionPicker(ownerID,
-- cityID); we resolve the city on our side and call open().
local function OnLuaEventOpenPicker(ownerID, cityID)
    Log.info("ProductionPickerAddin: OnLuaEventOpenPicker called owner="
             .. tostring(ownerID) .. " cityID=" .. tostring(cityID));
    if ownerID == nil or cityID == nil then
        Log.warn("ProductionPickerAddin: nil args; aborting");
        return;
    end
    local pPlayer = Players[ownerID];
    if pPlayer == nil then
        Log.warn("ProductionPickerAddin: player not found");
        return;
    end
    -- pPlayer:GetCityByID(id) is a gameplay-VM-only API; the UI VM
    -- silently throws on it (diagnostic 2026-05-26: handler entered,
    -- never reached "calling ProductionPicker.open" — no GetCityByID
    -- usage anywhere in engine UI source confirms it's not exposed).
    -- Iterate GetCities():Members() and match by ID instead.
    local pCity = nil;
    local pCities = pPlayer:GetCities();
    if pCities ~= nil then
        for _, c in pCities:Members() do
            if c:GetID() == cityID then
                pCity = c;
                break;
            end
        end
    end
    if pCity == nil then
        Log.warn("ProductionPickerAddin: city not found in player cities");
        Speech.emit("Production picker: city not found", "meta");
        return;
    end
    Log.info("ProductionPickerAddin: calling ProductionPicker.open");
    ProductionPicker.open(pCity);
end

local function Initialize()
    if ContextPtr == nil then
        Log.warn("ProductionPicker.Initialize: ContextPtr unavailable");
        return;
    end
    ContextPtr:SetInputHandler(onInput, true);
    -- Hide on init; we manage visibility via QueuePopup / DequeuePopup.
    ContextPtr:SetHide(true);
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_OpenProductionPicker.Add(OnLuaEventOpenPicker);
        Log.info("ProductionPickerAddin: subscribed to CivViAccess_OpenProductionPicker");
    end
    Log.info("ProductionPickerAddin.Initialize: input handler installed");
end

Initialize();
