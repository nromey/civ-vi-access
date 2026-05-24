-- Free-roam tile cursor for blind players. Holds (_x, _y) — never the live
-- plot userdata, since plot handles can outlive their freshness across
-- engine ticks. Re-resolves via Map.GetPlot at every operation.
--
-- Civ VI has no native keyboard hex cursor — arrow keys pan the camera, not
-- a logical hex focus. HexCursor owns that focus end-to-end as module-local
-- state, mirroring Civ V Access's CursorCore pattern.
--
-- Key layout (ported from Civ V Access CivVAccess_BaselineHandler.lua):
--   Q . E      NW . NE
--   A . D   =  W  .  E
--   Z . C      SW . SE
-- Spatial mapping to hex shape on the left side of the keyboard.
-- Laptop-friendly, no numpad needed. S and X are reserved for future
-- layered-info hotkeys (coordinates, combat detail) per
-- [[project-info-hotkeys]].
--
-- This is the first user of HandlerStack + InputRouter. The cursor handler
-- pushes itself onto the stack on init; ? help collects its bindings.

include("Log");
include("ScreenReader");
include("ScreenReaderPlotUtils");
include("HandlerStack");
include("InputRouter");
include("Help");
include("HexGeom");

-- Diagnostic: confirm file load. If Lua.log never shows this line, the
-- file isn't loading at all (modinfo path issue, syntax error, etc.).
Log.info("HexCursor.lua: file loaded");

HexCursor = HexCursor or {};

local _x = nil;
local _y = nil;
local _initialized = false;

local VK_OEM_2 = (Keys ~= nil and Keys.VK_OEM_2) or 191;

-- Civ VI direction names that map to our Q/E/A/D/Z/C keys. Pulled into
-- locals so a typo here is caught at file-load rather than at first
-- keypress.
local DIR_NW = DirectionTypes.DIRECTION_NORTHWEST;
local DIR_NE = DirectionTypes.DIRECTION_NORTHEAST;
local DIR_W  = DirectionTypes.DIRECTION_WEST;
local DIR_E  = DirectionTypes.DIRECTION_EAST;
local DIR_SW = DirectionTypes.DIRECTION_SOUTHWEST;
local DIR_SE = DirectionTypes.DIRECTION_SOUTHEAST;

-- Terrain-name resolution mirrors Firaxis's PlotToolTip View() so the
-- spoken name matches what sighted users see in the engine tooltip.
-- Lake / Coast get special LOC keys; everything else uses the terrain's
-- own Name field.
local function terrainName(plot)
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

local function featureName(plot)
    if plot == nil then return ""; end
    local featureIdx = plot:GetFeatureType();
    if featureIdx == -1 then return ""; end
    local featureRow = GameInfo.Features[featureIdx];
    if featureRow == nil then return ""; end
    return Locale.Lookup(featureRow.Name);
end

local function resourceName(plot)
    if plot == nil then return ""; end
    local resourceIdx = plot:GetResourceType();
    if resourceIdx == -1 then return ""; end
    local resourceRow = GameInfo.Resources[resourceIdx];
    if resourceRow == nil then return ""; end
    -- Visibility gate — don't leak unrevealed strategic resources. Match
    -- PlotToolTip's behavior: only speak the resource if local player has
    -- it visible.
    local localPlayer = Game.GetLocalPlayer();
    if localPlayer == -1 then return ""; end
    local playerResources = Players[localPlayer]:GetResources();
    if playerResources == nil then return ""; end
    if not playerResources:IsResourceVisible(resourceRow.Hash) then return ""; end
    return Locale.Lookup(resourceRow.Name);
end

