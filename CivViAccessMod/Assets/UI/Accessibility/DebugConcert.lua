-- ===========================================================================
--  DebugConcert.lua — manufacture a real rock-band concert on demand.
--
--  WHY: the RockBand reveal can only be exercised by the engine event
--  Events.PostTourismBomb, which Lua can't raise directly — it fires when the
--  gamecore RESOLVES a concert (UNITOPERATION_TOURISM_BOMB). This rig creates a
--  band and gets it into position so the operation can fire, raising the real
--  PostTourismBomb (vanilla popup + our RevealListeners gate).
--
--  SPLIT-VM (root-caused 2026-05-31, see reference_civ_vi_vm_split):
--    * THIS file is a GameCore (gameplay) script (<AddGameplayScripts>). It has
--      the unit-CREATION + PLACEMENT API (InitUnit*, PlaceUnit, Kill) but NOT
--      RequestOperation/UnitOperationTypes.
--    * RevealListeners.lua (UI VM) has RequestOperation and PERFORMS the concert.
--    * No cross-VM messaging: both hook Events.LocalPlayerTurnBegin (fires in
--      both VMs); the band this VM positions on turn N is enumerable + performable
--      by the UI VM on turn N+1.
--
--  PLACEMENT (root-caused 2026-05-31): InitUnitValidAdjacentHex around an ENEMY
--  city leaves the band OFF-MAP at (-9999,-9999) — you can't place a unit into
--  foreign territory, so no valid adjacent hex exists. Fix: spawn near OUR OWN
--  city (always valid), then PlaceUnit (force-teleport, like AustraliaScenario)
--  the band onto a land hex ADJACENT to the foreign city. Then it has a concert
--  target. PlaceUnit is permanent; the UI performs next turn on fresh moves.
--
--  HOW TO USE: relaunch, load/new game, then END TURNS. Sequence (auto, no
--  manual movement):
--    turn A: ghost cleanup + spawn a band near our capital;
--    turn B: teleport that band adjacent to the foreign city;
--    turn C: UI VM performs the concert -> the rock-band gate speaks.
--  Watch Lua.log "[DebugConcert]" then "concert UI:".
--
--  Debug-only. DEBUG_CONCERT_ENABLED=false (or remove from modinfo) to disable.
-- ===========================================================================

-- OFF by default (2026-05-31): the concert pipeline is engine-validated
-- (CanStartOperation(TOURISM_BOMB)=true); only a live PostTourismBomb is
-- unconfirmed, blocked by manufacturing a tourism building in an ancient-era
-- foreign city. Decided to validate the cinematic on a natural late-game save.
-- Flip to true (then relaunch) to re-run the spawn + walk + venue-grant rig.
local DEBUG_CONCERT_ENABLED = false;

local m_done = false;   -- latch once the band is positioned adjacent

local function log(msg)
    if Log ~= nil and Log.info ~= nil then
        Log.info("[DebugConcert] " .. tostring(msg));
    else
        print("[CivViAccess][DebugConcert] " .. tostring(msg));
    end
end

-- ---------------------------------------------------------------------------
--  Helpers
-- ---------------------------------------------------------------------------
local function isRockBand(u)
    if u == nil then return false; end
    local t = (u.GetUnitType and u:GetUnitType()) or (u.GetType and u:GetType());
    if t == nil or GameInfo == nil or GameInfo.Units == nil then return false; end
    local row = GameInfo.Units[t];
    return row ~= nil and row.UnitType == "UNIT_ROCK_BAND";
end

-- True when a unit is actually on the map (not the (-9999,-9999) limbo sentinel).
local function isOnMap(u)
    return u ~= nil and u.GetX ~= nil and u:GetX() ~= nil and u:GetX() > -1;
end

