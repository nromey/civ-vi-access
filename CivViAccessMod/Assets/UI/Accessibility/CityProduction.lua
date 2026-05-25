-- End-turn blocker unblock workaround (0.5.2). Civ VI gates end-turn
-- on several "you need to make a decision" popups, and none of the
-- chooser UIs (ProductionPanel, ResearchChooser, CivicsChooser) are
-- arrow-key navigable. Without programmatic defaults, a blind player
-- cannot proceed past turn 1 — production blocker, then tech blocker,
-- then civic blocker, then production again next turn.
--
-- CityProduction.unblockAll() — single hotkey (Alt+P) that handles all
-- three blocker types in one pass:
--
--   PRODUCTION (per city with empty queue):
--     1. Monument (building, no prereqs, 60 prod) — canonical first-
--        turn build, available in every fresh city.
--     2. Warrior (unit, 40 prod) — fallback if Monument unavailable.
--     3. Cheapest available building or unit — last-resort fallback
--        for mid/late-game cities.
--
--   RESEARCH (when player has no current tech):
--     Cheapest available technology (lowest Cost, CanResearch=true).
--     On turn 1 that's typically Pottery / Animal Husbandry / Mining
--     / Sailing depending on map. API: UI.RequestPlayerOperation
--     with PlayerOperations.RESEARCH.
--
--   CIVIC (when player has no current civic):
--     Cheapest available civic. Turn 1 = Code of Laws (the only
--     option, prereq for everything else). API:
--     UI.RequestPlayerOperation with PlayerOperations.PROGRESS_CIVIC.
--
-- Per-item announce ("Queued Monument in Cape Town. Researching
-- Pottery. Studying Code of Laws.").
--
-- Hotkey is Alt+P (wired in HexCursorAddin via CIVVIACCESS_UnblockProduction).
-- Name is a holdover from when this only handled production; kept for
-- continuity with the original 0.5.2 ship.
--
-- This is a TEMPORARY workaround. The full accessible pickers (arrow-
-- nav through items with cost + benefit announcement) are tasks #9
-- (production), and will follow for tech and civic. The Alt+P unblock
-- stays as a quick-default convenience even after the pickers exist.
--
-- Civ V Access analogue: CivVAccess_ChooseProductionPopupAccess.lua
-- (full pickers, no quick-default workaround).

include("Log");
include("ScreenReader");

CityProduction = CityProduction or {};

-- Engine API constants. Wrapped in pcall paths so the file doesn't
-- crash-load if a future engine rev renames anything.
local DEFAULT_BUILDING_TYPE = "BUILDING_MONUMENT";
local DEFAULT_UNIT_TYPE     = "UNIT_WARRIOR";

local function localPlayerID()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    if not ok or id == nil then return -1; end
    return id;
end

-- Returns the hash for a Buildings or Units row by Type string, or nil.
local function hashForBuilding(typeName)
    local row = GameInfo.Buildings[typeName];
    if row == nil then return nil; end
    return row.Hash;
end

local function hashForUnit(typeName)
    local row = GameInfo.Units[typeName];
    if row == nil then return nil; end
    return row.Hash;
end

-- True if the city has nothing currently producing. Engine convention:
-- GetCurrentProductionTypeHash() returns 0 when the queue is empty
-- (per ProductionPanel.lua:88 m_CurrentProductionHash = 0 default).
local function cityIsBlocked(pCity)
    if pCity == nil then return false; end
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return false; end
    local ok, hash = pcall(function() return pQueue:GetCurrentProductionTypeHash(); end);
    if not ok then return false; end
    return hash == nil or hash == 0;
end

-- Try to queue (cityCommandType, paramKey, hash). Returns the localized
-- name on success, nil on failure. Mirrors ProductionPanel.lua's
-- BuildBuilding / BuildUnit / AdvanceProject pattern.
local function queueBuilding(pCity, buildingHash, displayName)
    if buildingHash == nil then return nil; end
    local tParameters = {};
    tParameters[CityOperationTypes.PARAM_BUILDING_TYPE] = buildingHash;
    local ok = pcall(CityManager.RequestOperation, pCity, CityOperationTypes.BUILD, tParameters);
    if not ok then return nil; end
    return displayName;
end

local function queueUnit(pCity, unitHash, displayName)
    if unitHash == nil then return nil; end
    local tParameters = {};
    tParameters[CityOperationTypes.PARAM_UNIT_TYPE] = unitHash;
    local ok = pcall(CityManager.RequestOperation, pCity, CityOperationTypes.BUILD, tParameters);
    if not ok then return nil; end
    return displayName;
end

-- Iterate GameInfo.Buildings, return (hash, localizedName, cost) for the
-- cheapest buildable building in this city. Skips wonders (we want
-- something quick to complete, not a wonder commitment).
local function cheapestBuilding(pCity)
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return nil, nil, 0; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Buildings() do
        if row.IsWonder ~= true then
            local can = false;
            local okQ, result = pcall(function() return pQueue:CanProduce(row.Hash, true); end);
            if okQ and result then can = true; end
            if can then
                local cost = row.Cost or 99999;
                if bestCost == nil or cost < bestCost then
                    bestHash = row.Hash;
                    bestName = Locale.Lookup(row.Name);
                    bestCost = cost;
                end
            end
        end
    end
    return bestHash, bestName, bestCost;
end

local function cheapestUnit(pCity)
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return nil, nil, 0; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Units() do
        local can = false;
        local okQ, result = pcall(function() return pQueue:CanProduce(row.Hash, true); end);
        if okQ and result then can = true; end
        if can then
            local cost = row.Cost or 99999;
            if bestCost == nil or cost < bestCost then
                bestHash = row.Hash;
                bestName = Locale.Lookup(row.Name);
                bestCost = cost;
            end
        end
    end
    return bestHash, bestName, bestCost;
end

-- Queue a sensible default into this blocked city. Returns the queued
-- item's localized name, or nil if literally nothing could be queued
-- (shouldn't happen in normal play — every city can build at least a
-- Slinger or some building).
local function queueDefault(pCity)
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return nil; end

    -- Try Monument first.
    local monumentHash = hashForBuilding(DEFAULT_BUILDING_TYPE);
    if monumentHash ~= nil then
        local okQ, can = pcall(function() return pQueue:CanProduce(monumentHash, true); end);
        if okQ and can then
            return queueBuilding(pCity, monumentHash, "Monument");
        end
    end

    -- Try Warrior.
    local warriorHash = hashForUnit(DEFAULT_UNIT_TYPE);
    if warriorHash ~= nil then
        local okQ, can = pcall(function() return pQueue:CanProduce(warriorHash, true); end);
        if okQ and can then
            return queueUnit(pCity, warriorHash, "Warrior");
        end
    end

    -- Fall back to cheapest available building, then cheapest unit.
    local bHash, bName = cheapestBuilding(pCity);
    if bHash ~= nil then
        return queueBuilding(pCity, bHash, bName);
    end
    local uHash, uName = cheapestUnit(pCity);
    if uHash ~= nil then
        return queueUnit(pCity, uHash, uName);
    end

    return nil;
end

-- =======================================================================
-- Research + Civic auto-pick (the other two end-turn blockers)
-- =======================================================================

-- True if the local player needs to choose a research right now.
-- pPlayerTechs:GetResearchingTech() returns -1 (or nil in some
-- engine revs) when nothing is queued.
local function needsResearch(pPlayer)
    local pTechs = pPlayer:GetTechs();
    if pTechs == nil then return false; end
    local ok, current = pcall(function() return pTechs:GetResearchingTech(); end);
    if not ok then return false; end
    return current == nil or current < 0;
end

local function needsCivic(pPlayer)
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil then return false; end
    local ok, current = pcall(function() return pCulture:GetProgressingCivic(); end);
    if not ok then return false; end
    return current == nil or current < 0;
end

-- Iterate GameInfo.Technologies, return (hash, name) of the cheapest
-- tech the player can research right now. Cost-sorted so we don't
-- accidentally commit a multi-era boost target.
local function cheapestResearch(pPlayer)
    local pTechs = pPlayer:GetTechs();
    if pTechs == nil then return nil, nil; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Technologies() do
        local can = false;
        local okC, result = pcall(function() return pTechs:CanResearch(row.Index); end);
        if okC and result then can = true; end
        if can then
            local cost = row.Cost or 99999;
            if bestCost == nil or cost < bestCost then
                bestHash = row.Hash;
                bestName = Locale.Lookup(row.Name);
                bestCost = cost;
            end
        end
    end
    return bestHash, bestName;
end

local function cheapestCivic(pPlayer)
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil then return nil, nil; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Civics() do
        local can = false;
        local okC, result = pcall(function() return pCulture:CanProgress(row.Index); end);
        if okC and result then can = true; end
        if can then
            local cost = row.Cost or 99999;
            if bestCost == nil or cost < bestCost then
                bestHash = row.Hash;
                bestName = Locale.Lookup(row.Name);
                bestCost = cost;
            end
        end
    end
    return bestHash, bestName;
end

-- Commit research selection. Mirrors ResearchChooser.lua:252
-- OnChooseResearch — UI.RequestPlayerOperation with the RESEARCH
-- operation. Returns the localized name on success, nil on failure.
local function setResearch(pid, techHash, displayName)
    if techHash == nil then return nil; end
    local tParameters = {};
    tParameters[PlayerOperations.PARAM_TECH_TYPE] = techHash;
    tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
    local ok = pcall(UI.RequestPlayerOperation, pid, PlayerOperations.RESEARCH, tParameters);
    if not ok then return nil; end
    return displayName;
end

-- Mirrors CivicsChooser.lua:239 OnChooseCivic.
local function setCivic(pid, civicHash, displayName)
    if civicHash == nil then return nil; end
    local tParameters = {};
    tParameters[PlayerOperations.PARAM_CIVIC_TYPE] = civicHash;
    tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
    local ok = pcall(UI.RequestPlayerOperation, pid, PlayerOperations.PROGRESS_CIVIC, tParameters);
    if not ok then return nil; end
    return displayName;
end

-- =======================================================================
-- Top-level: clear every end-turn blocker we know how to default
-- =======================================================================

function CityProduction.unblockAll()
    local pid = localPlayerID();
    if pid < 0 then
        OutputMessageToScreenReader("No active player");
        return;
    end
    local pPlayer = Players[pid];
    if pPlayer == nil then
        OutputMessageToScreenReader("Player not available");
        return;
    end
    local pCities = pPlayer:GetCities();
    if pCities == nil then
        OutputMessageToScreenReader("No cities");
        return;
    end

    -- Pass 1: production. Iterate cities, queue defaults into any
    -- city with an empty production queue.
    local queued = {};
    local skipped = 0;
    for _, pCity in pCities:Members() do
        if cityIsBlocked(pCity) then
            local cityName = Locale.Lookup(pCity:GetName());
            local queuedName = queueDefault(pCity);
            if queuedName ~= nil then
                table.insert(queued, queuedName .. " in " .. cityName);
                Log.info("CityProduction.unblockAll: queued " .. queuedName
                         .. " in " .. cityName);
            else
                skipped = skipped + 1;
                Log.warn("CityProduction.unblockAll: could not queue anything in "
                         .. cityName);
            end
        end
    end

    -- Pass 2: research. If no current tech, pick the cheapest
    -- available and commit it.
    local researchPicked = nil;
    if needsResearch(pPlayer) then
        local tHash, tName = cheapestResearch(pPlayer);
        if tHash ~= nil then
            researchPicked = setResearch(pid, tHash, tName);
            if researchPicked ~= nil then
                Log.info("CityProduction.unblockAll: researching " .. researchPicked);
            end
        end
    end

    -- Pass 3: civic.
    local civicPicked = nil;
    if needsCivic(pPlayer) then
        local cHash, cName = cheapestCivic(pPlayer);
        if cHash ~= nil then
            civicPicked = setCivic(pid, cHash, cName);
            if civicPicked ~= nil then
                Log.info("CityProduction.unblockAll: studying " .. civicPicked);
            end
        end
    end

    -- Announce. Order: production first (per-city + total), then
    -- research, then civic, then skip count. Each spoken-line queued
    -- (NOINTERRUPT after the first) so the burst doesn't truncate.
    local spoke = false;

    if #queued == 1 then
        OutputMessageToScreenReader("Queued " .. queued[1]);
        spoke = true;
    elseif #queued > 1 then
        OutputMessageToScreenReader("Queued " .. tostring(#queued) .. " cities. "
                                    .. table.concat(queued, ", "));
        spoke = true;
    end

    if researchPicked ~= nil then
        OutputMessageToScreenReader("Researching " .. researchPicked, spoke);
        spoke = true;
    end
    if civicPicked ~= nil then
        OutputMessageToScreenReader("Studying " .. civicPicked, spoke);
        spoke = true;
    end

    if skipped > 0 then
        OutputMessageToScreenReader(tostring(skipped) .. " cities had nothing to queue",
                                    spoke);
        spoke = true;
    end

    if not spoke then
        OutputMessageToScreenReader("No blockers to clear");
    end
end

local function Initialize()
    Log.info("CityProduction.lua: loaded");
end
Initialize();
