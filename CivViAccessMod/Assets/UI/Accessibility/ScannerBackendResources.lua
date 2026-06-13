-- ScannerBackendResources.lua — scanner backend for RESOURCES. Walks revealed
-- plots, emits each visible resource under its class subcategory (strategic /
-- luxury / bonus). Resources persist through fog (you remember what you've seen),
-- so the gate is IsRevealed, not IsVisible. Ported from Civ V Access's resources
-- backend onto Civ VI's API (GameInfo.Resources[idx].ResourceClassType).
--
-- itemName = resource name ("Iron", "Wheat") so deposits collapse into one item
-- with N instances → "nearest Iron, 3 northeast, 1 of 5".

include("Log");
include("ScannerCore");

ScannerBackendResources = { name = "resources" };

local CLASS_SUB = {
    RESOURCECLASS_STRATEGIC = "strategic",
    RESOURCECLASS_LUXURY    = "luxury",
    RESOURCECLASS_BONUS     = "bonus",
    -- ARTIFACT / LEY / OTHER deliberately unmapped — not scanner targets.
};

local function localPlayerId()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

local function plotCount()
    if Map == nil then return 0; end
    if Map.GetPlotCount ~= nil then return Map.GetPlotCount(); end
    if Map.GetNumPlots ~= nil then return Map.GetNumPlots(); end   -- older API name
    return 0;
end

local function revealed(vis, x, y)
    if vis == nil or vis.IsRevealed == nil then return true; end
    local ok, r = pcall(function() return vis:IsRevealed(x, y); end);
    return (not ok) or (r == true);
end

-- Tech-reveal gate (Noel 2026-06-12: the scanner listed Coal and Aluminum in
-- the ANCIENT era — sighted players can't see a strategic resource until its
-- reveal tech, and neither should we; the tile readout already gates via the
-- same check). playerResources:IsResourceVisible(hash), per the engine
-- PlotToolTip. Fail-open only if the API is missing entirely.
local function resourceKnown(playerResources, row)
    if playerResources == nil or playerResources.IsResourceVisible == nil then return true; end
    local ok, visible = pcall(function() return playerResources:IsResourceVisible(row.Hash); end);
    return ok and visible == true;
end

function ScannerBackendResources.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 then return out; end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    local playerResources = nil;
    pcall(function() playerResources = Players[localId]:GetResources(); end);

    local n = plotCount();
    for i = 0, n - 1 do
        local plot = Map.GetPlotByIndex(i);
        if plot ~= nil then
            local resId = plot:GetResourceType();
            if resId ~= nil and resId >= 0 and revealed(vis, plot:GetX(), plot:GetY()) then
                local row = GameInfo.Resources[resId];
                if row ~= nil and not resourceKnown(playerResources, row) then row = nil; end
                if row ~= nil then
                    local sub = CLASS_SUB[row.ResourceClassType];
                    if sub ~= nil then
                        out[#out + 1] = {
                            plotIndex   = i,
                            category    = "resources",
                            subcategory = sub,
                            itemName    = Locale.Lookup(row.Name),
                            key         = "resource:" .. i,
                            data        = { resId = resId },
                        };
                    end
                end
            end
        end
    end
    return out;
end

function ScannerBackendResources.ValidateEntry(entry, _cursorPlotHint)
    if Map == nil or Map.GetPlotByIndex == nil then return false; end
    local plot = Map.GetPlotByIndex(entry.plotIndex);
    if plot == nil then return false; end
    local localId = localPlayerId();
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    if not revealed(vis, plot:GetX(), plot:GetY()) then return false; end
    if plot:GetResourceType() ~= entry.data.resId then return false; end
    local playerResources = nil;
    pcall(function() playerResources = Players[localId]:GetResources(); end);
    local row = GameInfo.Resources[entry.data.resId];
    return row ~= nil and resourceKnown(playerResources, row);
end

function ScannerBackendResources.FormatName(entry)
    return entry.itemName or "resource";
end

Scanner.registerBackend(ScannerBackendResources);

Log.info("ScannerBackendResources.lua: loaded");
