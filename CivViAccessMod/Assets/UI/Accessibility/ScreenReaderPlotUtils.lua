-- Plot / unit / city stringification helpers for screen-reader speech.
--
-- Three exports, all global so `include("ScreenReaderPlotUtils")` is enough
-- to use them:
--
--   GetLocalizedDirectionString(direction) -> string
--     Maps a Civ VI DirectionTypes enum value to the engine's localized
--     direction name (LOC_DIRECTION_*). Civ VI uses pointy-top hexes —
--     six neighbors, no true north / south — so the map covers NE, E, SE,
--     NW, W, SW only. Any other direction value returns "".
--
--   StringifyUnit(unit) -> string
--     "{civilization adjective} {unit name}", e.g. "American Warrior".
--     Uses civilization description (the adjective form Firaxis ships in
--     PlayerConfigurations) rather than leader name so AI / barbarian /
--     city-state units read naturally.
--
--   StringifyCity(city) -> string
--     "{civilization adjective} city {city name}", e.g. "American city
--     Boston". LOC_CITY_NAME_BLANK supplies the localized "city" word so
--     translated builds read correctly in their target language.
--
--   PlotEntryCost(plot) -> number | nil
--     Effective MP cost to ENTER the plot, nil if impassable.

include("ScreenReader");

-- Pointy-top hex neighbors only. The four "Civ VI doesn't have these"
-- directions (NORTH, SOUTH, and any diagonal not in the six) deliberately
-- aren't in the map — they'll fall through to the empty-string return.
local DIRECTION_TO_LOC_SUFFIX = {
    [DirectionTypes.DIRECTION_NORTHEAST] = "NORTH_EAST",
    [DirectionTypes.DIRECTION_EAST]      = "EAST",
    [DirectionTypes.DIRECTION_SOUTHEAST] = "SOUTH_EAST",
    [DirectionTypes.DIRECTION_SOUTHWEST] = "SOUTH_WEST",
    [DirectionTypes.DIRECTION_WEST]      = "WEST",
    [DirectionTypes.DIRECTION_NORTHWEST] = "NORTH_WEST",
};

function GetLocalizedDirectionString(direction)
    local suffix = DIRECTION_TO_LOC_SUFFIX[direction];
    if suffix == nil then
        return "";
    end
    return Locale.Lookup("LOC_DIRECTION_" .. suffix);
end

local function civilizationAdjective(ownerId)
    local config = PlayerConfigurations[ownerId];
    if config == nil then
        return "";
    end
    return Locale.Lookup(config:GetCivilizationDescription());
end

-- Wraps a unit/city description with a relationship prefix when the
-- ownership relationship is non-default. Peace (the dominant case
-- between any two civs that have met) is deliberately unmarked — saying
-- "peaceful French Warrior" on every announce gets noisy fast. Self /
-- Enemy / Allied get LOC-wrapped so translators can adjust word order
-- and grammar per language.
--
-- pcall-guarded around the diplomacy calls because (a) some run contexts
-- (UI vs gameplay) may not expose them, (b) edge cases during turn
-- transitions can return nil mid-query. Failure of any individual check
-- silently falls through to "no decoration" — safe default.
local function decorateWithRelationship(description, ownerId)
    if description == "" or ownerId == nil or ownerId < 0 then
        return description;
    end
    local localPlayer = -1;
    if Game ~= nil and Game.GetLocalPlayer ~= nil then
        local ok, lp = pcall(Game.GetLocalPlayer);
        if ok and lp ~= nil then localPlayer = lp; end
    end
    if localPlayer < 0 then
        return description;
    end
    if ownerId == localPlayer then
        return Locale.Lookup("LOC_CIVVIACCESS_REL_SELF", description);
    end
    if Players == nil or Players[localPlayer] == nil then
        return description;
    end
    local diplo = nil;
    local ok = pcall(function() diplo = Players[localPlayer]:GetDiplomacy(); end);
    if not ok or diplo == nil then
        return description;
    end
    if diplo.IsAtWarWith ~= nil then
        local atWarOk, atWar = pcall(function() return diplo:IsAtWarWith(ownerId); end);
        if atWarOk and atWar == true then
            return Locale.Lookup("LOC_CIVVIACCESS_REL_ENEMY", description);
        end
    end
    if diplo.HasAllianceWith ~= nil then
        local allyOk, allied = pcall(function() return diplo:HasAllianceWith(ownerId); end);
        if allyOk and allied == true then
            return Locale.Lookup("LOC_CIVVIACCESS_REL_ALLIED", description);
        end
    end
    return description;