-- Lean plot announce: terrain + feature + resource + units + city. Skips
-- yields / appeal / continent / defense modifier / movement cost — those
-- live behind Ctrl+T (verbose) per [[feedback-terse-announce-default]].
--
-- Respects fog of war so screen-reader users don't get information
-- advantage over sighted players. Three states (Civ6Common.lua pattern):
--   - Unrevealed (never explored): speak "Unexplored" only
--   - Revealed but not visible (fog of war): terrain/feature/resource
--     only — what player saw last time, no current units/cities
--   - Visible (currently in sight): speak everything as before
local function AnnouncePlot(plot)
    if plot == nil then
        OutputMessageToScreenReader("No plot");
        return;
    end
    local x = plot:GetX();
    local y = plot:GetY();

    -- Visibility gate. PlayersVisibility[localPlayer] gives per-player
    -- fog state. Civ6Common.lua line 115 uses the same pattern.
    local localPlayer = (Game ~= nil and Game.GetLocalPlayer) and Game.GetLocalPlayer() or -1;
    local pVis = (localPlayer >= 0 and PlayersVisibility ~= nil)
                 and PlayersVisibility[localPlayer] or nil;
    local isRevealed = true;
    local isVisible  = true;
    if pVis ~= nil then
        if pVis.IsRevealed ~= nil then
            local ok, r = pcall(function() return pVis:IsRevealed(x, y); end);
            if ok then isRevealed = r; end
        end
        if pVis.IsVisible ~= nil then
            local ok, v = pcall(function() return pVis:IsVisible(x, y); end);
            if ok then isVisible = v; end
        end
    end

    if not isRevealed then
        OutputMessageToScreenReader("Unexplored");
        return;
    end

    local parts = {};
    local terrain = terrainName(plot);
    if terrain ~= "" then parts[#parts + 1] = terrain; end
    local feature = featureName(plot);
    if feature ~= "" then parts[#parts + 1] = feature; end
    local resource = resourceName(plot);
    if resource ~= "" then parts[#parts + 1] = resource; end

    if not isVisible then
        -- Fog of war: speak only the static terrain memory. Current units
        -- and city state could have changed since the player last saw it.
        if #parts == 0 then
            OutputMessageToScreenReader("Unknown");
            return;
        end
        OutputMessageToScreenReader(table.concat(parts, ". ") .. ". Fog of war.");
        return;
    end

    local city = Cities.GetCityInPlot(x, y);
    if city ~= nil then
        parts[#parts + 1] = StringifyCity(city);
    end
    -- MapLayers.ANY so civilian units (Settler, Builder, Trader, etc.)
    -- appear alongside military. GetUnitsInPlot's default layer is
    -- military-only — confirmed via testing 2026-05-24 when cursor on
    -- a Settler's plot announced only "grasslands, rice" and missed
    -- the Settler entirely.
    local units = Units.GetUnitsInPlotLayerID(x, y, MapLayers.ANY);
    if units ~= nil then
        for _, unit in ipairs(units) do
            parts[#parts + 1] = StringifyUnit(unit);
        end
    end

    if #parts == 0 then
        OutputMessageToScreenReader("Unknown");
        return;
    end
    OutputMessageToScreenReader(table.concat(parts, ". "));
end

HexCursor.AnnouncePlot = AnnouncePlot;

local function setCursor(plot)
    if plot == nil then return; end
    _x = plot:GetX();
    _y = plot:GetY();
    -- Pan camera to follow cursor. UI.LookAtPlot is the Civ VI analog of
    -- Civ V Access's UI.LookAt(plot, 0). Cursor IS the camera per the
    -- 0.4.0 design decision.
    if UI ~= nil and UI.LookAtPlot ~= nil then
        UI.LookAtPlot(_x, _y);
    end
end

-- Place the cursor at session start. Tries the player's selected unit
-- first (engine usually auto-selects on session open); falls back to the
-- first owned unit; falls back to the capital city's plot. Logs and
-- returns silently if none are available (game in a pre-settle state we
-- can't anchor on yet).
-- Civ VI units don't expose :GetPlot() the way Civ V's do — we have to
-- resolve via Map.GetPlot(unit:GetX(), unit:GetY()). Same for cities.
local function unitPlot(unit)
    if unit == nil then return nil; end
    local okX, x = pcall(function() return unit:GetX(); end);
    local okY, y = pcall(function() return unit:GetY(); end);
    if not (okX and okY) or x == nil or y == nil then return nil; end
    return Map.GetPlot(x, y);
end

function HexCursor.init()
    Log.info("HexCursor.init: called (already initialized=" .. tostring(_initialized) .. ")");
    if _initialized then return; end
    local localPlayer = Game.GetLocalPlayer();
    Log.info("HexCursor.init: localPlayer=" .. tostring(localPlayer));
    if localPlayer == -1 then
        Log.warn("HexCursor.init: no local player yet");
        return;
    end
    local target = nil;
    if UI ~= nil and UI.GetHeadSelectedUnit ~= nil then
        local unit = UI.GetHeadSelectedUnit();
        Log.info("HexCursor.init: UI.GetHeadSelectedUnit() returned " .. tostring(unit));
        if unit ~= nil then
            target = unitPlot(unit);
            Log.info("HexCursor.init: head-selected unit plot = " .. tostring(target));
        end
    else
        Log.warn("HexCursor.init: UI.GetHeadSelectedUnit not available");
    end
    if target == nil then
        Log.info("HexCursor.init: trying first-owned-unit fallback");
        local pPlayer = Players[localPlayer];
        if pPlayer ~= nil and pPlayer.GetUnits ~= nil then
            local units = pPlayer:GetUnits();
            if units ~= nil and units.Members ~= nil then
                -- Civ VI's :Members() returns Lua generic-for's
                -- (iter_fn, container, control) triple. Wrapping the call
                -- in pcall captures only the first return value, breaking
                -- the binding so lMembersAux fails with "Not a valid
                -- instance" (confirmed via Lua.log 2026-05-24 at line 315).
                -- Use the direct engine pattern instead.
                local count = 0;
                for i, unit in units:Members() do
                    count = count + 1;
                    target = unitPlot(unit);
                    if target ~= nil then break; end
                end
                Log.info("HexCursor.init: iterated " .. count .. " units, target=" .. tostring(target));
            else
                Log.warn("HexCursor.init: pPlayer:GetUnits() returned nil or Members missing");
            end
        end
    end
    if target == nil then
        Log.info("HexCursor.init: trying capital fallback");
        local pPlayer = Players[localPlayer];
        if pPlayer ~= nil and pPlayer.GetCities ~= nil then
            local okCities, cities = pcall(function() return pPlayer:GetCities(); end);
            if okCities and cities ~= nil then
                local okCap, capital = pcall(function() return cities:GetCapitalCity(); end);
                Log.info("HexCursor.init: capital = " .. tostring(capital));
                if okCap and capital ~= nil then
                    target = Map.GetPlot(capital:GetX(), capital:GetY());
                end
            end
        end
    end
    if target == nil then
        Log.warn("HexCursor.init: no unit, no capital — cursor unset until first move");
        return;
    end
    setCursor(target);
    _initialized = true;
    Log.info("HexCursor.init: SUCCESS — placed at (" .. _x .. ", " .. _y .. ")");
end

local function move(direction)
    if not _initialized then
        HexCursor.init();
        if not _initialized then
            OutputMessageToScreenReader("Cursor not ready");
            return;
        end
    end
    local nextPlot = Map.GetAdjacentPlot(_x, _y, direction);
    if nextPlot == nil then
        OutputMessageToScreenReader("Edge of map");
        return;
    end
    setCursor(nextPlot);
    AnnouncePlot(nextPlot);
end

-- Public API. HexCursorAddin.lua wires CIVVIACCESS_* engine actions to
-- these functions via Events.InputActionTriggered dispatch.

function HexCursor.move(direction)
    move(direction);
end

-- Sync cursor to (x, y) without speaking. Used by UnitMovement so the
-- cursor follows the unit after a successful move; the move-complete
-- announce from UnitMovement covers the speech, AnnouncePlot here would
-- double-speak.
function HexCursor.jumpTo(x, y)
    if not _initialized then
        HexCursor.init();
    end
    local plot = Map.GetPlot(x, y);
    if plot == nil then return; end
    setCursor(plot);
end

function HexCursor.speakWhereAmIAbs()
    if not _initialized then
        OutputMessageToScreenReader("Cursor not ready");
        return;
    end
    OutputMessageToScreenReader(HexGeom.absoluteCoords(_x, _y));
end

function HexCursor.speakWhereAmI()
    if not _initialized then
        OutputMessageToScreenReader("Cursor not ready");
        return;
    end
    local rel = HexGeom.relativeToCapital(_x, _y);
    if rel == nil then
        -- No capital yet — fall back to absolute so the user always hears
        -- something useful, not silence.
        OutputMessageToScreenReader(HexGeom.absoluteCoords(_x, _y)
                                    .. ". No capital yet.");
        return;
    end
    OutputMessageToScreenReader(rel);
end

function HexCursor.openHelp()
    Help.enter(cursorHandler);
end

-- Authored help entries for the cursor handler. ? help walks the stack
-- and surfaces these alongside the commonHelpEntries (Alt+V, Ctrl+T, etc.
-- registered by BaseMenu).
local CURSOR_HELP_ENTRIES = {
    { keyLabel = "Q",       description = "Move cursor northwest" },
    { keyLabel = "E",       description = "Move cursor northeast" },
    { keyLabel = "A",       description = "Move cursor west" },
    { keyLabel = "D",       description = "Move cursor east" },
    { keyLabel = "Z",       description = "Move cursor southwest" },
    { keyLabel = "C",       description = "Move cursor southeast" },
    { keyLabel = "Shift+Q", description = "Move selected unit northwest" },
    { keyLabel = "Shift+E", description = "Move selected unit northeast" },
    { keyLabel = "Shift+A", description = "Move selected unit west" },
    { keyLabel = "Shift+D", description = "Move selected unit east" },
    { keyLabel = "Shift+Z", description = "Move selected unit southwest" },
    { keyLabel = "Shift+C", description = "Move selected unit southeast" },
    { keyLabel = "/",       description = "Speak selected unit's stats" },
    { keyLabel = "Ctrl+/",  description = "Recenter cursor on selected unit" },
    { keyLabel = "Ctrl+.",  description = "Cycle to next unit (any state, including units already done)" },
    { keyLabel = "Ctrl+,",  description = "Cycle to previous unit (any state)" },
    { keyLabel = "Shift+S", description = "Speak position relative to capital" },
    { keyLabel = "Alt+S",   description = "Speak absolute X, Y coordinates" },
};

-- Handler record on the HandlerStack. Bindings is empty — input dispatch
-- happens via Events.InputActionTriggered in HexCursorAddin.lua, not via
-- InputRouter walking these bindings (the addin's ContextPtr never gets
-- raw keyboard; see [[reference-addUserInterfaces-no-keyboard]]). The
-- handler IS still pushed onto the stack so ? help collects helpEntries.
local cursorHandler = {
    name = "HexCursor",
    helpEntries = CURSOR_HELP_ENTRIES,
    bindings = {},  -- intentionally empty
};

local function Initialize()
    Log.info("HexCursor.Initialize: starting");
    Log.info("HexCursor.Initialize: ContextPtr=" .. tostring(ContextPtr));
    Log.info("HexCursor.Initialize: Events=" .. tostring(Events)
            .. " LuaEvents=" .. tostring(LuaEvents)
            .. " Game=" .. tostring(Game)
            .. " UI=" .. tostring(UI));
    -- Push the handler onto HandlerStack first so ? help collects its
    -- bindings even before the player has navigated.
    HandlerStack.push(cursorHandler);
    Log.info("HexCursor.Initialize: pushed onto HandlerStack, depth=" .. HandlerStack.count());

    -- Place the cursor when the loading screen closes — the canonical
    -- "we're in-game now" signal in Civ VI. Use Events (engine-level) not
    -- LuaEvents (mod-level) for this; LoadScreenClose is engine-fired.
    if Events ~= nil and Events.LoadScreenClose ~= nil then
        Events.LoadScreenClose.Add(HexCursor.init);
        Log.info("HexCursor.Initialize: subscribed to Events.LoadScreenClose");
    else
        Log.warn("HexCursor.Initialize: Events.LoadScreenClose not available, trying immediate init");
        HexCursor.init();
    end
end
Initialize();
