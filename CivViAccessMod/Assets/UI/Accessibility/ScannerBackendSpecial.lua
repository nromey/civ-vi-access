-- ScannerBackendSpecial.lua — scanner backend for SPECIAL map points: NATURAL
-- WONDERS (features flagged NaturalWonder) and TRIBAL VILLAGES / goody huts
-- (IMPROVEMENT_GOODY_HUT). Both are revealed-gated landmarks you want to find
-- and route back to. Subcategories: natural_wonders / goody_huts.
--
-- itemName = the wonder's name (each wonder unique → 1 instance) / "Tribal
-- village" (huts collapse into one item, nearest-first).

include("Log");
include("ScannerCore");
include("ScreenReaderPlotUtils");   -- FeatureName

ScannerBackendSpecial = { name = "special" };

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

local function isNaturalWonder(plot)
    local fid = plot:GetFeatureType();
    if fid == -1 then return false; end
    local row = GameInfo.Features[fid];
    return row ~= nil and row.NaturalWonder == true;
end

local function isGoodyHut(plot)
    local iid = plot:GetImprovementType();
    if iid == nil or iid < 0 then return false; end
    local row = GameInfo.Improvements[iid];
    return row ~= nil and row.ImprovementType == "IMPROVEMENT_GOODY_HUT";
end

function ScannerBackendSpecial.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 then return out; end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;

    local n = plotCount();
    for i = 0, n - 1 do
        local plot = Map.GetPlotByIndex(i);
        if plot ~= nil and revealed(vis, plot:GetX(), plot:GetY()) then
            if isNaturalWonder(plot) then
                out[#out + 1] = {
                    plotIndex = i, category = "special", subcategory = "natural_wonders",
                    itemName = FeatureName(plot), key = "special:nw:" .. i, data = { kind = "nw" },
                };
            end
            if isGoodyHut(plot) then
                out[#out + 1] = {
                    plotIndex = i, category = "special", subcategory = "goody_huts",
                    itemName = "Tribal village", key = "special:goody:" .. i, data = { kind = "goody" },
                };
            end
        end
    end
    return out;
end

function ScannerBackendSpecial.ValidateEntry(entry, _cursorPlotHint)
    if Map == nil or Map.GetPlotByIndex == nil then return false; end
    local plot = Map.GetPlotByIndex(entry.plotIndex);
    if plot == nil then return false; end
    local localId = localPlayerId();
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    if not revealed(vis, plot:GetX(), plot:GetY()) then return false; end
    local kind = entry.data and entry.data.kind or nil;
    if kind == "nw"    then return isNaturalWonder(plot); end
    if kind == "goody" then return isGoodyHut(plot); end
    return true;
end

function ScannerBackendSpecial.FormatName(entry)
    return entry.itemName or "special";
end

Scanner.registerBackend(ScannerBackendSpecial);

Log.info("ScannerBackendSpecial.lua: loaded");