end

-- True if the unit has taken any damage at all. We don't bother with a
-- percentage threshold — "damaged" surfaces the existence of the
-- condition; the user can investigate further if they want details.
-- pcall-guarded because GetDamage can return nil on units mid-destruction.
local function isUnitDamaged(unit)
    if unit == nil or unit.GetDamage == nil then
        return false;
    end
    local ok, damage = pcall(function() return unit:GetDamage(); end);
    if not ok or damage == nil then
        return false;
    end
    return damage > 0;
end

function StringifyUnit(unit)
    if unit == nil then
        return "";
    end
    local ownerId   = unit:GetOwner();
    local adjective = civilizationAdjective(ownerId);
    local name      = Locale.Lookup(unit:GetName());
    local base      = (adjective ~= "") and (adjective .. " " .. name) or name;
    local decorated = decorateWithRelationship(base, ownerId);
    if isUnitDamaged(unit) then
        decorated = Locale.Lookup("LOC_CIVVIACCESS_UNIT_DAMAGED", decorated);
    end
    -- En-route status (Noel 2026-06-09): an OWN unit auto-moving to a queued
    -- destination reads "... moving to <dir>, at <x, y>" so a unit
    -- walking over several turns isn't silent in the scanner / selection readouts.
    -- Own units only — we don't (and shouldn't) see a foreign unit's orders.
    -- Guarded: HexGeom may be absent in some VMs; falls back to coords.
    local localPlayer = (Game ~= nil and Game.GetLocalPlayer) and Game.GetLocalPlayer() or -1;
    if ownerId == localPlayer and UnitManager ~= nil and UnitManager.GetQueuedDestination ~= nil then
        local okDest, destId = pcall(function() return UnitManager.GetQueuedDestination(unit); end);
        if okDest and destId ~= nil and Map ~= nil and Map.GetPlotByIndex ~= nil then
            local dest = Map.GetPlotByIndex(destId);
            if dest ~= nil then
                local dx, dy = dest:GetX(), dest:GetY();
                local coords = (HexGeom ~= nil and HexGeom.absoluteCoords)
                               and HexGeom.absoluteCoords(dx, dy) or (dx .. ", " .. dy);
                local where = nil;
                if HexGeom ~= nil and HexGeom.directionString then
                    -- directionString carries the distance itself (hex decomposition,
                    -- or the "<dir>, N hexes" LOC phrase) — appending it here doubled
                    -- it: "moving to 1 southeast, 1 hexes" (Lua.log 2026-06-11).
                    where = HexGeom.directionString(unit:GetX(), unit:GetY(), dx, dy);
                end
                decorated = decorated .. ", moving to "
                            .. (where ~= nil and (where .. ", at " .. coords) or coords);
            end
        end
    end
    return decorated;
end

function StringifyCity(city)
    if city == nil then
        return "";
    end
    local ownerId   = city:GetOwner();
    local adjective = civilizationAdjective(ownerId);
    local cityWord  = Locale.Lookup("LOC_CITY_NAME_BLANK");
    local name      = Locale.Lookup(city:GetName());
    local base;
    if adjective == "" then
        base = cityWord .. " " .. name;
    else
        base = adjective .. " " .. cityWord .. " " .. name;
    end
    return decorateWithRelationship(base, ownerId);
end

-- Terrain / feature / resource stringification for plot inspection.
-- Mirrors HexCursor.lua's local helpers, lifted to ScreenReaderPlotUtils
-- so both UI and gameplay-script contexts can use the same canonical
-- naming. HexCursor's locals will eventually fold into these.

function TerrainName(plot)
    if plot == nil then return ""; end
    if plot:IsLake() then
        return Locale.Lookup("LOC_TOOLTIP_LAKE");
    end
    local terrainIdx = plot:GetTerrainType();
    local terrainRow = GameInfo.Terrains[terrainIdx];
    if terrainRow == nil then return ""; end
    if terrainRow.TerrainType == "TERRAIN_COAST" then
        return Locale.Lookup("LOC_TOOLTIP_COAST");
    end
    return Locale.Lookup(terrainRow.Name);
