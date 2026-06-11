-- ScannerBackendImprovements.lua — scanner backend for tile IMPROVEMENTS.
-- Walks revealed plots, emits each improved plot under an ownership subcategory
-- (mine / neutral / enemy). Improvements persist through fog (you remember what
-- you've seen), so the gate is IsRevealed, not IsVisible — same as resources.
--
-- itemName = the improvement's name ("Farm", "Mine"). Pillaged improvements get
-- a " (pillaged)" suffix (Noel 2026-06-09) so they read distinctly and stay
-- findable without a separate subcategory; verbosity can layer more detail later.
--
-- Skips: barbarian camps + tribal villages (already surfaced under Cities /
-- Special) and routes (roads/railroads are GetRouteType, not improvements).
--
-- Rich data per entry (entry.data) carries improvementId / pillaged / owner so a
-- future auto-pick / placement-preview layer can read it (see
-- project_placement_preview_vision).

include("Log");
include("ScannerCore");

ScannerBackendImprovements = { name = "improvements" };

-- Improvement TYPE strings handled by other backends — skip here to avoid
-- double-listing. Roads/railroads aren't improvements in Civ VI (routes), so
-- they never show up via GetImprovementType anyway.
local SKIP_TYPE = {
    IMPROVEMENT_BARBARIAN_CAMP = true,   -- Cities / barb_camps
    IMPROVEMENT_GOODY_HUT      = true,   -- Special / goody_huts
};

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

-- mine / enemy / neutral. Unowned plots (owner == -1) and city-state / neutral
-- majors are "neutral"; majors we're at war with are "enemy". (The improvements
-- taxonomy has no allied/city_states bucket — everything non-mine-non-enemy is
-- neutral.)
local function classifyOwner(localId, ownerId, localDiplo)
    if ownerId == nil or ownerId < 0 then return "neutral"; end
    if ownerId == localId then return "mine"; end
    local player = Players and Players[ownerId] or nil;
    if player == nil then return "neutral"; end
    local isMajor = false;
    if player.IsMajor ~= nil then
        local ok, m = pcall(function() return player:IsMajor(); end);
        isMajor = ok and m == true;
    end
    if isMajor and localDiplo ~= nil and localDiplo.IsAtWarWith ~= nil then
        local ok, atWar = pcall(function() return localDiplo:IsAtWarWith(ownerId); end);
        if ok and atWar == true then return "enemy"; end
    end
    return "neutral";
end

local function improvementRow(impId)
    if impId == nil or impId < 0 then return nil; end
    local ok, row = pcall(function() return GameInfo.Improvements[impId]; end);
    return ok and row or nil;
end

function ScannerBackendImprovements.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 then return out; end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    local localDiplo = nil;
    if Players ~= nil and Players[localId] ~= nil and Players[localId].GetDiplomacy ~= nil then
        pcall(function() localDiplo = Players[localId]:GetDiplomacy(); end);
    end

    local n = plotCount();
    for i = 0, n - 1 do
        local plot = Map.GetPlotByIndex(i);
        if plot ~= nil then
            local impId = plot:GetImprovementType();
            if impId ~= nil and impId >= 0 and revealed(vis, plot:GetX(), plot:GetY()) then
                local row = improvementRow(impId);
                if row ~= nil and not SKIP_TYPE[row.ImprovementType] then
                    local pillaged = false;
                    if plot.IsImprovementPillaged ~= nil then
                        local ok, p = pcall(function() return plot:IsImprovementPillaged(); end);
                        pillaged = ok and p == true;
                    end
                    local ownerId = plot:GetOwner();
                    local name = Locale.Lookup(row.Name);
                    if pillaged then name = name .. " (pillaged)"; end
                    out[#out + 1] = {
                        plotIndex   = i,
                        category    = "improvements",
                        subcategory = classifyOwner(localId, ownerId, localDiplo),
                        itemName    = name,
                        key         = "improvement:" .. i,
                        data        = { impId = impId, pillaged = pillaged, owner = ownerId },
                    };
                end
            end
        end
    end
    return out;
end

function ScannerBackendImprovements.ValidateEntry(entry, _cursorPlotHint)
    if Map == nil or Map.GetPlotByIndex == nil or entry.data == nil then return false; end
    local plot = Map.GetPlotByIndex(entry.plotIndex);
    if plot == nil then return false; end
    local localId = localPlayerId();
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    if not revealed(vis, plot:GetX(), plot:GetY()) then return false; end
    return plot:GetImprovementType() == entry.data.impId;
end

function ScannerBackendImprovements.FormatName(entry)
    return entry.itemName or "improvement";
end

Scanner.registerBackend(ScannerBackendImprovements);

Log.info("ScannerBackendImprovements.lua: loaded");
