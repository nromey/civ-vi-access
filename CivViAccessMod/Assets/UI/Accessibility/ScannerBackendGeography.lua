-- ScannerBackendGeography.lua — scanner backend for GEOGRAPHY: landmasses and
-- oceans, as the player has actually explored them.
--
-- HYBRID approach (Noel 2026-06-09): flood-fill the REVEALED tiles you've
-- connected by exploring into contiguous components (6-neighbor hex adjacency),
-- then NAME each land component by its dominant engine continent
-- (GetContinentType -> GameInfo.Continents). So a landmass reads "Africa,
-- 40 hexes" — the grouping matches what you've uncovered, and the label is the
-- real continent name when one dominates. Land components with no clean
-- continent (or a duplicate name) fall back to "Landmass N". Oceans have no
-- engine names, so they're numbered "Ocean N". Both number by distance from your
-- capital (then any city, then any unit).
--
-- Lakes are skipped (they're terrain features, not geography). Only REVEALED
-- tiles count — the hex totals never leak fog.
--
-- Cluster-style backend: each component is ONE entry whose entry.data.plots holds
-- every member tile. ValidateEntry re-centers entry.plotIndex on the nearest
-- still-revealed member to the cursor, so snapping to "Africa" lands you on the
-- closest bit of it. Rich data (plots/count/continent) is retained for a future
-- map-overview / placement layer (see project_placement_preview_vision).

include("Log");
include("ScannerCore");

ScannerBackendGeography = { name = "geography" };

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

-- "land" / "water" / nil. nil = not part of geography (unrevealed, or a lake).
local function domainOf(plot, vis)
    if plot == nil then return nil; end
    if not revealed(vis, plot:GetX(), plot:GetY()) then return nil; end
    local isWater = (plot.IsWater ~= nil) and plot:IsWater() or false;
    if isWater then
        local isLake = (plot.IsLake ~= nil) and plot:IsLake() or false;
        if isLake then return nil; end
        return "water";
    end
    return "land";
end

-- Iterative flood-fill from a start plot over same-domain revealed neighbors.
-- Marks visited[index]=true for every member. Returns the array of member indices.
local function floodFill(startIdx, startPlot, dom, vis, visited)
    local members = {};
    local stack = { { startIdx, startPlot } };
    visited[startIdx] = true;
    while #stack > 0 do
        local top = stack[#stack]; stack[#stack] = nil;
        local idx, plot = top[1], top[2];
        members[#members + 1] = idx;
        local x, y = plot:GetX(), plot:GetY();
        for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
            local np = Map.GetAdjacentPlot(x, y, dir);
            if np ~= nil then
                local ni = np:GetIndex();
                if ni ~= nil and not visited[ni] and domainOf(np, vis) == dom then
                    visited[ni] = true;
                    stack[#stack + 1] = { ni, np };
                end
            end
        end
    end
    return members;
end

-- Dominant continent name across a land component's member tiles, or nil.
local function dominantContinentName(members)
    local tally = {};
    local best, bestCount = nil, 0;
    for _, idx in ipairs(members) do
        local p = Map.GetPlotByIndex(idx);
        if p ~= nil and p.GetContinentType ~= nil then
            local ct = p:GetContinentType();
            if ct ~= nil and ct ~= -1 then
                tally[ct] = (tally[ct] or 0) + 1;
                if tally[ct] > bestCount then bestCount = tally[ct]; best = ct; end
            end
        end
    end
    if best == nil then return nil; end
    local ok, row = pcall(function() return GameInfo.Continents[best]; end);
    if ok and row ~= nil and row.Description ~= nil then
        return Locale.Lookup(row.Description);
    end
    return nil;
end

-- Reference plot (x,y) for numbering: capital -> any city -> any unit -> (0,0).
local function referenceXY(localId)
    local player = Players and Players[localId] or nil;
    if player ~= nil then
        if player.GetCities ~= nil then
            local ok, cities = pcall(function() return player:GetCities(); end);
            if ok and cities ~= nil and cities.Members ~= nil then
                local cap = nil;
                for _, c in cities:Members() do
                    if c ~= nil then
                        if cap == nil then cap = c; end
                        if c.IsCapital ~= nil then
                            local ic = false;
                            pcall(function() ic = c:IsCapital(); end);
                            if ic then return c:GetX(), c:GetY(); end
                        end
                    end
                end
                if cap ~= nil then return cap:GetX(), cap:GetY(); end
            end
        end
        if player.GetUnits ~= nil then
            local ok, units = pcall(function() return player:GetUnits(); end);
            if ok and units ~= nil and units.Members ~= nil then
                for _, u in units:Members() do
                    if u ~= nil then return u:GetX(), u:GetY(); end
                end
            end
        end
    end
    return 0, 0;
end

-- For a component, find (representative index nearest the reference, min distance,
-- smallest member index for a stable key).
local function componentStats(members, refX, refY)
    local repIdx, repDist, minIdx = members[1], nil, members[1];
    for _, idx in ipairs(members) do
        if idx < minIdx then minIdx = idx; end
        local p = Map.GetPlotByIndex(idx);
        if p ~= nil then
            local d = Map.GetPlotDistance(p:GetX(), p:GetY(), refX, refY);
            if repDist == nil or d < repDist then repDist = d; repIdx = idx; end
        end
    end
    return repIdx, (repDist or 0), minIdx;
end

function ScannerBackendGeography.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 then return out; end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
    local refX, refY = referenceXY(localId);

    -- 1. Flood-fill all revealed land/water into components.
    local visited = {};
    local comps = { land = {}, water = {} };
    local n = plotCount();
    for i = 0, n - 1 do
        if not visited[i] then
            local plot = Map.GetPlotByIndex(i);
            local dom = domainOf(plot, vis);
            if dom ~= nil then
                local members = floodFill(i, plot, dom, vis, visited);
                local repIdx, dist, minIdx = componentStats(members, refX, refY);
                comps[dom][#comps[dom] + 1] = {
                    members = members, count = #members,
                    repIdx = repIdx, dist = dist, minIdx = minIdx,
                    continentName = (dom == "land") and dominantContinentName(members) or nil,
                };
            end
        end
    end

    -- 2. Number each domain by distance from the reference (nearest first).
    local function byDist(a, b) return a.dist < b.dist; end
    table.sort(comps.land, byDist);
    table.sort(comps.water, byDist);

    -- 3. Emit one entry per component. Land uses the continent name when it's
    --    present and unique; otherwise "Landmass N". Oceans are "Ocean N".
    local usedNames = {};
    for ord, c in ipairs(comps.land) do
        local name;
        if c.continentName ~= nil and not usedNames[c.continentName] then
            name = c.continentName;
            usedNames[c.continentName] = true;
        elseif c.continentName ~= nil then
            name = c.continentName .. " " .. ord;   -- disambiguate a repeated continent
        else
            name = "Landmass " .. ord;
        end
        out[#out + 1] = {
            plotIndex   = c.repIdx,
            category    = "geography",
            subcategory = "landmasses",
            itemName    = name,
            key         = "geo:land:" .. c.minIdx,
            data        = { plots = c.members, count = c.count, name = name,
                            continentName = c.continentName },
        };
    end
    for ord, c in ipairs(comps.water) do
        local name = "Ocean " .. ord;
        out[#out + 1] = {
            plotIndex   = c.repIdx,
            category    = "geography",
            subcategory = "oceans",
            itemName    = name,
            key         = "geo:water:" .. c.minIdx,
            data        = { plots = c.members, count = c.count, name = name },
        };
    end
    return out;
end

-- Cluster-style: re-center plotIndex on the nearest still-revealed member to the
-- cursor. cursorPlotHint is a plot index (may be nil). Returns false only if the
-- whole component has somehow gone unrevealed.
function ScannerBackendGeography.ValidateEntry(entry, cursorPlotHint)
    if entry.data == nil or entry.data.plots == nil or Map == nil then return false; end
    local localId = localPlayerId();
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;

    local cx, cy = nil, nil;
    if type(cursorPlotHint) == "number" and Map.GetPlotByIndex ~= nil then
        local cp = Map.GetPlotByIndex(cursorPlotHint);
        if cp ~= nil then cx, cy = cp:GetX(), cp:GetY(); end
    end

    local best, bestDist = nil, nil;
    for _, idx in ipairs(entry.data.plots) do
        local p = Map.GetPlotByIndex(idx);
        if p ~= nil and revealed(vis, p:GetX(), p:GetY()) then
            if cx == nil then best = idx; break; end
            local d = Map.GetPlotDistance(p:GetX(), p:GetY(), cx, cy);
            if bestDist == nil or d < bestDist then bestDist = d; best = idx; end
        end
    end
    if best == nil then return false; end
    entry.plotIndex = best;
    return true;
end

function ScannerBackendGeography.FormatName(entry)
    local d = entry.data;
    local name = (d and d.name) or entry.itemName or "area";
    if d and d.count then
        return name .. ", " .. d.count .. " hexes";
    end
    return name;
end

Scanner.registerBackend(ScannerBackendGeography);

Log.info("ScannerBackendGeography.lua: loaded");