end

function FeatureName(plot)
    if plot == nil then return ""; end
    local featureIdx = plot:GetFeatureType();
    if featureIdx == -1 then return ""; end
    local featureRow = GameInfo.Features[featureIdx];
    if featureRow == nil then return ""; end
    return Locale.Lookup(featureRow.Name);
end

-- True if a resource INDEX is visible to the local player — i.e. its revealing
-- tech is researched (or it has no prereq, like bonus/luxury resources).
-- STRATEGIC resources (oil, iron, coal, niter, aluminum, uranium...) are
-- TECH-HIDDEN even on a revealed tile; plot:GetResourceType returns them
-- regardless, so every speech path MUST gate on this or we leak e.g. oil at
-- game start — a resource-level fog-of-war cheat (Noel 2026-06-15). Mirrors the
-- engine's own check (PlotToolTip / WorldViewIconsManager):
-- GetResources():IsResourceVisible(hash). Defaults to TRUE if the API is
-- unavailable (no regression); only a DEFINITIVE false hides the resource.
function ResourceVisibleToLocalPlayer(resourceIdx)
    if resourceIdx == nil or resourceIdx == -1 then return false; end
    local row = GameInfo.Resources[resourceIdx];
    if row == nil or row.Hash == nil then return true; end
    if Game == nil or Game.GetLocalPlayer == nil or Players == nil then return true; end
    local lp = Game.GetLocalPlayer();
    if lp == nil or lp < 0 then return true; end
    local pPlayer = Players[lp];
    if pPlayer == nil or pPlayer.GetResources == nil then return true; end
    local pr = pPlayer:GetResources();
    if pr == nil or pr.IsResourceVisible == nil then return true; end
    local ok, vis = pcall(function() return pr:IsResourceVisible(row.Hash); end);
    if ok and vis == false then return false; end
    return true;
end

function ResourceName(plot)
    if plot == nil then return ""; end
    local resourceIdx = plot:GetResourceType();
    if resourceIdx == -1 then return ""; end
    if not ResourceVisibleToLocalPlayer(resourceIdx) then return ""; end
    local resourceRow = GameInfo.Resources[resourceIdx];
    if resourceRow == nil then return ""; end
    return Locale.Lookup(resourceRow.Name);
end

-- "your territory" / "Scottish territory" / nil for unowned — the spoken form
-- of the border colors sighted players see. Callers decide how to handle nil:
-- the cursor tile announce stays SILENT on unclaimed land (exceptions speak);
-- slash says "in neutral land" explicitly (on-demand readout, and neutral is
-- the case that changes heal behavior).
function TerritoryPhrase(ownerId)
    if ownerId == nil or ownerId == -1 then return nil; end
    local lp = (Game ~= nil and Game.GetLocalPlayer) and Game.GetLocalPlayer() or -1;
    if ownerId == lp then return "your territory"; end
    local adjective = civilizationAdjective(ownerId);
    if adjective ~= "" then return adjective .. " territory"; end
    return "foreign territory";
end

-- Effective MP cost to ENTER the plot, or nil if impassable. Base number is the
-- engine's own per-plot cost (terrain + feature — the same figure the sighted
-- plot tooltip prints). An unpillaged road overrides it with the route's rate
-- (Civ VI roads flatten terrain: ancient road = 1, later eras < 1), so a roaded
-- hill correctly stops costing 2. NOTE (verified live 2026-06-13): GetMovementCost
-- ALSO folds in the river-crossing surcharge (+1 here) — the exits ring's ", river"
-- is an informational flag, NOT an extra cost callers add. Unit-specific modifiers
-- (promotions, embarked state) are NOT applied.
function PlotEntryCost(plot)
    if plot == nil then return nil; end
    local impassable = false;
    pcall(function() impassable = plot:IsImpassable(); end);
    if impassable then return nil; end
    local cost = nil;
    pcall(function() cost = plot:GetMovementCost(); end);
    local routeCost = nil;
    pcall(function()
        if plot:IsRoute() and not plot:IsRoutePillaged() then
            local row = GameInfo.Routes[plot:GetRouteType()];
            routeCost = (row ~= nil) and row.MovementCost or nil;
        end
    end);
    if routeCost ~= nil and (cost == nil or routeCost < cost) then
        return routeCost;
    end
    return cost;
end
