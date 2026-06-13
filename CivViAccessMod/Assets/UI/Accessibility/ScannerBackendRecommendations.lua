-- ScannerBackendRecommendations.lua — scanner backend for the engine's own
-- top CITY-SITE recommendations (the "where should I settle" data the game uses
-- for its green settle highlights). Wraps GetGrandStrategicAI():
-- GetSettlementRecommendations(N) — the same call BoardQueryProbe already uses.
--
-- All recommended sites collapse into one item, "City site", with N instances
-- (nearest-first). entry.data keeps the engine's reason + rank so a future
-- auto-pick / placement-preview layer can use them (see
-- project_placement_preview_vision). v1 surfaces city sites only; Civ VI
-- builder/district placement recommendations (if exposed to Lua) are a later add.

include("Log");
include("ScannerCore");

ScannerBackendRecommendations = { name = "recommendations" };

local NUM_SITES = 6;

local function localPlayerId()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

local function plotIndexFromXY(x, y)
    if Map == nil or Map.GetPlot == nil or x == nil or y == nil then return nil; end
    local plot = nil;
    pcall(function() plot = Map.GetPlot(x, y); end);
    if plot == nil then return nil; end
    local ok, idx = pcall(function() return plot:GetIndex(); end);
    return (ok and idx ~= nil) and idx or nil;
end

