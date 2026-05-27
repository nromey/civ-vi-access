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

-- First-turn orientation state. We fire the rich announce only once
-- per game session — the FIRST own-unit selection event during the
-- first game turn. After that, subsequent selections (even on turn 1,
-- e.g. Tab to the Warrior) fall through to the existing terse
-- announce per feedback_terse_announce_default.
local _firstTurnAnnounceDone = false;

-- Don't fire the first-turn orientation announce until the loading
-- screen has actually closed. Round-5 log showed UnitSelectionChanged
-- firing inside OnLoadGameViewStateDone (BEFORE LoadScreenClose),
-- which kicked off the orientation announce while the briefing was
-- still in Tolk's queue — interrupting it with position info. Subscribe
-- to LoadScreenClose to flip this flag; defer any orientation queued
-- before then.
local _loadScreenClosed = false;
local _pendingFirstTurn = nil;  -- { pUnit, hexI, hexJ } if queued

-- Coarse latitude-band region descriptor based on the unit's Y
-- coordinate relative to map height. Civ VI's start-bias system has
-- richer region tags internally but they're not exposed in Lua;
-- latitude bands give the player a usable orientation cue without
-- depending on private engine APIs.
local function coarseRegionDescriptor(hexJ)
    if hexJ == nil or Map == nil or Map.GetGridSize == nil then
        return nil;
    end
    local _, gridHeight = Map.GetGridSize();
    if gridHeight == nil or gridHeight <= 0 then
        return nil;
    end
    local latPct = hexJ / gridHeight;  -- 0=south pole, 1=north pole
    if latPct < 0.20 or latPct > 0.80 then
        return Locale.Lookup("LOC_CIVVIACCESS_REGION_POLAR");
    elseif latPct < 0.35 or latPct > 0.65 then
        return Locale.Lookup("LOC_CIVVIACCESS_REGION_TEMPERATE");
    elseif latPct < 0.45 or latPct > 0.55 then
        return Locale.Lookup("LOC_CIVVIACCESS_REGION_SUBTROPICAL");
    else
        return Locale.Lookup("LOC_CIVVIACCESS_REGION_TROPICAL");
    end
end

-- Collect visible resources / features on hexes within 2 rings of
-- the unit. Returns a list of "RESOURCE direction" strings ready to
-- join with commas. Empty list when nothing notable is visible.
local function nearbyVisibleFeatures(hexI, hexJ)
    local items = {};
    local seen = {};  -- dedupe by (resourceType, direction) for ring 2 overlap
    if Map == nil or Map.GetAdjacentPlot == nil then
        return items;
    end
    for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
        local plot = Map.GetAdjacentPlot(hexI, hexJ, direction);
        if plot ~= nil then
            local resource = ResourceName(plot);
            if resource ~= "" then
                local key = resource .. "@" .. direction;
                if not seen[key] then
                    seen[key] = true;
                    table.insert(items,
                        resource .. " " .. GetLocalizedDirectionString(direction));
                end
            end
        end
    end
    return items;
end