-- Our capital (preferred) or first city — spawn the band adjacent to it because
-- placement in our OWN territory always succeeds.
local function ownCity(pPlayer)
    if pPlayer == nil or pPlayer.GetCities == nil then return nil; end
    local cities = pPlayer:GetCities();
    if cities == nil then return nil; end
    local first = nil;
    for _, c in cities:Members() do
        if c ~= nil then
            if first == nil then first = c; end
            if c.IsCapital and c:IsCapital() then return c; end
        end
    end
    return first;
end

-- First city NOT owned by lp (city-states included → exists from turn 1). The
-- gameplay API sees through fog. Returns the city or nil.
local function findForeignCity(lp)
    if PlayerManager ~= nil and PlayerManager.GetAliveMajors ~= nil then
        for _, p in ipairs(PlayerManager.GetAliveMajors()) do
            if p ~= nil and p:GetID() ~= lp and p.GetCities ~= nil then
                local cities = p:GetCities();
                if cities ~= nil then
                    for _, c in cities:Members() do if c ~= nil then return c, "major civ"; end end
                end
            end
        end
    end
    for i = 0, 63 do
        local p = Players ~= nil and Players[i] or nil;
        if p ~= nil and i ~= lp and (p.IsAlive == nil or p:IsAlive()) and p.GetCities ~= nil then
            local cities = p:GetCities();
            if cities ~= nil then
                for _, c in cities:Members() do if c ~= nil then return c, "non-major"; end end
            end
        end
    end
    return nil;
end

-- A passable LAND hex adjacent to (cx,cy) — where a land unit (rock band) can
-- legally sit. Pointy-top hex = 6 neighbors. Returns (x, y) or nil.
local function adjacentLandHex(cx, cy)
    if Map == nil or Map.GetAdjacentPlot == nil then return nil; end
    local ndir = (DirectionTypes ~= nil and DirectionTypes.NUM_DIRECTION_TYPES) or 6;
    for dir = 0, ndir - 1 do
        local p = Map.GetAdjacentPlot(cx, cy, dir);
        if p ~= nil then
            local water = (p.IsWater ~= nil) and p:IsWater() or false;
            local impassable = (p.IsImpassable ~= nil) and p:IsImpassable() or false;
            if not water and not impassable then
                return p:GetX(), p:GetY();
            end
        end
    end
    return nil;
end

local function plotDist(x1, y1, x2, y2)
    if Map ~= nil and Map.GetPlotDistance ~= nil then
        return Map.GetPlotDistance(x1, y1, x2, y2);
    end
    return math.abs(x2 - x1) + math.abs(y2 - y1);
end

