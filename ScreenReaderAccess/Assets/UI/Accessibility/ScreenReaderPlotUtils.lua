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

function StringifyUnit(unit)
    if unit == nil then
        return "";
    end
    local adjective = civilizationAdjective(unit:GetOwner());
    local name      = Locale.Lookup(unit:GetName());
    if adjective == "" then
        return name;
    end
    return adjective .. " " .. name;
end

function StringifyCity(city)
    if city == nil then
        return "";
    end
    local adjective = civilizationAdjective(city:GetOwner());
    local cityWord  = Locale.Lookup("LOC_CITY_NAME_BLANK");
    local name      = Locale.Lookup(city:GetName());
    if adjective == "" then
        return cityWord .. " " .. name;
    end
    return adjective .. " " .. cityWord .. " " .. name;
end
