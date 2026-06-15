-- BoardQueryProbe — THROWAWAY design probe (2026-05-31). NOT a shipping feature.
--
-- Purpose: make the "query the board" concept AUDIBLE against a live map so Noel
-- can hear whether region descriptions land ("grassland northwest, about 3 by 4;
-- big unknown to the south") before we commit to wording / key bindings. No
-- bindings, no UX surface — one FireTuner line:
--     LuaEvents.CivViAccess_DebugBoardQuery()        -- radius 16 around ref
--     LuaEvents.CivViAccess_DebugBoardQuery(20)
-- Reference point = selected unit, else local player's capital/first city.
--
-- It demonstrates the ONE PRIMITIVE the whole spatial-awareness design rests on:
-- flood-fill the map into connected REGIONS (blocks), run three ways —
--   (1) open settle-able land blocks (grassland/plains, unclaimed, passable),
--   (2) unexplored (fog) blocks — "where to send a scout",
--   (3) the engine's OWN city-site recommendations (GetSettlementRecommendations).
-- Same fill, different predicate — exactly the macro/micro story we sketched.
--
-- STRIP before release (like DebugConcert). Hosted in the live UI VM via
-- RevealListeners' include + Initialize. Everything is pcall-soft so a probe
-- failure can never break the host addin.

include("ScreenReader");
include("Log");

BoardQueryProbe = BoardQueryProbe or {};

local function lp()
    return (Game ~= nil and Game.GetLocalPlayer ~= nil) and Game.GetLocalPlayer() or -1;
end

local function speak(text)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then Speech.emit(text, "status"); end
    Log.info("BoardQuery: " .. text);
end

local function L(key) return (Locale ~= nil and key ~= nil) and Locale.Lookup(key) or tostring(key); end

-- 8-way compass bearing from reference (rx,ry) to (tx,ty). Region bearings read
-- naturally as 8-way ("northwest", "south") even though unit MOVES are 6-way —
-- a region's general direction isn't a hex step. Map: +x east, +y north.
local DEG = 180 / math.pi;
local SECTOR_NAME = { [0]="east", [1]="northeast", [2]="north", [3]="northwest",
                      [4]="west", [5]="southwest", [6]="south", [7]="southeast" };

-- 8-way sector index (0..7) from ref to target, or nil if same tile.
local function sectorIndex(rx, ry, tx, ty)
    local dx, dy = tx - rx, ty - ry;
    if dx == 0 and dy == 0 then return nil; end
    local a = math.atan(dy, dx) * DEG;           -- east=0, north=+90
    if a < 0 then a = a + 360; end
    return math.floor((a + 22.5) / 45) % 8;
end

local function bearing(rx, ry, tx, ty)
    local idx = sectorIndex(rx, ry, tx, ty);
    return (idx ~= nil) and SECTOR_NAME[idx] or "here";
end

-- Turn a block's per-sector tile histogram into a spoken spread: a single
-- direction ("south") or an ARC across the compass ("from south to southeast")
-- when the block sprawls across sectors — the "breadth" cue (Noel 2026-05-31:
-- the sweep tells him it's a frontier, not a pocket). Only sectors holding >=10%
-- of the block count as part of the spread, so a few stray tiles don't smear it.
local function spreadPhrase(sectors, total)
    local thresh = math.max(1, math.floor(total * 0.1));
    local pop = {};
    for i = 0, 7 do if (sectors[i] or 0) >= thresh then pop[#pop + 1] = i; end end
    if #pop == 0 then return nil; end
    if #pop == 1 then return SECTOR_NAME[pop[1]]; end
    -- Minimal circular arc covering the populated sectors = complement of the
    -- widest empty gap. Sort, find the largest CW gap, the arc is the rest.
    table.sort(pop);
    local n = #pop;
    local maxGap, gapAt = -1, 1;
    for i = 1, n do
        local cur = pop[i];
        local nxt = (i < n) and pop[i + 1] or (pop[1] + 8);
        local gap = nxt - cur;
        if gap > maxGap then maxGap = gap; gapAt = i; end
    end
    local startIdx = pop[(gapAt % n) + 1];   -- sector just after the widest gap
    local endIdx   = pop[gapAt];             -- sector just before it
    return "from " .. SECTOR_NAME[startIdx] .. " to " .. SECTOR_NAME[endIdx];
end

local function refPoint()
    if UI ~= nil and UI.GetHeadSelectedUnit ~= nil then
        local u = UI.GetHeadSelectedUnit();
        if u ~= nil then return u:GetX(), u:GetY(), "your unit"; end
    end
    local p = Players and Players[lp()] or nil;
    local cities = p and p.GetCities and p:GetCities() or nil;
    if cities ~= nil then
        for _, c in cities:Members() do if c ~= nil then return c:GetX(), c:GetY(), "your capital"; end end
    end
    return nil, nil, nil;
end

-- Coarse "is this good open settle-able land" predicate for block (1).
local function isOpenLand(plot, player)
    if plot == nil then return false; end
    if plot:IsWater() or plot:IsImpassable() or plot:IsMountain() then return false; end
    if plot:IsOwned() then return false; end             -- unclaimed only
    local terr = GameInfo.Terrains[plot:GetTerrainType()];
    if terr == nil then return false; end
    local t = terr.TerrainType;
    -- grassland / plains (flat or hills) = the "green" a sighted player scans for
    return t == "TERRAIN_GRASS" or t == "TERRAIN_GRASS_HILLS"
        or t == "TERRAIN_PLAINS" or t == "TERRAIN_PLAINS_HILLS";
end

local function isFogged(plot, vis, player)
    if plot == nil then return false; end
    if vis == nil or vis.IsRevealed == nil then return false; end
    local ok, rev = pcall(function() return vis:IsRevealed(plot:GetX(), plot:GetY()); end);
    if not ok then return false; end
    return rev ~= true;     -- unexplored = NOT revealed to the local player
end

-- Flood-fill connected plots satisfying predicate(plot), starting anywhere in a
-- bounded window around (rx,ry). Returns a list of blocks; each block =
-- {count, minx,maxx,miny,maxy, cx,cy, hasRiver, resources={name->true}}.
local function fillBlocks(rx, ry, radius, predicate)
    local player = Players and Players[lp()] or nil;
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[lp()] or nil;
    local seen = {};            -- plotIndex -> true
    local blocks = {};
    local W, H = Map.GetGridSize();

    local function key(x, y) return y * W + x; end
    local function plotAt(x, y)
        if y < 0 or y >= H then return nil; end
        return Map.GetPlot(x, y);                 -- x wraps internally
    end

    for y = math.max(0, ry - radius), math.min(H - 1, ry + radius) do
        for dx = -radius, radius do
            local x = rx + dx;
            local plot = plotAt(x, y);
            if plot ~= nil then
                local k = key(plot:GetX(), plot:GetY());
                if not seen[k] and predicate(plot, player, vis) then
                    -- BFS this connected region
                    local stack = { plot };
                    seen[k] = true;
                    local b = { count = 0, minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9,
                                sumx = 0, sumy = 0, hasRiver = false, resources = {},
                                sectors = {} };
                    while #stack > 0 do
                        local pl = table.remove(stack);
                        local px, py = pl:GetX(), pl:GetY();
                        b.count = b.count + 1;
                        b.minx = math.min(b.minx, px); b.maxx = math.max(b.maxx, px);
                        b.miny = math.min(b.miny, py); b.maxy = math.max(b.maxy, py);
                        b.sumx = b.sumx + px; b.sumy = b.sumy + py;
                        local si = sectorIndex(rx, ry, px, py);
                        if si ~= nil then b.sectors[si] = (b.sectors[si] or 0) + 1; end
                        if pl.IsRiver and pl:IsRiver() then b.hasRiver = true; end
                        -- Gate on resource visibility so the board query doesn't
                        -- leak tech-hidden strategics (oil before Refining, etc.) —
                        -- Noel 2026-06-15. Helper is global from ScreenReaderPlotUtils
                        -- (same VM); nil-guard defaults to showing (no regression).
                        local rt = pl:GetResourceType();
                        if rt ~= nil and rt ~= -1 and GameInfo.Resources[rt] ~= nil
                           and (ResourceVisibleToLocalPlayer == nil or ResourceVisibleToLocalPlayer(rt)) then
                            b.resources[L(GameInfo.Resources[rt].Name)] = true;
                        end
                        for dir = 0, (DirectionTypes.NUM_DIRECTION_TYPES or 6) - 1 do
                            local adj = Map.GetAdjacentPlot(px, py, dir);
                            if adj ~= nil then
                                local ak = key(adj:GetX(), adj:GetY());
                                -- stay within the window so a fill can't run the whole map
                                if not seen[ak]
                                   and math.abs(adj:GetY() - ry) <= radius
                                   and Map.GetPlotDistance(adj:GetX(), adj:GetY(), rx, ry) <= radius
                                   and predicate(adj, player, vis) then
                                    seen[ak] = true;
                                    stack[#stack + 1] = adj;
                                end
                            end
                        end
                    end
                    b.cx = math.floor(b.sumx / b.count + 0.5);
                    b.cy = math.floor(b.sumy / b.count + 0.5);
                    blocks[#blocks + 1] = b;
                end
            end
        end
    end
    table.sort(blocks, function(a, c) return a.count > c.count end);
    return blocks;
end

local function blockSize(b)
    return (b.maxx - b.minx + 1) .. " by " .. (b.maxy - b.miny + 1);
end

-- Pre-digest area into the unit a player actually reasons in: how many
-- non-overlapping cities fit. Civ VI cities work a 3-hex radius and can't be
-- founded within 3 tiles of each other, so usable footprint per city is ~12-16
-- tiles. ~14 is a reasonable divisor for "room for about N cities". This is the
-- gestalt a sighted player reads off the green blob; we compute it exactly.
local function cityCapacity(tileCount)
    local n = math.floor(tileCount / 14 + 0.5);
    if n < 1 then n = (tileCount >= 7) and 1 or 0; end   -- a half-block still seats 1
    return n;
end

local function capacityPhrase(tileCount)
    local n = cityCapacity(tileCount);
    if n <= 0 then return "tight, maybe a single city"; end
    if n == 1 then return "room for about 1 city"; end
    return "room for about " .. n .. " cities";
end

-- Bucket resources: count + up to 3 headliners, never the full dump (16 names
-- in a row was the firehose again — Noel 2026-05-31). A real version would rank
-- strategic > luxury > bonus; for the probe, first-3 is enough to test shape.
local function resourceSummary(b)
    local names = {};
    for n in pairs(b.resources) do names[#names + 1] = n; end
    if #names == 0 then return nil; end
    table.sort(names);   -- deterministic order for the probe
    if #names <= 3 then return table.concat(names, ", "); end
    return #names .. " kinds including " .. names[1] .. ", " .. names[2] .. ", " .. names[3];
end

-- Terrain + fresh-water descriptor for a recommended site. Fresh water is THE
-- settle-quality driver (housing) — this mirrors the game's OWN start logic
-- (AssignStartingPlots checks IsFreshWater then IsCoastalLand). River is the
-- headline case Noel asked for (2026-06-01); "no fresh water" is the load-bearing
-- NEGATIVE cue (a dry site is a weak settle). Rivers run along hex EDGES, so a
-- tile is either on a river (IsRiver) or not — there's no "through the middle".
local function siteDescriptor(tx, ty)
    local plot = (Map ~= nil and Map.GetPlot ~= nil) and Map.GetPlot(tx, ty) or nil;
    if plot == nil then return nil; end
    local bits = {};
    local terr = GameInfo.Terrains[plot:GetTerrainType()];
    if terr ~= nil then bits[#bits + 1] = L(terr.Name); end
    local feat = plot:GetFeatureType();
    if feat ~= nil and feat ~= -1 and GameInfo.Features[feat] ~= nil then
        bits[#bits + 1] = L(GameInfo.Features[feat].Name);
    end
    if plot.IsRiver and plot:IsRiver() then bits[#bits + 1] = "on a river";
    elseif plot.IsFreshWater and plot:IsFreshWater() then bits[#bits + 1] = "fresh water";
    elseif plot.IsCoastalLand and plot:IsCoastalLand() then bits[#bits + 1] = "coastal";
    else bits[#bits + 1] = "no fresh water"; end
    return table.concat(bits, ", ");
end

-- The engine's OWN top city-site recommendations (the "green highlight" data).
local function speakRecommendations(rx, ry)
    local player = Players and Players[lp()] or nil;
    if player == nil or player.GetGrandStrategicAI == nil then return; end
    local ai = player:GetGrandStrategicAI();
    if ai == nil or ai.GetSettlementRecommendations == nil then
        speak("Game settle recommendations: not available."); return;
    end
    local ok, recs = pcall(function() return ai:GetSettlementRecommendations(3); end);
    if not ok or recs == nil or #recs == 0 then
        speak("Game has no settle recommendations right now."); return;
    end
    for i, r in ipairs(recs) do
        local loc = r.SettlingLocation;
        if loc ~= nil and Map.GetPlotLocation ~= nil then
            local tx, ty = Map.GetPlotLocation(loc);
            local dist = Map.GetPlotDistance(tx, ty, rx, ry);
            local dir = bearing(rx, ry, tx, ty);
            local reason = r.SettleExplanation0 and L(r.SettleExplanation0) or nil;
            local line = "Recommended site " .. i .. ": " .. dir .. ", " .. dist .. " tiles";
            local desc = siteDescriptor(tx, ty);
            if desc ~= nil then line = line .. ", " .. desc; end
            if reason ~= nil then line = line .. ". " .. reason; end
            speak(line);
        end
    end
end

function BoardQueryProbe.Run(radius)
    radius = radius or 16;
    if Map == nil or Map.GetGridSize == nil then speak("Board query: no map."); return; end
    local rx, ry, refName = refPoint();
    if rx == nil then speak("Board query: nothing to anchor on yet."); return; end
    speak("Board query around " .. (refName or "you") .. ", radius " .. radius .. ".");

    -- (1) open settle-able land blocks
    local openBlocks = fillBlocks(rx, ry, radius, isOpenLand);
    local spoke = 0;
    for _, b in ipairs(openBlocks) do
        if b.count >= 4 and spoke < 3 then
            spoke = spoke + 1;
            local dist   = Map.GetPlotDistance(b.cx, b.cy, rx, ry);
            -- Lead with the SPREAD (breadth) then distance + capacity (urgency) —
            -- the two cues Noel actually reasons with (2026-05-31). A multi-sector
            -- block reads "sweeping from X to Y"; a compact one reads "to the X".
            local spread = spreadPhrase(b.sectors, b.count) or bearing(rx, ry, b.cx, b.cy);
            local where  = spread:find("from ") and ("sweeping " .. spread)
                           or ("to the " .. spread);
            local line = "Open grassland and plains " .. where
                .. ", " .. dist .. " tiles out, " .. b.count .. " tiles in total area, "
                .. capacityPhrase(b.count);
            if b.hasRiver then line = line .. ", river through it"; end
            local res = resourceSummary(b);
            if res ~= nil then line = line .. ". Resources: " .. res; end
            speak(line);
            Log.info("BoardQuery:   (shape drill-down: about " .. blockSize(b) .. ")");
        end
    end
    if spoke == 0 then speak("No sizable open land blocks nearby."); end

    -- (2) unexplored fog blocks — where to scout
    local fogBlocks = fillBlocks(rx, ry, radius, isFogged);
    local fogSpoke = 0;
    for _, b in ipairs(fogBlocks) do
        if b.count >= 4 and fogSpoke < 2 then
            fogSpoke = fogSpoke + 1;
            speak("Unexplored area to the " .. bearing(rx, ry, b.cx, b.cy)
                .. ", " .. b.count .. " tiles. Good scouting direction.");
        end
    end

    -- (3) the engine's own recommendations
    speakRecommendations(rx, ry);
end

function BoardQueryProbe.Initialize()
    if LuaEvents ~= nil and LuaEvents.CivViAccess_DebugBoardQuery ~= nil then
        LuaEvents.CivViAccess_DebugBoardQuery.Add(function(radius)
            local ok, err = pcall(function() BoardQueryProbe.Run(radius); end);
            if not ok then Log.warn("BoardQueryProbe.Run failed: " .. tostring(err)); end
        end);
        Log.info("BoardQueryProbe: armed (LuaEvents.CivViAccess_DebugBoardQuery)");
    end
end

Log.info("BoardQueryProbe.lua: loaded (throwaway design probe)");
