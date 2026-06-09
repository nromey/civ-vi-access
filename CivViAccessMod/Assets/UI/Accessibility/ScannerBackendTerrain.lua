-- ScannerBackendTerrain.lua — scanner backend for TERRAIN landmarks. Walks revealed
-- plots and emits the orientation-useful aspects: FEATURES (forest/jungle/oasis…),
-- ELEVATION (hills/mountain), FRESH WATER. One plot can yield several entries (a
-- forested hill by a river → forest + hills + fresh water) — Civ V Access does the
-- same; each subcategory answers a different spatial question.
--
-- BASE terrain (grassland/plains/desert/…) is intentionally NOT emitted in v1: it
-- would add an entry for nearly every revealed plot (thousands late-game) per scan,
-- and "nearest grassland" is rarely actionable. Add it behind a perf pass (cache /
-- scan-on-open) if wanted — the "base" subcategory stays in the taxonomy for it.
--
-- Gate is IsRevealed (terrain is remembered through fog). itemName collapses like
-- terrain ("Forest", "Hills", "Fresh water") so you cycle TYPES, each with N
-- instances nearest-first.

include("Log");
include("ScannerCore");
include("ScreenReaderPlotUtils");   -- FeatureName

ScannerBackendTerrain = { name = "terrain" };

local function localPlayerId()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

local function plotCount()
    if Map == nil then return 0; end
    if Map.GetPlotCount ~= nil then return Map.GetPlotCount(); end
    if Map.GetNumPlots ~= nil then return Map.GetNumPlots(); end
    return 0;
end

local function revealed(vis, x, y)
    if vis == nil or vis.IsRevealed == nil then return true; end
    local ok, r = pcall(function() return vis:IsRevealed(x, y); end);
    return (not ok) or (r == true);
end

local function isHills(plot)
    local idx = plot:GetTerrainType();
    local row = GameInfo.Terrains[idx];
    return row ~= nil and row.TerrainType ~= nil and string.find(row.TerrainType, "HILLS") ~= nil;
end

-- Emit any aspect entries for one plot into `out`.
local function emitPlot(out, i, plot)
    -- Features (forest / jungle / marsh / oasis / floodplains / natural wonders…)
    if plot:GetFeatureType() ~= -1 then
        local name = FeatureName(plot);
        if name ~= "" then
            out[#out + 1] = {
                plotIndex = i, category = "terrain", subcategory = "features",
                itemName = name, key = "terrain:feat:" .. i, data = { aspect = "feature" },
            };
        end
    end
    -- Elevation: mountain first (impassable landmark), else hills.
    if plot.IsMountain ~= nil and plot:IsMountain() then
        out[#out + 1] = {
            plotIndex = i, category = "terrain", subcategory = "elevation",
            itemName = "Mountain", key = "terrain:mtn:" .. i, data = { aspect = "mountain" },
        };
    elseif isHills(plot) then
        out[#out + 1] = {
            plotIndex = i, category = "terrain", subcategory = "elevation",
            itemName = "Hills", key = "terrain:hill:" .. i, data = { aspect = "hills" },
        };
    end
    -- Fresh water (orientation + settle cue).
    if plot.IsFreshWater ~= nil and plot:IsFreshWater() then
        out[#out + 1] = {
            plotIndex = i, category = "terrain", subcategory = "freshwater",
            itemName = "Fresh water", key = "terrain:fw:" .. i, data = { aspect = "freshwater" },
        };
    end
end

function ScannerBackendTerrain.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 then return out; end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;

    local n = plotCount();
    for i = 0, n - 1 do
        local plot = Map.GetPlotByIndex(i);
        if plot ~= nil and revealed(vis, plot:GetX(), plot:GetY()) then
            emitPlot(out, i, plot);
        end
    end
    return out;
end

function ScannerBackendTerrain.ValidateEntry(entry, _cursorPlotHint)
    if Map == nil or Map.GetPlotByIndex == nil then return false; end
    local plot = Map.GetPlotByIndex(entry.plotIndex);
    if plot == nil then return false; end
    local localId = localPlayerId();
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    if not revealed(vis, plot:GetX(), plot:GetY()) then return false; end
    local aspect = entry.data and entry.data.aspect or nil;
    if aspect == "feature"    then return plot:GetFeatureType() ~= -1; end
    if aspect == "mountain"   then return plot.IsMountain ~= nil and plot:IsMountain(); end
    if aspect == "hills"      then return isHills(plot); end
    if aspect == "freshwater" then return plot.IsFreshWater ~= nil and plot:IsFreshWater(); end
    return true;
end

function ScannerBackendTerrain.FormatName(entry)
    -- Features can change (e.g. a chopped forest re-validated away); re-read live.
    if entry.data and entry.data.aspect == "feature" and Map ~= nil and Map.GetPlotByIndex ~= nil then
        local plot = Map.GetPlotByIndex(entry.plotIndex);
        if plot ~= nil then
            local name = FeatureName(plot);
            if name ~= "" then return name; end
        end
    end
    return entry.itemName or "terrain";
end

Scanner.registerBackend(ScannerBackendTerrain);

Log.info("ScannerBackendTerrain.lua: loaded");
