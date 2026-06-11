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
    return out;
end

function ScannerBackendRecommendations.ValidateEntry(entry, _cursorPlotHint)
    if Map == nil or Map.GetPlotByIndex == nil then return false; end
    return Map.GetPlotByIndex(entry.plotIndex) ~= nil;
end

function ScannerBackendRecommendations.FormatName(entry)
    -- Keep the collapse key clean ("City site"); the engine's reason rides in
    -- entry.data.reason for a richer announce / detail readout later.
    return entry.itemName or "recommendation";
end

Scanner.registerBackend(ScannerBackendRecommendations);

Log.info("ScannerBackendRecommendations.lua: loaded");
