-- City production unblock workaround (0.5.2). Until the full accessible
-- production picker lands, blind players hit a hard stop on the
-- ENDTURN_BLOCKING_PRODUCTION blocker — the engine refuses to end-turn
-- when any city has an empty production queue, and the
-- ProductionPanel chooser UI isn't arrow-key navigable.
--
-- CityProduction.unblockAll() iterates the local player's cities and
-- queues a sensible default into any city with no current production:
--
--   1. Monument (building, no prereqs, 60 prod) — canonical first-turn
--      build, available in every fresh city.
--   2. Warrior (unit, 40 prod) — fallback if Monument is unavailable
--      (already built, late-game captured city, etc).
--   3. Cheapest available building or unit — last-resort fallback for
--      mid/late-game cities where neither default qualifies.
--
-- Announces queued items per city, then the total ("Queued 3 cities").
-- Hotkey is Alt+P (wired in HexCursorAddin via CIVVIACCESS_UnblockProduction).
--
-- This is a TEMPORARY workaround. The full picker (arrow-nav through
-- units / buildings / wonders / districts / projects with cost + benefit
-- announcement) is task #9 in the Playable Basics arc and will replace
-- this once it ships. The hotkey stays as a quick-default convenience
-- even after the picker exists.
--
-- Civ V Access analogue: CivVAccess_ChooseProductionPopupAccess.lua
-- (full picker, no quick-default workaround).

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

    if #queued == 0 and skipped == 0 then
        OutputMessageToScreenReader("All cities have production");
        return;
    end

    if #queued == 1 then
        OutputMessageToScreenReader("Queued " .. queued[1]);
    elseif #queued > 1 then
        OutputMessageToScreenReader("Queued " .. tostring(#queued) .. " cities. "
                                    .. table.concat(queued, ", "));
    end
    if skipped > 0 then
        OutputMessageToScreenReader(tostring(skipped) .. " cities had nothing to queue",
                                    true);
    end
end

local function Initialize()
    Log.info("CityProduction.lua: loaded");
end
Initialize();
