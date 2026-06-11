-- ScannerBackendUnits.lua — scanner backend for UNITS. Walks every player's
-- units, gates foreign units on current visibility (you only "see" enemy/other
-- units on tiles you can see right now), and classifies each into the units
-- taxonomy subcategory by relationship to the local player. Doubles as the data
-- source the combat/threat-awareness work reads (enemy sub = barbarians + civs
-- at war). Ported in spirit from Civ V Access's ScannerBackendUnits, on Civ VI's
-- API.
--
-- Subcategories (must match ScannerCore taxonomy "units"): mine / allied /
-- neutral / enemy. The implicit "all" aggregates them.
--   itemName  = unit TYPE name ("Warrior") so same-type units collapse into one
--               item with N instances; the subcategory already separates owners.
--   FormatName = StringifyUnit (live, decorated: civ adjective + name + enemy /
--               allied / damaged) — the full spoken name at announce time.
--   key       = "unit:<owner>:<id>" — stable identity per unit across rebuilds.

include("Log");
include("ScannerCore");
include("ScreenReaderPlotUtils");   -- StringifyUnit

ScannerBackendUnits = { name = "units" };

local function localPlayerId()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

-- Relationship of `ownerId` to the local player → subcategory key.
local function relationshipSub(localId, ownerId, localDiplo)
    if ownerId == localId then return "mine"; end
    -- Barbarians are always hostile but not a formal diplomatic "war", so
    -- IsAtWarWith misses them and they'd fall to "neutral". Classify by
    -- IsBarbarian so they land in "enemy", where threat-awareness and a blind
    -- player both expect them (Noel 2026-06-11).
    local owner = Players and Players[ownerId] or nil;
    if owner ~= nil and owner.IsBarbarian ~= nil then
        local ok, isBarb = pcall(function() return owner:IsBarbarian(); end);
        if ok and isBarb == true then return "enemy"; end
    end
    if localDiplo ~= nil then
        if localDiplo.IsAtWarWith ~= nil then
            local ok, atWar = pcall(function() return localDiplo:IsAtWarWith(ownerId); end);
            if ok and atWar == true then return "enemy"; end
        end
        if localDiplo.HasAllianceWith ~= nil then
            local ok, allied = pcall(function() return localDiplo:HasAllianceWith(ownerId); end);
            if ok and allied == true then return "allied"; end
        end
    end
    return "neutral";
end

-- A foreign unit is scannable only on a tile the local player can currently SEE
-- (units aren't remembered through fog the way terrain is). Own units always.
local function isUnitScannable(localId, ownerId, x, y)
    if ownerId == localId then return true; end
    if PlayersVisibility == nil or PlayersVisibility[localId] == nil then return false; end
    local vis = PlayersVisibility[localId];
    if vis.IsVisible == nil then return false; end
    local ok, visible = pcall(function() return vis:IsVisible(x, y); end);
    return ok and visible == true;
end

local function plotIndexAt(x, y)
    if Map == nil or Map.GetPlot == nil then return nil; end
    local plot = nil;
    pcall(function() plot = Map.GetPlot(x, y); end);
    if plot == nil then return nil; end
    local ok, idx = pcall(function() return plot:GetIndex(); end);
    return (ok and idx ~= nil) and idx or nil;
end

function ScannerBackendUnits.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 or Players == nil then return out; end
    local localDiplo = nil;
    if Players[localId] ~= nil and Players[localId].GetDiplomacy ~= nil then
        pcall(function() localDiplo = Players[localId]:GetDiplomacy(); end);
    end

    local maxPlayers = (GameDefines and GameDefines.MAX_PLAYERS) or 64;
    for pid = 0, maxPlayers - 1 do
        local player = Players[pid];
        if player ~= nil and player.GetUnits ~= nil then
            local units = player:GetUnits();
            if units ~= nil then
                for _, unit in units:Members() do
                    if unit ~= nil then
                        local x, y = unit:GetX(), unit:GetY();
                        if x ~= nil and isUnitScannable(localId, pid, x, y) then
                            local plotIndex = plotIndexAt(x, y);
                            if plotIndex ~= nil then
                                local sub = relationshipSub(localId, pid, localDiplo);
                                local typeName = Locale.Lookup(unit:GetName());
                                out[#out + 1] = {
                                    plotIndex   = plotIndex,
                                    category    = "units",
                                    subcategory = sub,
                                    itemName    = typeName,
                                    key         = "unit:" .. pid .. ":" .. unit:GetID(),
                                    data        = { owner = pid, unitId = unit:GetID() },
                                };
                            end
                        end
                    end
                end
            end
        end
    end
    return out;
end

-- Still alive, owned by the same player, and (for foreign units) still in sight.
function ScannerBackendUnits.ValidateEntry(entry, _cursorPlotHint)
    if Players == nil or entry.data == nil then return false; end
    local owner = entry.data.owner;
    local player = Players[owner];
    if player == nil or player.GetUnits == nil then return false; end
    local unit = nil;
    pcall(function() unit = player:GetUnits():FindID(entry.data.unitId); end);
    if unit == nil then return false; end
    local x, y = unit:GetX(), unit:GetY();
    if x == nil then return false; end
    local localId = localPlayerId();
    if not isUnitScannable(localId, owner, x, y) then return false; end
    -- Refresh the plot in case the unit moved since the snapshot was built.
    local idx = plotIndexAt(x, y);
    if idx ~= nil then entry.plotIndex = idx; end
    return true;
end

-- Live, fully-decorated spoken name (civ adjective + name + enemy/allied/damaged).
function ScannerBackendUnits.FormatName(entry)
    if Players ~= nil and entry.data ~= nil then
        local player = Players[entry.data.owner];
        if player ~= nil and player.GetUnits ~= nil then
            local unit = nil;
            pcall(function() unit = player:GetUnits():FindID(entry.data.unitId); end);
            if unit ~= nil then
                local name = StringifyUnit(unit);
                if name ~= nil and name ~= "" then return name; end
            end
        end
    end
    return entry.itemName or "unit";
end

Scanner.registerBackend(ScannerBackendUnits);

Log.info("ScannerBackendUnits.lua: loaded");
