-- In-game gameplay-script event handlers for screen-reader announcements.
--
-- Listed under <AddGameplayScripts> in CivViAccessMod.modinfo so it runs
-- once per game session inside the in-game Lua context (where the Game,
-- Players, Map, Units, and Cities APIs are reachable). The frontend context
-- never loads this file — there are no units to announce in the main menu.
--
-- Two engine events are wired:
--
--   Events.UnitSelectionChanged: when the local player selects one of their
--     own units, announce the unit's localized name (interrupting any
--     in-flight speech because this is a direct response to a click /
--     keypress). Then enumerate the six adjacent hexes and queue a follow-up
--     line listing any units or cities found there, with their direction
--     relative to the selected unit. The follow-up is queued (non-
--     interrupting) so the primary unit announce isn't truncated mid-word.
--
--   Events.CitySelectionChanged: when the local player selects one of their
--     own cities, announce its name and population. Adjacent-plot
--     enumeration deliberately is not wired here — adjacency on a city tile
--     is dominated by the city's own work-radius tiles, which is not the
--     same context as unit adjacency.

include("ScreenReader");
include("ScreenReaderPlotUtils");

local function unitDisplayName(unit)
    local unitInfo = GameInfo.Units[unit:GetType()];
    if unitInfo == nil then
        return "";
    end
    return Locale.Lookup(unitInfo.Name);
end

-- True if the unit has any damage at all. Inline rather than imported
-- from ScreenReaderPlotUtils because it's three lines and we don't need
-- a global API surface for it. pcall-guards GetDamage in case it returns
-- nil mid-destruction.
local function unitIsDamaged(unit)
    if unit == nil or unit.GetDamage == nil then
        return false;
    end
    local ok, damage = pcall(function() return unit:GetDamage(); end);
    return ok and damage ~= nil and damage > 0;
end

-- Compose the player's-own-unit announcement: unit name plus a damaged
-- suffix when applicable. No civilization adjective — the player knows
-- it's theirs because they just selected it.
local function ownUnitAnnouncement(unit)
    local name = unitDisplayName(unit);
    if name == "" or not unitIsDamaged(unit) then
        return name;
    end
    return Locale.Lookup("LOC_CIVVIACCESS_UNIT_DAMAGED", name);
end

-- Collect every unit and city sitting on a hex adjacent to (hexX, hexY).
-- Civ VI's DirectionTypes.NUM_DIRECTION_TYPES on a pointy-top hex map is 6,
-- so this iterates the six real neighbors. Map.GetAdjacentPlot returns nil
-- for off-map directions (edge of the world); we skip those.
function GetAdjacentPointsOfInterestFrom(hexX :number, hexY :number)
    local units  = {};
    local cities = {};

    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(hexX, hexY, direction);
        if plot ~= nil then
            for _, unit in ipairs(Units.GetUnitsInPlot(plot)) do
                table.insert(units, { unit = unit, direction = direction });
            end
            local city = Cities.GetCityInPlot(plot);
            if city ~= nil then
                table.insert(cities, { city = city, direction = direction });
            end
        end
    end

    return { units = units, cities = cities };
end

-- Render an adjacency table (from GetAdjacentPointsOfInterestFrom) as a
-- single string ready for OutputMessageToScreenReader. Returns nil when the
-- table is empty so the caller can suppress the line entirely rather than
-- speaking an empty announce.
function TurnPointsOfInterestIntoString(iPois :table)
    local lines = {};

    for _, entry in ipairs(iPois.units) do
        local line = StringifyUnit(entry.unit)
            .. " " .. GetLocalizedDirectionString(entry.direction);
        table.insert(lines, line);
    end

    for _, entry in ipairs(iPois.cities) do
        local line = StringifyCity(entry.city)
            .. " " .. GetLocalizedDirectionString(entry.direction);
        table.insert(lines, line);
    end

    if #lines == 0 then
        return nil;
    end
    return table.concat(lines, "[NEWLINE]");
end

function OnUnitSelectionChanged(playerID :number, unitID :number,
                                 hexI :number, hexJ :number, hexK :number,
                                 isSelected :boolean, isEditable :boolean)
    if playerID ~= Game.GetLocalPlayer() or not isSelected then
        return;
    end

    local pUnit = Players[playerID]:GetUnits():FindID(unitID);
    if pUnit == nil then
        return;
    end

    OutputMessageToScreenReader(ownUnitAnnouncement(pUnit));

    local pois = GetAdjacentPointsOfInterestFrom(hexI, hexJ);
    local line = TurnPointsOfInterestIntoString(pois);
    if line ~= nil then
        OutputMessageToScreenReader(line, true);
    end
end

function OnCitySelectionChanged(owner :number, cityID :number,
                                 i :number, j :number, k :number,
                                 isSelected :boolean, isEditable :boolean)
    if owner ~= Game.GetLocalPlayer() or not isSelected then
        return;
    end

    local pCity = Players[owner]:GetCities():FindID(cityID);
    if pCity == nil then
        return;
    end

    local name       = Locale.Lookup(pCity:GetName());
    local population = pCity:GetPopulation();
    local popLabel   = Locale.Lookup("LOC_HUD_CITY_POPULATION");
    OutputMessageToScreenReader(name .. " (" .. popLabel .. " " .. population .. ")");
end

local function Initialize()
    print("Initializing screen reader event handlers");
    Events.UnitSelectionChanged.Add(OnUnitSelectionChanged);
    Events.CitySelectionChanged.Add(OnCitySelectionChanged);
end

Initialize();