function ScannerBackendRecommendations.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 or Players == nil then return out; end
    local player = Players[localId];
    if player == nil or player.GetGrandStrategicAI == nil then return out; end

    local ai = nil;
    pcall(function() ai = player:GetGrandStrategicAI(); end);
    if ai == nil or ai.GetSettlementRecommendations == nil then return out; end

    local ok, recs = pcall(function() return ai:GetSettlementRecommendations(NUM_SITES); end);
    if not ok or recs == nil then return out; end

    for i, r in ipairs(recs) do
        local loc = r.SettlingLocation;
        if loc ~= nil and Map.GetPlotLocation ~= nil then
            local okLoc, tx, ty = pcall(function() return Map.GetPlotLocation(loc); end);
            if okLoc and tx ~= nil then
                local plotIndex = plotIndexFromXY(tx, ty);
                if plotIndex ~= nil then
                    local reason = nil;
                    if r.SettleExplanation0 ~= nil and r.SettleExplanation0 ~= "" then
                        reason = Locale.Lookup(r.SettleExplanation0);
                    end
                    out[#out + 1] = {
                        plotIndex   = plotIndex,
                        category    = "recommendations",
                        subcategory = "all",
                        itemName    = "City site",
                        key         = "rec:settle:" .. plotIndex,
                        sortKey     = i,   -- preserve the engine's ranking as a tiebreak
                        data        = { kind = "settle", rank = i, reason = reason },
                    };
                end
            end
        end
    end

    -- WORK SITES (Noel 2026-06-12: "an easier way to find places to build
    -- stuff, like a sighted person does" — this is the spoken Builder lens).
    -- Probe every plot the player OWNS with the same engine check the Shift+B
    -- picker uses: CanStartOperation(BUILD_IMPROVEMENT, PARAM_X/Y, results) ->
    -- the valid improvement list for that tile. The check is per-UNIT (tech,
    -- charges, abilities), so it needs a live Builder — without one there are
    -- no work-site entries, exactly like the sighted lens that only lights up
    -- while a Builder is selected. Tiles already improved are skipped.
    -- Find a live builder-class unit (the lens lights up only with one).
    local pBuilder = nil;
    pcall(function()
        for _, u in player:GetUnits():Members() do
            local row = GameInfo.Units[u:GetUnitType()];
            if row ~= nil and row.BuildCharges ~= nil and row.BuildCharges > 0 then
                pBuilder = u;
                break;
            end
        end
    end);
    if pBuilder ~= nil and Map.GetPlotCount ~= nil then
        -- STATIC validity from the game database. The first build probed the
        -- engine (CanStartOperation with remote PARAM_X/Y) — the engine
        -- ignored the coords and answered for the builder's CURRENT tile,
        -- so every owned plot claimed "Lumber Mill" (Noel's log 2026-06-12).
        -- These are the same tables the Shift+B picker's lockReason reads;
        -- engine-exotic rules (Polder adjacency etc.) aren't expressible
        -- here, so the picker on arrival remains ground truth.
        local candidates = {};   -- array of { row, terrains={}, nTerrains, features={}, resources={} }
        pcall(function()
            local buildable = {};
            local uRow = GameInfo.Units[pBuilder:GetUnitType()];
            for r in GameInfo.Improvement_ValidBuildUnits() do
                if uRow ~= nil and r.UnitType == uRow.UnitType then buildable[r.ImprovementType] = true; end
            end
            local pTechs  = player.GetTechs   ~= nil and player:GetTechs()   or nil;
            local pCult   = player.GetCulture ~= nil and player:GetCulture() or nil;
            local function unlocked(impRow)
                if impRow.PrereqTech ~= nil then
                    local t = GameInfo.Technologies[impRow.PrereqTech];
                    if t == nil or pTechs == nil or not pTechs:HasTech(t.Index) then return false; end
                end
                if impRow.PrereqCivic ~= nil then
                    local c = GameInfo.Civics[impRow.PrereqCivic];
                    if c == nil or pCult == nil or not pCult:HasCivic(c.Index) then return false; end
                end
                return true;
            end
            for impRow in GameInfo.Improvements() do
                if buildable[impRow.ImprovementType] and unlocked(impRow) then
                    local c = { row = impRow, terrains = {}, nTerrains = 0,
                                features = {}, resources = {} };
                    for r in GameInfo.Improvement_ValidTerrains() do
                        if r.ImprovementType == impRow.ImprovementType then
                            c.terrains[r.TerrainType] = true;
                            c.nTerrains = c.nTerrains + 1;
                        end
                    end
                    for r in GameInfo.Improvement_ValidFeatures() do
                        if r.ImprovementType == impRow.ImprovementType then c.features[r.FeatureType] = true; end
                    end
                    for r in GameInfo.Improvement_ValidResources() do
                        if r.ImprovementType == impRow.ImprovementType then c.resources[r.ResourceType] = true; end
                    end
                    candidates[#candidates + 1] = c;
                end
            end
        end);
        local playerResources = nil;
        pcall(function() playerResources = Players[localId]:GetResources(); end);

        -- Best candidate for one plot. Priority: resource match (the tile's
        -- visible resource wants ITS improvement) > feature match (woods ->
        -- Lumber Mill) > terrain match, most-specific candidate first (Mine's
        -- hills-only beats Farm's everywhere). Tiles whose resource/feature
        -- has no unlocked match yield NOTHING (don't suggest builds the
        -- engine would refuse or that need a chop).
        local function bestFor(plot)
            local terrainType, featureType, resType = nil, nil, nil;
            pcall(function()
                local tr = GameInfo.Terrains[plot:GetTerrainType()];
                terrainType = tr and tr.TerrainType or nil;
                local fIdx = plot:GetFeatureType();
                if fIdx ~= -1 then
                    local fr = GameInfo.Features[fIdx];
                    featureType = fr and fr.FeatureType or nil;
                end
                local rIdx = plot:GetResourceType();
                if rIdx ~= -1 then
                    local rr = GameInfo.Resources[rIdx];
                    if rr ~= nil then
                        local visible = true;
                        if playerResources ~= nil and playerResources.IsResourceVisible ~= nil then
                            local ok, v = pcall(function() return playerResources:IsResourceVisible(rr.Hash); end);
                            visible = ok and v == true;
                        end
                        if visible then resType = rr.ResourceType; end
                    end
                end
            end);
            if resType ~= nil then
                for _, c in ipairs(candidates) do
                    if c.resources[resType] then return c.row; end
                end
                return nil;   -- resource tile, no unlocked harvester yet
            end
            if featureType ~= nil then
                for _, c in ipairs(candidates) do
                    if c.features[featureType] then return c.row; end
                end
                return nil;   -- featured tile needs a chop or a later tech
            end
            if terrainType == nil then return nil; end
            local best = nil;
            for _, c in ipairs(candidates) do
                if c.terrains[terrainType] then
                    if best == nil or c.nTerrains < best.nTerrains then best = c; end
                end
            end
            return best ~= nil and best.row or nil;
        end

        for i = 0, Map.GetPlotCount() - 1 do
            local plot = Map.GetPlotByIndex(i);
            if plot ~= nil then
                local eligible = false;
                pcall(function()
                    eligible = (plot:GetOwner() == localId)
                           and (plot:GetImprovementType() == -1)
                           and not plot:IsCity()
                           and plot:GetDistrictType() == -1;
                end);
                if eligible then
                    local impRow = bestFor(plot);
                    if impRow ~= nil then
                        out[#out + 1] = {
                            plotIndex   = i,
                            category    = "recommendations",
                            subcategory = "all",
                            itemName    = Locale.Lookup(impRow.Name) .. " site",
                            key         = "rec:work:" .. i,
                            data        = { kind = "work", eImp = impRow.Index },
                        };
                    end
                end
            end
        end
    end
    return out;
end

function ScannerBackendRecommendations.ValidateEntry(entry, _cursorPlotHint)
    if Map == nil or Map.GetPlotByIndex == nil then return false; end
    local plot = Map.GetPlotByIndex(entry.plotIndex);
    if plot == nil then return false; end
    -- A work site that got built (or lost) since the scan is stale.
    if entry.data ~= nil and entry.data.kind == "work" then
        local stillValid = false;
        pcall(function()
            stillValid = (plot:GetImprovementType() == -1)
                     and (plot:GetOwner() == localPlayerId());
        end);
        return stillValid;
    end
    return true;
end

function ScannerBackendRecommendations.FormatName(entry)
    -- Keep the collapse key clean ("City site"); the engine's reason rides in
    -- entry.data.reason for a richer announce / detail readout later.
    return entry.itemName or "recommendation";
end

Scanner.registerBackend(ScannerBackendRecommendations);

Log.info("ScannerBackendRecommendations.lua: loaded");
