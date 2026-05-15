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