-- Collect the player's rock bands, split into on-map and ghosts (off-map limbo).
local function collectBands(pPlayer)
    local onMap, ghosts = {}, {};
    if pPlayer == nil or pPlayer.GetUnits == nil then return onMap, ghosts; end
    local pUnits = pPlayer:GetUnits();
    if pUnits == nil then return onMap, ghosts; end
    for _, u in pUnits:Members() do
        if isRockBand(u) then
            if isOnMap(u) then onMap[#onMap + 1] = u; else ghosts[#ghosts + 1] = u; end
        end
    end
    return onMap, ghosts;
end

-- ---------------------------------------------------------------------------
--  Venue grant (the ACTUAL blocker, root-caused 2026-05-31): a rock band can
--  only concert a city that has a TOURISM building (Amphitheater/Arena/etc.,
--  see Building_TourismBombs_XP2). An Ancient-era city has none, so the concert
--  op is valid (CanStartOperation=true) but has ZERO activation plots. Grant the
--  nearest foreign city a Theater district + Amphitheater so a venue exists.
--  API: pCity:GetBuildQueue():CreateIncompleteDistrict / CreateIncompleteBuilding
--  (TunerCityPanel.lua) — construction 100 = complete. PrereqDistrict for
--  Amphitheater is DISTRICT_THEATER (Buildings.xml:113).
-- ---------------------------------------------------------------------------
local m_venueGranted = false;

local function nearestForeignCityFrom(lp, bx, by)
    local best, bestX, bestY, bestD = nil, nil, nil, nil;
    for i = 0, 63 do
        local p = Players ~= nil and Players[i] or nil;
        if p ~= nil and i ~= lp and (p.IsAlive == nil or p:IsAlive()) and p.GetCities ~= nil then
            local cs = p:GetCities();
            if cs ~= nil then
                for _, c in cs:Members() do
                    if c ~= nil then
                        local cx, cy = c:GetX(), c:GetY();
                        local d = plotDist(bx, by, cx, cy);
                        if bestD == nil or d < bestD then best, bestX, bestY, bestD = c, cx, cy, d; end
                    end
                end
            end
        end
    end
    return best;
end

-- True if the city already has any tourism-bomb building (a valid concert venue).
local function cityHasVenue(pCity)
    local pCityBuildings = pCity.GetBuildings and pCity:GetBuildings() or nil;
    if pCityBuildings == nil or pCityBuildings.HasBuilding == nil then return false; end
    if GameInfo == nil or GameInfo.Building_TourismBombs_XP2 == nil then return false; end
    for row in GameInfo.Building_TourismBombs_XP2() do
        local b = GameInfo.Buildings[row.BuildingType];
        if b ~= nil then
            local ok, has = pcall(function() return pCityBuildings:HasBuilding(b.Index); end);
            if ok and has then return true; end
        end
    end
    return false;
end

-- Grant the nearest foreign city a Theater district + Amphitheater (a venue).
-- Returns true once granted (or already present). One-shot via m_venueGranted.
local function grantVenueToNearestForeignCity(lp, fromX, fromY)
    if m_venueGranted then return true; end
    local pCity = nearestForeignCityFrom(lp, fromX, fromY);
    if pCity == nil then log("venue: no foreign city to grant a venue to"); return false; end
    local cx, cy = pCity:GetX(), pCity:GetY();
    if cityHasVenue(pCity) then
        log("venue: city (" .. cx .. "," .. cy .. ") already has a tourism building");
        m_venueGranted = true; return true;
    end
    local bq = pCity.GetBuildQueue and pCity:GetBuildQueue() or nil;
    if bq == nil or bq.CreateIncompleteDistrict == nil or bq.CreateIncompleteBuilding == nil then
        log("venue: GetBuildQueue/CreateIncomplete* unavailable in this VM"); return false;
    end
    -- District needs a plot. Use a passable hex adjacent to the city center.
    local ax, ay = adjacentLandHex(cx, cy);
    local cityPlotIdx = (Map ~= nil and Map.GetPlot ~= nil) and Map.GetPlot(cx, cy) or nil;
    cityPlotIdx = cityPlotIdx and cityPlotIdx:GetIndex() or nil;
    local distPlot = (ax ~= nil and Map ~= nil and Map.GetPlot ~= nil) and Map.GetPlot(ax, ay) or nil;
    local distPlotIdx = distPlot and distPlot:GetIndex() or cityPlotIdx;
    if distPlotIdx == nil then log("venue: no plot index for district"); return false; end
    local dTheater = GameInfo.Districts and GameInfo.Districts["DISTRICT_THEATER"];
    local bAmphi   = GameInfo.Buildings and GameInfo.Buildings["BUILDING_AMPHITHEATER"];
    if dTheater == nil or bAmphi == nil then log("venue: Theater/Amphitheater not in GameInfo"); return false; end
    pcall(function() bq:CreateIncompleteDistrict(dTheater.Index, distPlotIdx, 100); end);
    -- Building goes in the city (CreateIncompleteBuilding takes the city-center plot).
    pcall(function() bq:CreateIncompleteBuilding(bAmphi.Index, cityPlotIdx or distPlotIdx, 100); end);
    log("venue: granted Theater district + Amphitheater to city (" .. cx .. "," .. cy
        .. ") on plot " .. tostring(distPlotIdx));
    m_venueGranted = true;
    return true;
end

-- ---------------------------------------------------------------------------
--  Main tick
-- ---------------------------------------------------------------------------
local function tickConcert()
    if Game == nil or Game.GetLocalPlayer == nil then log("no Game API in this VM"); return false; end
    local lp = Game.GetLocalPlayer();
    if lp == nil or lp < 0 then log("no local player"); return false; end
    local pPlayer = Players ~= nil and Players[lp] or nil;
    if pPlayer == nil then log("no local player object"); return false; end
    if UnitManager == nil or UnitManager.InitUnitValidAdjacentHex == nil then
        log("InitUnitValidAdjacentHex unavailable HERE — wrong VM; cannot spawn"); return false;
    end

    local onMap, ghosts = collectBands(pPlayer);
    log("bands: onMap=" .. #onMap .. " ghosts(off-map)=" .. #ghosts);

    -- Cleanup: kill off-map ghost bands (clutter + possible end-turn blockers)
    -- and any extra on-map bands beyond the one we'll use. Collect-then-kill so
    -- we don't mutate the unit list mid-iteration.
    if UnitManager.Kill ~= nil then
        for _, g in ipairs(ghosts) do pcall(function() UnitManager.Kill(g); end); end
        for i = 2, #onMap do pcall(function() UnitManager.Kill(onMap[i]); end); end
        if #ghosts > 0 or #onMap > 1 then
            log("cleanup: killed " .. #ghosts .. " ghost(s) + " .. math.max(0, #onMap - 1) .. " extra on-map band(s)");
        end
    end

    local band = onMap[1];

    -- No usable band -> spawn one in OUR territory (valid placement, real coords).
    if band == nil then
        local cap = ownCity(pPlayer);
        if cap == nil then log("no own city to spawn near — found a city yet?"); return false; end
        log("spawn: placing band near our city at (" .. cap:GetX() .. "," .. cap:GetY() .. ") radius 2");
        pcall(function() UnitManager.InitUnitValidAdjacentHex(lp, "UNIT_ROCK_BAND", cap:GetX(), cap:GetY(), 2); end);
        log("spawn: done (band enumerable next turn; will teleport it then)");
        return false;
    end

    -- A band exists -> HANDS OFF. Earlier this teleported toward findForeignCity
    -- (first major, 33,27) while the UI auto-walk drove toward the NEAREST city
    -- (Zanzibar 24,21) — the two fought over the band every turn, so it never sat
    -- adjacent WITH moves (root-caused 2026-05-31). Now the UI side is the SOLE
    -- driver (walk-to-nearest-city + perform). Gameplay's only job is the initial
    -- spawn; once a band exists it just logs state and latches.
    local bx, by = band:GetX(), band:GetY();
    local moves = (band.GetMovesRemaining and band:GetMovesRemaining()) or "?";
    -- Grant a concert VENUE to the nearest foreign city (same city the UI side
    -- walks toward) — the real blocker: no tourism building = no activation plot.
    grantVenueToNearestForeignCity(lp, bx, by);
    log("band id=" .. tostring(band:GetID()) .. " at (" .. bx .. "," .. by
        .. ") movesRemaining=" .. tostring(moves) .. " — UI side drives; gameplay hands off");
    return true;   -- latch; UI side does walk + perform
end

-- Self-trigger: the engine fires LocalPlayerTurnBegin in THIS (GameCore) VM.
local function onLocalTurnBegin()
    if not DEBUG_CONCERT_ENABLED or m_done then return; end
    log("LocalPlayerTurnBegin -> concert tick");
    local ok, positioned = pcall(tickConcert);
    if not ok then log("error: " .. tostring(positioned)); return; end
    if positioned then
        m_done = true;
        log("band positioned — gameplay side done; UI VM performs the concert");
    end
end

if DEBUG_CONCERT_ENABLED and Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
    Events.LocalPlayerTurnBegin.Add(onLocalTurnBegin);
    log("DebugConcert armed: spawn-near-capital + teleport-adjacent on LocalPlayerTurnBegin (GameCore VM)");
else
    log("DebugConcert.lua loaded (disabled or no Events.LocalPlayerTurnBegin)");
end
