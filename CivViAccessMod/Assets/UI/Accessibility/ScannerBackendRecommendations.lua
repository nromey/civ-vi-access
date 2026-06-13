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
    if pBuilder ~= nil and UnitManager ~= nil and UnitManager.CanStartOperation ~= nil then
        local op = (UnitOperationTypes ~= nil and UnitOperationTypes.BUILD_IMPROVEMENT) or nil;
        if op ~= nil and Map.GetPlotCount ~= nil then
            for i = 0, Map.GetPlotCount() - 1 do
                local plot = Map.GetPlotByIndex(i);
                if plot ~= nil then
                    local owned, improved = false, false;
                    pcall(function()
                        owned = (plot:GetOwner() == localId);
                        improved = (plot:GetImprovementType() ~= -1);
                    end);
                    if owned and not improved then
                        local best = nil;
                        pcall(function()
                            local tParameters = {};
                            tParameters[UnitOperationTypes.PARAM_X] = plot:GetX();
                            tParameters[UnitOperationTypes.PARAM_Y] = plot:GetY();
                            local canStart, tResults =
                                UnitManager.CanStartOperation(pBuilder, op, nil, tParameters, true);
                            if canStart and tResults ~= nil then
                                local imps = tResults[UnitOperationResults.IMPROVEMENTS];
                                if imps ~= nil and #imps > 0 then
                                    best = tResults[UnitOperationResults.BEST_IMPROVEMENT];
                                    if best == nil or best == -1 then best = imps[1]; end
                                end
                            end
                        end);
                        if best ~= nil then
                            local row = GameInfo.Improvements[best];
                            local impName = (row ~= nil and row.Name ~= nil)
                                            and Locale.Lookup(row.Name) or "Improvement";
                            out[#out + 1] = {
                                plotIndex   = i,
                                category    = "recommendations",
                                subcategory = "all",
                                itemName    = impName .. " site",
                                key         = "rec:work:" .. i,
                                data        = { kind = "work", eImp = best },
                            };
                        end
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
