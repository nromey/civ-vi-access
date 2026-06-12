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

local function improvementName(plot)
    if plot == nil then return ""; end
    local idx = plot:GetImprovementType();
    if idx == -1 then return ""; end
    local row = GameInfo.Improvements[idx];
    if row == nil or row.Name == nil then return ""; end
    local name = Locale.Lookup(row.Name);
    local pillaged = false;
    pcall(function() pillaged = plot:IsImprovementPillaged(); end);
    if pillaged then return name .. ", pillaged"; end
    return name;
end

local function routeName(plot)
    if plot == nil then return ""; end
    local has = false;
    pcall(function() has = plot:IsRoute(); end);
    if not has then return ""; end
    local row = GameInfo.Routes[plot:GetRouteType()];
    local name = (row ~= nil and row.Name ~= nil) and Locale.Lookup(row.Name) or "Road";
    local pillaged = false;
    pcall(function() pillaged = plot:IsRoutePillaged(); end);
    if pillaged then return name .. ", pillaged"; end
    return name;
end

-- Lean plot announce: terrain + feature + resource + river + improvement +
-- road + cost-if->1 + units + city. Skips yields / appeal / continent /
-- defense modifier — those live behind Ctrl+T (verbose) per
-- [[feedback-terse-announce-default]]. Movement cost graduated to the lean
-- line 2026-06-12 (Noel), exceptions-only: it speaks ONLY when > 1.
--
-- Respects fog of war so screen-reader users don't get information
-- advantage over sighted players. Three states (Civ6Common.lua pattern):
--   - Unrevealed (never explored): speak "Unexplored" only
--   - Revealed but not visible (fog of war): terrain/feature/resource
--     only — what player saw last time, no current units/cities
--   - Visible (currently in sight): speak everything as before
local function AnnouncePlot(plot)
    if plot == nil then
        Speech.emit("No plot", "meta");
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
        Speech.emit("Unexplored", "nav");
        return;
    end

    local parts = {};
    local terrain = terrainName(plot);
    if terrain ~= "" then parts[#parts + 1] = terrain; end
    local feature = featureName(plot);
    if feature ~= "" then parts[#parts + 1] = feature; end
    local resource = resourceName(plot);
    if resource ~= "" then parts[#parts + 1] = resource; end
    -- River is an EDGE property, not a terrain type, so it never came through
    -- terrainName() — a riverside grassland just read "Grassland" (Noel 2026-06-01:
    -- nav says coast/ocean but never river). Mirror PlotToolTip's own line
    -- (LOC_TOOLTIP_RIVER, inserted right after the resource) so the spoken tile
    -- matches the sighted tooltip. In `parts` before the fog branch so a river you
    -- already saw still reads under fog of war (static terrain memory).
    if plot.IsRiver and plot:IsRiver() then
        parts[#parts + 1] = Locale.Lookup("LOC_TOOLTIP_RIVER");
    end
    -- Improvement + road (Noel 2026-06-12, previously never spoken at all).
    -- Added before the fog branch like terrain: under fog this reads CURRENT
    -- state, an approximation of the sighted "last seen" memory — good enough
    -- until a revealed-state cache exists.
    local improvement = improvementName(plot);
    if improvement ~= "" then parts[#parts + 1] = improvement; end
    local route = routeName(plot);
    if route ~= "" then parts[#parts + 1] = route; end
    -- Territory (Noel 2026-06-12): sighted players read ownership off border
    -- colors; speak the owner when there IS one ("your territory" / "Scottish
    -- territory"), stay silent on unclaimed land (exceptions speak). Skipped on
    -- city plots — StringifyCity already names the civ. Static like
    -- improvements (borders persist under fog).
    if TerritoryPhrase ~= nil then
        local hasCity = false;
        pcall(function() hasCity = plot:IsCity(); end);
        if not hasCity then
            local ownerId = -1;
            pcall(function() ownerId = plot:GetOwner(); end);
            local terr = TerritoryPhrase(ownerId);
            if terr ~= nil then parts[#parts + 1] = terr; end
        end
    end
    -- Entry cost, exceptions-only (Noel 2026-06-12): "costs N" speaks iff N > 1,
    -- so flat tiles stay terse and only the turn-eaters (hills, woods, marsh)
    -- announce themselves. Silence = the normal 1. Roads flatten the cost back
    -- to <=1 (PlotEntryCost), so a roaded hill goes quiet again.
    local cost = (PlotEntryCost ~= nil) and PlotEntryCost(plot) or nil;
    if cost ~= nil and cost > 1 then
        parts[#parts + 1] = "costs " .. tostring(cost);
    end

    if not isVisible then
        -- Fog of war: speak only the static terrain memory. Current units
        -- and city state could have changed since the player last saw it.
        if #parts == 0 then
            Speech.emit("Unknown", "nav");
            return;
        end
        Speech.emit(table.concat(parts, ". ") .. ". Fog of war.", "nav");
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
    -- Selected-unit flag (Noel 2026-06-03): when the cursor sits on the tile
    -- of the unit you currently command, say "(selected)" so you can tell
    -- your builder from the barbarian sharing the neighbourhood.
    local selUnit = (UI ~= nil and UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil;
    local units = Units.GetUnitsInPlotLayerID(x, y, MapLayers.ANY);
    if units ~= nil then
        for _, unit in ipairs(units) do
            local s = StringifyUnit(unit);
            if selUnit ~= nil and unit ~= nil
               and unit:GetID() == selUnit:GetID()
               and unit:GetOwner() == selUnit:GetOwner() then
                s = s .. " (selected)";
            end
            parts[#parts + 1] = s;
        end
    end

    -- Chatty mode: append the full tile mechanics (yields, water, defense,
    -- appeal, movement, continent) so tile NAV reads the deep datasheet. Terse
    -- (default) stops at the brief line above. This is THE verbosity gate for
    -- world nav (Noel 2026-06-02: terse vs chatty must actually change what you
    -- hear as you move; previously nav ignored the toggle entirely).
    if Verbosity ~= nil and Verbosity.isOn() and HexCursor._mechanicsParts ~= nil then
        for _, m in ipairs(HexCursor._mechanicsParts(plot)) do parts[#parts + 1] = m; end
    end

    if #parts == 0 then
        Speech.emit("Unknown", "nav");
        return;
    end
    Speech.emit(table.concat(parts, ". "), "nav");
end

HexCursor.AnnouncePlot = AnnouncePlot;

-- ── Verbose tile readout (Shift+T) ──────────────────────────────────────────
-- The "full mechanics" layer the terse nav announce deliberately omits: yields,
-- defense bonus, appeal, fresh-water status, movement cost, continent. Mirrors
-- the sighted PlotToolTip (same LOC strings) so a blind player gets parity data
-- on demand. Noel 2026-06-01: this is the content behind Shift+T — and what
-- Alt+V will eventually fold into the default announce.

-- "2 Food, 1 Production, 1 Gold" from per-yield plot values.
local function yieldSummary(plot)
    if plot == nil or plot.GetYield == nil then return nil; end
    local out = {};
    for row in GameInfo.Yields() do
        local ok, y = pcall(function() return plot:GetYield(row.Index); end);
        if ok and y ~= nil and y > 0 then
            out[#out + 1] = y .. " " .. Locale.Lookup(row.Name);
        end
    end
    if #out == 0 then return nil; end
    return "Yields: " .. table.concat(out, ", ");
end

-- Appeal descriptor (Charming / Breathtaking / etc.) mirroring PlotToolTip: the
-- first AppealHousingChanges threshold the appeal meets. Land tiles only.
local function appealPhrase(plot)
    if plot == nil or plot.GetAppeal == nil then return nil; end
    if plot.IsWater and plot:IsWater() then return nil; end
    local ok, appeal = pcall(function() return plot:GetAppeal(); end);
    if not ok or appeal == nil then return nil; end
    local desc = nil;
    for row in GameInfo.AppealHousingChanges() do
        if appeal >= row.MinimumValue then
            desc = Locale.Lookup(row.Description);
            break;
        end
    end
    if desc == nil then return nil; end
    return Locale.Lookup("LOC_TOOLTIP_APPEAL", desc, appeal);
end

-- Fresh-water status (the housing driver), ranked like the engine's own start
-- logic. River is already its own line in the base parts, so skip it here.
local function waterPhrase(plot)
    if plot == nil then return nil; end
    if plot.IsRiver and plot:IsRiver() then return nil; end
    if plot.IsFreshWater and plot:IsFreshWater() then return "fresh water"; end
    if plot.IsCoastalLand and plot:IsCoastalLand() then return "coastal"; end
    return "no fresh water";
end

-- Shared "full mechanics" list (yields, water, defense, appeal, movement,
-- continent) used by BOTH the Shift+T verbose readout and chatty-mode tile nav.
-- Returns an array of strings (possibly empty). Exposed on the HexCursor table
-- (not a local) so AnnouncePlot — defined earlier in the file — can reach it at
-- runtime regardless of lexical order.
function HexCursor._mechanicsParts(plot)
    local out = {};
    local function add(s) if s ~= nil and s ~= "" then out[#out + 1] = s; end end
    if plot == nil then return out; end
    add(yieldSummary(plot));
    add(waterPhrase(plot));
    if plot.GetDefenseModifier ~= nil then
        local ok, dm = pcall(function() return plot:GetDefenseModifier(); end);
        if ok and dm ~= nil and dm ~= 0 then
            add(Locale.Lookup("LOC_TOOLTIP_DEFENSE_MODIFIER", dm));
        end
    end
    add(appealPhrase(plot));
    if (plot.IsImpassable == nil or not plot:IsImpassable()) and plot.GetMovementCost ~= nil then
        local ok, mc = pcall(function() return plot:GetMovementCost(); end);
        if ok and mc ~= nil and mc > 0 then
            add(Locale.Lookup("LOC_TOOLTIP_MOVEMENT_COST", mc));
        end
    end
    if plot.GetContinentType ~= nil then
        local ct = plot:GetContinentType();
        if ct ~= nil and ct ~= -1 and GameInfo.Continents[ct] ~= nil then
            add(Locale.Lookup("LOC_TOOLTIP_CONTINENT", GameInfo.Continents[ct].Description));
        end
    end
    return out;
end

-- Shift+T handler: speak the full readout for the hex under the cursor.
function HexCursor.DescribeVerbose()
    local plot = (_x ~= nil and _y ~= nil and Map ~= nil and Map.GetPlot ~= nil)
                 and Map.GetPlot(_x, _y) or nil;
    if plot == nil then Speech.emit("No tile under cursor", "meta"); return; end

    local x, y = plot:GetX(), plot:GetY();

    -- Fog gate (mirror AnnouncePlot): never describe an unexplored tile.
    local localPlayer = (Game ~= nil and Game.GetLocalPlayer) and Game.GetLocalPlayer() or -1;
    local pVis = (localPlayer >= 0 and PlayersVisibility ~= nil)
                 and PlayersVisibility[localPlayer] or nil;
    if pVis ~= nil and pVis.IsRevealed ~= nil then
        local ok, rev = pcall(function() return pVis:IsRevealed(x, y); end);
        if ok and rev ~= true then Speech.emit("Unexplored", "selection"); return; end
    end

    local parts = {};
    local function add(s) if s ~= nil and s ~= "" then parts[#parts + 1] = s; end end

    -- Order (Noel 2026-06-01): identity first, then the decision trio
    -- (yields / water / defense), then secondary detail, with movement cost +
    -- continent pushed to the TAIL so the settle-relevant facts land before the
    -- firehose and the listener can stop early.
    add(terrainName(plot));
    add(featureName(plot));
    if plot.IsRiver and plot:IsRiver() then add(Locale.Lookup("LOC_TOOLTIP_RIVER")); end

    add(yieldSummary(plot));
    add(waterPhrase(plot));
    if plot.GetDefenseModifier ~= nil then
        local ok, dm = pcall(function() return plot:GetDefenseModifier(); end);
        if ok and dm ~= nil and dm ~= 0 then
            add(Locale.Lookup("LOC_TOOLTIP_DEFENSE_MODIFIER", dm));
        end
    end

    add(resourceName(plot));
    add(appealPhrase(plot));

    -- Tail: least decision-critical, spoken last.
    if (plot.IsImpassable == nil or not plot:IsImpassable()) and plot.GetMovementCost ~= nil then
        local ok, mc = pcall(function() return plot:GetMovementCost(); end);
        if ok and mc ~= nil and mc > 0 then
            add(Locale.Lookup("LOC_TOOLTIP_MOVEMENT_COST", mc));
        end
    end
    if plot.GetContinentType ~= nil then
        local ct = plot:GetContinentType();
        if ct ~= nil and ct ~= -1 and GameInfo.Continents[ct] ~= nil then
            add(Locale.Lookup("LOC_TOOLTIP_CONTINENT", GameInfo.Continents[ct].Description));
        end
    end

    if #parts == 0 then Speech.emit("No tile data", "meta"); return; end
    Speech.emit(table.concat(parts, ". "), "selection");
end

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
            Speech.emit("Cursor not ready", "meta");
            return;
        end
    end
    local nextPlot = Map.GetAdjacentPlot(_x, _y, direction);
    if nextPlot == nil then
        Speech.emit("Edge of map", "meta");
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

-- Scanner HOME: park the cursor on a found item and confirm both WHAT is there
-- and WHERE it is. Speaks the tile glance (terrain/feature/resource/units —
-- AnnouncePlot) then the coordinates. Two emits: glance at nav, coords at
-- status so the coords queue after the glance instead of interrupting it
-- (Noel 2026-06-08: Home should say "moving to sheep at 13, 25", not just the
-- tile). selUnit/fog handling all live inside AnnouncePlot.
function HexCursor.jumpAndAnnounce(x, y)
    if not _initialized then
        HexCursor.init();
    end
    local plot = Map.GetPlot(x, y);
    if plot == nil then return; end
    setCursor(plot);
    AnnouncePlot(plot);
    Speech.emit(HexGeom.absoluteCoords(x, y), "status");
end

-- Scanner BACKSPACE: return the cursor to the cell saved before the last jump.
-- Frame it ("Returning to ...") plus the terse where-am-I (capital-relative
-- bearing + coords) so it's clear the cursor moved BACK and to where — the bare
-- tile glance left it ambiguous whether anything moved (Noel 2026-06-08).
function HexCursor.returnAndAnnounce(x, y)
    if not _initialized then
        HexCursor.init();
    end
    local plot = Map.GetPlot(x, y);
    if plot == nil then return; end
    setCursor(plot);
    local coords = HexGeom.absoluteCoords(x, y);
    local rel = HexGeom.relativeToCapital(x, y);
    local where = (rel == nil) and coords or (rel .. ". " .. coords);
    Speech.emit(Locale.Lookup("LOC_CIVVIACCESS_SCANNER_RETURNING", where), "status");
end

-- Current cursor coords, or (nil, nil) before init. Read seam for the scanner
-- (Scanner.cursor.position): the scanner sorts/measures distances from here and
-- parks the cursor here when you Home onto a result.
function HexCursor.position()
    if not _initialized then return nil, nil; end
    return _x, _y;
end

-- "selected French Builder" for the head-selected unit, or nil if nothing is
-- selected. The cursor is free-roam, so the selected unit can be anywhere — the
-- where-am-I reads name it so you always know what you're commanding (Noel
-- 2026-06-03). StringifyUnit is a global from ScreenReaderPlotUtils.
local function selectedUnitPhrase()
    local sel = (UI ~= nil and UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil;
    if sel == nil then return nil; end
    local name = StringifyUnit(sel);
    if name == nil or name == "" then return nil; end
    return "selected " .. name;
end

function HexCursor.speakWhereAmIAbs()
    if not _initialized then
        Speech.emit("Cursor not ready", "meta");
        return;
    end
    Speech.emit(HexGeom.absoluteCoords(_x, _y), "status");
end

function HexCursor.speakWhereAmI()
    if not _initialized then
        Speech.emit("Cursor not ready", "meta");
        return;
    end
    -- Quick where-am-I: capital-relative bearing AND the absolute coords.
    -- Noel 2026-06-02: the natural where-am-I keys (bare S / Shift+S) must
    -- speak the numbers too — Alt+S as the only coords key was too easy to
    -- forget. Coords go last so the bearing (the thing you usually want)
    -- leads.
    local coords = HexGeom.absoluteCoords(_x, _y);
    local rel = HexGeom.relativeToCapital(_x, _y);
    local base = (rel == nil) and (coords .. ". No capital yet.")
                 or (rel .. ". " .. coords);
    local sel = selectedUnitPhrase();
    if sel ~= nil then base = base .. ". " .. sel; end
    Speech.emit(base, "status");
end

-- Nearest of the local player's cities to (x,y): returns (name, directionString)
-- or nil if the player has no cities yet. Direction is the city's bearing FROM
-- the cursor ("5 east, 2 southeast").
local function nearestOwnCity(x, y)
    local lpid = (Game ~= nil and Game.GetLocalPlayer) and Game.GetLocalPlayer() or -1;
    if lpid < 0 or Players == nil or Players[lpid] == nil then return nil; end
    local p = Players[lpid];
    local cities = (p.GetCities ~= nil) and p:GetCities() or nil;
    if cities == nil then return nil; end
    local best, bestDist, bx, by = nil, nil, nil, nil;
    for _, c in cities:Members() do
        if c ~= nil then
            local cx, cy = c:GetX(), c:GetY();
            local d = Map.GetPlotDistance(cx, cy, x, y);
            if bestDist == nil or d < bestDist then
                best, bestDist, bx, by = c, d, cx, cy;
            end
        end
    end
    if best == nil then return nil; end
    return Locale.Lookup(best:GetName()), HexGeom.directionString(x, y, bx, by);
end

-- Shift+S: the RICH locate ("survey"). Where you are (capital-relative), the
-- terrain under the cursor, and your nearest city + its bearing. Bare S stays
-- the quick where-am-I (speakWhereAmI). Noel 2026-06-01. Nearest-unexplored
-- direction is a banked future addition.
function HexCursor.speakSurvey()
    if not _initialized then
        Speech.emit("Cursor not ready", "meta");
        return;
    end
    local parts = {};
    local rel = HexGeom.relativeToCapital(_x, _y);
    parts[#parts + 1] = rel or "no capital yet";
    local plot = (Map ~= nil and Map.GetPlot ~= nil) and Map.GetPlot(_x, _y) or nil;
    if plot ~= nil then
        local terr = terrainName(plot);
        if terr ~= "" then parts[#parts + 1] = "on " .. terr; end
        if plot.IsRiver and plot:IsRiver() then parts[#parts + 1] = "by a river"; end
    end
    local cityName, cityDir = nearestOwnCity(_x, _y);
    if cityName ~= nil then
        local line = "nearest city " .. cityName;
        if cityDir ~= nil then line = line .. ", " .. cityDir; end
        parts[#parts + 1] = line;
    end
    local sel = selectedUnitPhrase();
    if sel ~= nil then parts[#parts + 1] = sel; end
    -- Coords last (Noel 2026-06-02): the survey now always ends with the
    -- absolute X, Y so any where-am-I key carries the numbers.
    parts[#parts + 1] = HexGeom.absoluteCoords(_x, _y);
    Speech.emit(table.concat(parts, ". "), "status");
end

-- Forward declaration. cursorHandler is fully populated below; declared
-- here so HexCursor.openHelp's closure binds to the local rather than
-- a (nil) global. Without this, ? help would log "Help.enter: nil
-- handler" because Lua resolves the symbol at function-define time as
-- a global, not the future local. Confirmed via Lua.log 2026-05-26.
local cursorHandler;

function HexCursor.openHelp()
    -- Collect entries in this VM (HandlerStack is per-VM; HelpAddin's
    -- separate UI VM has no idea what's on our stack). Marshal across
    -- via the LuaEvent so HelpAddin can render without needing its
    -- own handler stack. HelpAddin then opens as a modal popup with
    -- raw keyboard — gives us arrow-nav + type-to-filter that
    -- HexCursorAddin's InputAction dispatch can't provide.
    local entries = HandlerStack.collectHelpEntries();
    if LuaEvents ~= nil and LuaEvents.CivViAccess_OpenHelp ~= nil then
        LuaEvents.CivViAccess_OpenHelp(entries);
    else
        -- Fallback: inline path (BaseMenu-style state on the cursor
        -- handler). User won't have arrow-nav in cursor mode but at
        -- least hears the preamble + first entry.
        Help.enter(cursorHandler);
    end
end

-- Authored help entries for the cursor handler. ? help walks the stack
-- and surfaces these alongside the commonHelpEntries (Alt+V, Ctrl+T,
-- etc. registered by BaseMenu / shared modules). Order: cursor nav,
-- unit move, unit ops, unit cycle, pickers, notifications, info.
local CURSOR_HELP_ENTRIES = {
    -- Cursor navigation (bare letters)
    { keyLabel = "Q",       description = "Move cursor northwest" },
    { keyLabel = "E",       description = "Move cursor northeast" },
    { keyLabel = "A",       description = "Move cursor west" },
    { keyLabel = "D",       description = "Move cursor east" },
    { keyLabel = "Z",       description = "Move cursor southwest" },
    { keyLabel = "C",       description = "Move cursor southeast" },

    -- Unit one-hex move (Shift + cursor key) — bare letters move the cursor,
    -- Shift commits a unit move. (Help previously mislabeled these Alt.)
    { keyLabel = "Shift+Q", description = "Move selected unit northwest one hex" },
    { keyLabel = "Shift+E", description = "Move selected unit northeast one hex" },
    { keyLabel = "Shift+A", description = "Move selected unit west one hex" },
    { keyLabel = "Shift+D", description = "Move selected unit east one hex" },
    { keyLabel = "Shift+Z", description = "Move selected unit southwest one hex" },
    { keyLabel = "Shift+C", description = "Move selected unit southeast one hex" },

    -- Unit actions
    { keyLabel = "B",       description = "Found city with selected Settler" },
    { keyLabel = "R",       description = "Rest: fortify military or sleep civilians" },
    { keyLabel = "Alt+Z",   description = "Strict sleep (civilians only; military redirected to R)" },

    -- Unit cycle
    { keyLabel = "Period",  description = "Cycle to next unit needing orders" },
    { keyLabel = "Comma",   description = "Cycle to previous unit needing orders" },
    { keyLabel = "Shift+Period", description = "Cycle to next unit, any state including sleeping / done" },
    { keyLabel = "Shift+Comma",  description = "Cycle to previous unit, any state" },

    -- Unit info
    { keyLabel = "Slash",   description = "Speak selected unit's stats, then the six exits with move costs" },
    { keyLabel = "Ctrl+Slash", description = "Recenter cursor on selected unit" },

    -- Pickers
    { keyLabel = "Shift+P", description = "Open city production picker" },
    { keyLabel = "Alt+T",   description = "Open technology picker" },
    { keyLabel = "Alt+L",   description = "Open civic picker" },
    { keyLabel = "Alt+P",   description = "Auto-pick cheapest production, research, and civic to unblock end turn" },

    -- Notifications center
    { keyLabel = "Left Bracket",  description = "Previous notification" },
    { keyLabel = "Right Bracket", description = "Next notification" },
    { keyLabel = "Alt+N",   description = "Toggle idle notification reminder on / off" },

    -- Coordinates + verbosity
    { keyLabel = "S",       description = "Where am I — bearing from capital and coordinates" },
    { keyLabel = "Shift+S", description = "Survey — bearing from capital, terrain, nearest city, and coordinates" },
    { keyLabel = "Shift+V", description = "Toggle verbose / terse announce mode" },

    -- Help itself
    { keyLabel = "Question mark", description = "Open this help overlay" },
};

-- Handler record on the HandlerStack. Bindings is empty — input dispatch
-- happens via Events.InputActionTriggered in HexCursorAddin.lua, not via
-- InputRouter walking these bindings (the addin's ContextPtr never gets
-- raw keyboard; see [[reference-addUserInterfaces-no-keyboard]]). The
-- handler IS still pushed onto the stack so ? help collects helpEntries.
cursorHandler = {
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