-- Build the multi-line first-turn orientation announce. Returns a
-- list of strings (one per spoken line) so the caller can queue them
-- independently. Empty list aborts to the terse path.
local function firstTurnOrientationLines(pUnit, hexI, hexJ)
    if pUnit == nil then return {}; end

    local lines = {};
    local plot = Map.GetPlot(hexI, hexJ);
    local terrain = TerrainName(plot);
    local feature = FeatureName(plot);
    local unitName = unitDisplayName(pUnit);

    -- Line 1: unit + terrain (+ feature if any)
    local terrainPhrase = terrain;
    if feature ~= "" then
        terrainPhrase = terrain .. " with " .. feature;
    end
    table.insert(lines,
        Locale.Lookup("LOC_CIVVIACCESS_FIRST_TURN_UNIT_FORMAT",
                      unitName, terrainPhrase));

    -- Line 2: movement points
    if pUnit.GetMovesRemaining ~= nil then
        local ok, moves = pcall(function() return pUnit:GetMovesRemaining(); end);
        if ok and moves ~= nil then
            table.insert(lines,
                Locale.Lookup("LOC_CIVVIACCESS_MOVES_REMAINING_FORMAT",
                              moves));
        end
    end

    -- Line 3: region
    local region = coarseRegionDescriptor(hexJ);
    if region ~= nil then
        table.insert(lines, region .. ".");
    end

    -- Line 4: visible nearby resources (if any)
    local features = nearbyVisibleFeatures(hexI, hexJ);
    if #features > 0 then
        table.insert(lines,
            Locale.Lookup("LOC_CIVVIACCESS_FIRST_TURN_VISIBLE_NEARBY",
                          table.concat(features, ", ")));
    end

    -- Line 5: adjacency POIs from the existing helper (units + cities)
    local pois = GetAdjacentPointsOfInterestFrom(hexI, hexJ);
    local poiLine = TurnPointsOfInterestIntoString(pois);
    if poiLine ~= nil then
        table.insert(lines, poiLine);
    end

    -- Line 6: nav hint
    table.insert(lines,
        Locale.Lookup("LOC_CIVVIACCESS_FIRST_TURN_NAV_HINT"));

    return lines;
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

    -- First-turn orientation: fire ONCE on the first own-unit
    -- selection during the first game turn, AND only after the load
    -- screen has closed (so the briefing finishes uninterrupted).
    -- If selection fires before LoadScreenClose, queue it; the
    -- LoadScreenClose handler will replay.
    if not _firstTurnAnnounceDone
       and Game ~= nil and GameConfiguration ~= nil
       and Game.GetCurrentGameTurn() == GameConfiguration.GetStartTurn() then
        if not _loadScreenClosed then
            _pendingFirstTurn = { pUnit = pUnit, hexI = hexI, hexJ = hexJ };
            return;  -- defer until LoadScreenClose
        end
        _firstTurnAnnounceDone = true;
        local lines = firstTurnOrientationLines(pUnit, hexI, hexJ);
        if #lines > 0 then
            -- Lead is the unit-selection announce; subsequent lines
            -- queue behind it as status (never interrupt, never
            -- coalesce — multi-line briefing must speak all parts).
            Speech.emit(lines[1], "selection");
            for i = 2, #lines do
                Speech.emit(lines[i], "status");
            end
            return;
        end
    end

    Speech.emit(ownUnitAnnouncement(pUnit), "selection");

    local pois = GetAdjacentPointsOfInterestFrom(hexI, hexJ);
    local line = TurnPointsOfInterestIntoString(pois);
    if line ~= nil then
        Speech.emit(line, "status");
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
    Speech.emit(name .. " (" .. popLabel .. " " .. population .. ")", "selection");
end

-- Notification announcement moved to Notifications.lua (0.5.1) —
-- it grew dedup, debounce, turn-start hold, and an arrival earcon,
-- which warranted its own module ahead of Stage 2's notifications
-- center.

-- Drain any pending first-turn orientation queued by a Settler-
-- selection event that fired during the loading screen window.
local function flushPendingFirstTurn()
    if _pendingFirstTurn ~= nil and not _firstTurnAnnounceDone then
        local q = _pendingFirstTurn;
        _pendingFirstTurn = nil;
        _firstTurnAnnounceDone = true;
        local lines = firstTurnOrientationLines(q.pUnit, q.hexI, q.hexJ);
        if #lines > 0 then
            Speech.emit(lines[1], "selection");
            for i = 2, #lines do
                Speech.emit(lines[i], "status");
            end
        end
    end
end

local function OnLoadScreenClose()
    _loadScreenClosed = true;
    flushPendingFirstTurn();
end

-- Backstop for OnLoadScreenClose. As of 2026-05-26, LoadScreenClose
-- is silent on Noel's build for new games (HexCursor + SREH both
-- subscribe but the event never fires). Without this safety net, the
-- gate above keeps queueing UnitSelectionChanged events forever and
-- ownUnitAnnouncement never speaks — every unit cycle ends silently.
-- LocalPlayerTurnBegin is reliable across new-game and load-game per
-- the Lua.log, so we use it as the alternate trigger to mark load
-- done. Earliest it fires is just after the first turn's orientation
-- moment, so this doesn't preempt the briefing flow on a healthy load.
local function OnLocalPlayerTurnBeginBackstop()
    if not _loadScreenClosed then
        _loadScreenClosed = true;
        flushPendingFirstTurn();
    end
end

-- Task G — founded-city speech. Engine fires Events.CityAddedToMap
-- when a city is created (Settler founds, raze undone, etc.). Without
-- our handler, B-to-found gives no audible confirmation beyond the
-- generic "Found city" action announce and a notification chime; the
-- user has no idea the city was actually placed, what it's named, or
-- what to do next.
--
-- Speech composition:
--   "City of [name] founded at [x, y]. Population [N]. Press Shift+P
--    to choose production."
--
-- The Shift+P hint front-loads the next action so users don't have to
-- guess. When the production picker entry-point moves to notification
-- activation in a future stage, swap this hint for the appropriate
-- guidance ("press bracket to cycle to the production notification,
-- enter to choose").
local function OnCityAddedToMap(playerID, cityID, x, y)
    if Game == nil or playerID ~= Game.GetLocalPlayer() then return; end
    local pPlayer = Players[playerID];
    if pPlayer == nil then return; end
    local pCities = pPlayer:GetCities();
    if pCities == nil then return; end
    local pCity = pCities:FindID(cityID);
    if pCity == nil then return; end

    local name = Locale.Lookup(pCity:GetName());
    local pop  = pCity:GetPopulation() or 1;

    local parts = {};
    parts[#parts + 1] = "City of " .. name .. " founded at " .. tostring(x) .. ", " .. tostring(y);
    parts[#parts + 1] = "Population " .. tostring(pop);
    -- After founding, engine fires CHOOSE_CITY_PRODUCTION as a
    -- notification (NOT a modal — there's nothing to dismiss with
    -- Enter). The blocker stays active until production is picked,
    -- so the turn can't end. Tell user directly: Shift+P opens our
    -- picker, Alt+P auto-picks the cheapest defaults across all
    -- empty blockers (production, research, civic) in one keystroke.
    parts[#parts + 1] = "Press Shift+P to choose production, or Alt+P to auto-pick";
    -- critical kind: this is a major game-state change. Its 2000ms
    -- shield protects against the engine auto-selecting another unit
    -- (firing UnitSelectionChanged → "Warrior" selection announce)
    -- which previously clobbered this line mid-word. Selection-tier
    -- emits inside the shield window downgrade to NOINTERRUPT and
    -- queue behind this announce instead.
    Speech.emit(table.concat(parts, ". ") .. ".", "critical");
end

local function Initialize()
    print("[CivViAccess][INFO ] ScreenReaderEventHandlers.lua: file loaded, Initialize starting");
    print("[CivViAccess][INFO ] ScreenReaderEventHandlers: Events="
          .. tostring(Events) .. " Game=" .. tostring(Game)
          .. " Players=" .. tostring(Players) .. " Map=" .. tostring(Map));
    Events.UnitSelectionChanged.Add(OnUnitSelectionChanged);
    Events.CitySelectionChanged.Add(OnCitySelectionChanged);
    Events.LoadScreenClose.Add(OnLoadScreenClose);
    if Events.LocalPlayerTurnBegin ~= nil then
        Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBeginBackstop);
    end
    if Events.CityAddedToMap ~= nil then
        Events.CityAddedToMap.Add(OnCityAddedToMap);
    end
    print("[CivViAccess][INFO ] ScreenReaderEventHandlers: subscriptions complete");
end

Initialize();
