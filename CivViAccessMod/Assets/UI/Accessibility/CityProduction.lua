-- End-turn blocker unblock workaround (0.5.2). Civ VI gates end-turn
-- on several "you need to make a decision" popups, and none of the
-- chooser UIs (ProductionPanel, ResearchChooser, CivicsChooser) are
-- arrow-key navigable. Without programmatic defaults, a blind player
-- cannot proceed past turn 1 — production blocker, then tech blocker,
-- then civic blocker, then production again next turn.
--
-- CityProduction.unblockAll() — single hotkey (Alt+P) that handles all
-- three blocker types in one pass:
--
--   PRODUCTION (per city with empty queue):
--     1. Monument (building, no prereqs, 60 prod) — canonical first-
--        turn build, available in every fresh city.
--     2. Warrior (unit, 40 prod) — fallback if Monument unavailable.
--     3. Cheapest available building or unit — last-resort fallback
--        for mid/late-game cities.
--
--   RESEARCH (when player has no current tech):
--     Cheapest available technology (lowest Cost, CanResearch=true).
--     On turn 1 that's typically Pottery / Animal Husbandry / Mining
--     / Sailing depending on map. API: UI.RequestPlayerOperation
--     with PlayerOperations.RESEARCH.
--
--   CIVIC (when player has no current civic):
--     Cheapest available civic. Turn 1 = Code of Laws (the only
--     option, prereq for everything else). API:
--     UI.RequestPlayerOperation with PlayerOperations.PROGRESS_CIVIC.
--
-- Per-item announce ("Queued Monument in Cape Town. Researching
-- Pottery. Studying Code of Laws.").
--
-- Hotkey is Alt+P (wired in HexCursorAddin via CIVVIACCESS_UnblockProduction).
-- Name is a holdover from when this only handled production; kept for
-- continuity with the original 0.5.2 ship.
--
-- This is a TEMPORARY workaround. The full accessible pickers (arrow-
-- nav through items with cost + benefit announcement) are tasks #9
-- (production), and will follow for tech and civic. The Alt+P unblock
-- stays as a quick-default convenience even after the pickers exist.
--
-- Civ V Access analogue: CivVAccess_ChooseProductionPopupAccess.lua
-- (full pickers, no quick-default workaround).

include("Log");
include("ScreenReader");

CityProduction = CityProduction or {};

-- Engine API constants. Wrapped in pcall paths so the file doesn't
-- crash-load if a future engine rev renames anything.
local DEFAULT_BUILDING_TYPE = "BUILDING_MONUMENT";
local DEFAULT_UNIT_TYPE     = "UNIT_WARRIOR";

local function localPlayerID()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    if not ok or id == nil then return -1; end
    return id;
end

-- Returns the hash for a Buildings or Units row by Type string, or nil.
local function hashForBuilding(typeName)
    local row = GameInfo.Buildings[typeName];
    if row == nil then return nil; end
    return row.Hash;
end

local function hashForUnit(typeName)
    local row = GameInfo.Units[typeName];
    if row == nil then return nil; end
    return row.Hash;
end

-- True if the city has nothing currently producing. Engine convention:
-- GetCurrentProductionTypeHash() returns 0 when the queue is empty
-- (per ProductionPanel.lua:88 m_CurrentProductionHash = 0 default).
local function cityIsBlocked(pCity)
    if pCity == nil then return false; end
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return false; end
    local ok, hash = pcall(function() return pQueue:GetCurrentProductionTypeHash(); end);
    if not ok then return false; end
    return hash == nil or hash == 0;
end

-- Try to queue (cityCommandType, paramKey, hash). Returns the localized
-- name on success, nil on failure. Mirrors ProductionPanel.lua's
-- BuildBuilding / BuildUnit / AdvanceProject pattern.
local function queueBuilding(pCity, buildingHash, displayName)
    if buildingHash == nil then return nil; end
    local tParameters = {};
    tParameters[CityOperationTypes.PARAM_BUILDING_TYPE] = buildingHash;
    local ok = pcall(CityManager.RequestOperation, pCity, CityOperationTypes.BUILD, tParameters);
    if not ok then return nil; end
    return displayName;
end

local function queueUnit(pCity, unitHash, displayName)
    if unitHash == nil then return nil; end
    local tParameters = {};
    tParameters[CityOperationTypes.PARAM_UNIT_TYPE] = unitHash;
    local ok = pcall(CityManager.RequestOperation, pCity, CityOperationTypes.BUILD, tParameters);
    if not ok then return nil; end
    return displayName;
end

-- Iterate GameInfo.Buildings, return (hash, localizedName, cost) for the
-- cheapest buildable building in this city. Skips wonders (we want
-- something quick to complete, not a wonder commitment).
local function cheapestBuilding(pCity)
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return nil, nil, 0; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Buildings() do
        if row.IsWonder ~= true then
            local can = false;
            local okQ, result = pcall(function() return pQueue:CanProduce(row.Hash, true); end);
            if okQ and result then can = true; end
            if can then
                local cost = row.Cost or 99999;
                if bestCost == nil or cost < bestCost then
                    bestHash = row.Hash;
                    bestName = Locale.Lookup(row.Name);
                    bestCost = cost;
                end
            end
        end
    end
    return bestHash, bestName, bestCost;
end

local function cheapestUnit(pCity)
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return nil, nil, 0; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Units() do
        local can = false;
        local okQ, result = pcall(function() return pQueue:CanProduce(row.Hash, true); end);
        if okQ and result then can = true; end
        if can then
            local cost = row.Cost or 99999;
            if bestCost == nil or cost < bestCost then
                bestHash = row.Hash;
                bestName = Locale.Lookup(row.Name);
                bestCost = cost;
            end
        end
    end
    return bestHash, bestName, bestCost;
end

-- Queue a sensible default into this blocked city. Returns the queued
-- item's localized name, or nil if literally nothing could be queued
-- (shouldn't happen in normal play — every city can build at least a
-- Slinger or some building).
local function queueDefault(pCity)
    local pQueue = pCity:GetBuildQueue();
    if pQueue == nil then return nil; end

    -- Try Monument first.
    local monumentHash = hashForBuilding(DEFAULT_BUILDING_TYPE);
    if monumentHash ~= nil then
        local okQ, can = pcall(function() return pQueue:CanProduce(monumentHash, true); end);
        if okQ and can then
            return queueBuilding(pCity, monumentHash, "Monument");
        end
    end

    -- Try Warrior.
    local warriorHash = hashForUnit(DEFAULT_UNIT_TYPE);
    if warriorHash ~= nil then
        local okQ, can = pcall(function() return pQueue:CanProduce(warriorHash, true); end);
        if okQ and can then
            return queueUnit(pCity, warriorHash, "Warrior");
        end
    end

    -- Fall back to cheapest available building, then cheapest unit.
    local bHash, bName = cheapestBuilding(pCity);
    if bHash ~= nil then
        return queueBuilding(pCity, bHash, bName);
    end
    local uHash, uName = cheapestUnit(pCity);
    if uHash ~= nil then
        return queueUnit(pCity, uHash, uName);
    end

    return nil;
end

-- =======================================================================
-- Research + Civic auto-pick (the other two end-turn blockers)
-- =======================================================================

-- True if the local player needs to choose a research right now.
-- pPlayerTechs:GetResearchingTech() returns -1 (or nil in some
-- engine revs) when nothing is queued.
local function needsResearch(pPlayer)
    local pTechs = pPlayer:GetTechs();
    if pTechs == nil then return false; end
    local ok, current = pcall(function() return pTechs:GetResearchingTech(); end);
    if not ok then return false; end
    return current == nil or current < 0;
end

local function needsCivic(pPlayer)
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil then return false; end
    local ok, current = pcall(function() return pCulture:GetProgressingCivic(); end);
    if not ok then return false; end
    return current == nil or current < 0;
end

-- Iterate GameInfo.Technologies, return (hash, name) of the cheapest
-- tech the player can research right now. Cost-sorted so we don't
-- accidentally commit a multi-era boost target.
local function cheapestResearch(pPlayer)
    local pTechs = pPlayer:GetTechs();
    if pTechs == nil then return nil, nil; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Technologies() do
        local can = false;
        local okC, result = pcall(function() return pTechs:CanResearch(row.Index); end);
        if okC and result then can = true; end
        if can then
            local cost = row.Cost or 99999;
            if bestCost == nil or cost < bestCost then
                bestHash = row.Hash;
                bestName = Locale.Lookup(row.Name);
                bestCost = cost;
            end
        end
    end
    return bestHash, bestName;
end

local function cheapestCivic(pPlayer)
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil then return nil, nil; end
    local bestHash, bestName, bestCost = nil, nil, nil;
    for row in GameInfo.Civics() do
        local can = false;
        local okC, result = pcall(function() return pCulture:CanProgress(row.Index); end);
        if okC and result then can = true; end
        if can then
            local cost = row.Cost or 99999;
            if bestCost == nil or cost < bestCost then
                bestHash = row.Hash;
                bestName = Locale.Lookup(row.Name);
                bestCost = cost;
            end
        end
    end
    return bestHash, bestName;
end

-- Commit research selection. Mirrors ResearchChooser.lua:252
-- OnChooseResearch — UI.RequestPlayerOperation with the RESEARCH
-- operation. Returns the localized name on success, nil on failure.
local function setResearch(pid, techHash, displayName)
    if techHash == nil then return nil; end
    local tParameters = {};
    tParameters[PlayerOperations.PARAM_TECH_TYPE] = techHash;
    tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
    local ok = pcall(UI.RequestPlayerOperation, pid, PlayerOperations.RESEARCH, tParameters);
    if not ok then return nil; end
    return displayName;
end

-- Mirrors CivicsChooser.lua:239 OnChooseCivic.
local function setCivic(pid, civicHash, displayName)
    if civicHash == nil then return nil; end
    local tParameters = {};
    tParameters[PlayerOperations.PARAM_CIVIC_TYPE] = civicHash;
    tParameters[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
    local ok = pcall(UI.RequestPlayerOperation, pid, PlayerOperations.PROGRESS_CIVIC, tParameters);
    if not ok then return nil; end
    return displayName;
end

-- =======================================================================
-- Policy slots (the 4th end-turn blocker: NOTIFICATION_FILL_CIVIC_SLOT,
-- "A policy needs to be added to our government"). Hit live 2026-05-31:
-- a civic (Code of Laws) opened a policy slot and the turn won't end
-- until it's filled, but the Government screen isn't accessible yet.
-- Auto-fill any EMPTY slot with a legal unlocked policy so the turn can
-- end. Stopgap until a real accessible Government screen exists.
--
-- API (all UI-VM, from GovernmentScreen.lua):
--   pCulture:GetNumPolicySlots() / :GetSlotType(i) / :GetSlotPolicy(i)
--     (GetSlotPolicy returns -1 for an empty slot)
--   GameInfo.GovernmentSlots[iSlotType].GovernmentSlotType -> "SLOT_*"
--   :IsPolicyUnlocked(hash) / :IsPolicyObsolete(hash) / :IsPolicyActive(hash)
--   pCulture:RequestPolicyChanges(clearList, addList)  -- addList[slot]=hash
-- =======================================================================

-- Does the player have any empty government policy slot?
local function needsPolicy(pPlayer)
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil or pCulture.GetNumPolicySlots == nil then return false; end
    if pCulture.GetNumPolicySlotsOpen ~= nil then
        local ok, n = pcall(function() return pCulture:GetNumPolicySlotsOpen(); end);
        if ok and n ~= nil then return n > 0; end
    end
    -- Fallback: scan slots for an empty one.
    local total = pCulture:GetNumPolicySlots();
    for i = 0, total - 1 do
        local pol = pCulture:GetSlotPolicy(i);
        if pol == nil or pol < 0 then return true; end
    end
    return false;
end

-- The "SLOT_*" string accepted by a given slot index.
local function slotTypeString(pCulture, i)
    local iSlotType = pCulture:GetSlotType(i);
    local row = (iSlotType ~= nil and GameInfo.GovernmentSlots ~= nil)
                and GameInfo.GovernmentSlots[iSlotType] or nil;
    return row and row.GovernmentSlotType or nil;   -- e.g. "SLOT_MILITARY"
end

-- True if a policy (catalog row) can legally go in a slot of strSlotType.
-- Wildcard / great-person slots accept anything; otherwise exact match.
local function policyFitsSlot(policySlotType, strSlotType)
    if strSlotType == "SLOT_WILDCARD" or strSlotType == "SLOT_GREAT_PERSON" then
        return true;
    end
    return policySlotType == strSlotType;
end

-- An unlocked, non-obsolete, not-currently-active policy whose slot type
-- fits strSlotType. Returns (policyHash, displayName) or nil.
local function pickPolicyForSlot(pCulture, strSlotType, usedHashes)
    for row in GameInfo.Policies() do
        local typeRow = GameInfo.Types[row.PolicyType];
        local hash = typeRow and typeRow.Hash or nil;
        if hash ~= nil and not usedHashes[hash]
           and policyFitsSlot(row.GovernmentSlotType, strSlotType) then
            local unlocked = (pCulture.IsPolicyUnlocked == nil) or pCulture:IsPolicyUnlocked(hash);
            local obsolete = (pCulture.IsPolicyObsolete ~= nil) and pCulture:IsPolicyObsolete(hash);
            local active   = (pCulture.IsPolicyActive ~= nil) and pCulture:IsPolicyActive(hash);
            if unlocked and not obsolete and not active then
                return hash, Locale.Lookup(row.Name);
            end
        end
    end
    return nil;
end

-- Fill every empty policy slot with a legal unlocked policy. Returns a list
-- of policy display names slotted (empty if none / nothing available).
local function fillEmptyPolicySlots(pPlayer)
    local pCulture = pPlayer:GetCulture();
    if pCulture == nil or pCulture.GetNumPolicySlots == nil
       or pCulture.RequestPolicyChanges == nil then
        return {};
    end
    local total = pCulture:GetNumPolicySlots();
    Log.info("CityProduction: GetNumPolicySlots=" .. tostring(total));

    -- Mirror GovernmentScreen.lua OnConfirmPolicies_Yes EXACTLY: build a
    -- clearList of EVERY slot and an addList of the policy for every slot
    -- (existing slots re-add their current policy; empty slots get a new one).
    -- The earlier version passed clearList={} and added only empties — the
    -- engine silently ignored it (blocker persisted, no error). The game always
    -- does a full clear-and-reapply, so we do too. (clearList = array of slot
    -- indices; addList[slotIndex] = policyHash.)
    local clearList = {};      -- array: every slot index
    local addList = {};        -- addList[slotIndex] = policyHash (keep or new)
    local usedHashes = {};     -- don't slot the same NEW policy twice
    local names = {};          -- names of NEWLY filled policies (for announce)
    local filledAny = false;

    for i = 0, total - 1 do
        local cur = pCulture:GetSlotPolicy(i);    -- policy row index, -1 if empty
        local strSlotType = slotTypeString(pCulture, i);
        Log.info("CityProduction: slot " .. i .. " type=" .. tostring(strSlotType)
                 .. " current=" .. tostring(cur));

        table.insert(clearList, i);   -- clear EVERY slot (game does this)

        if cur ~= nil and cur >= 0 then
            -- Occupied: re-add its current policy so we don't wipe it.
            local row = GameInfo.Policies[cur];
            local typeRow = row and GameInfo.Types[row.PolicyType] or nil;
            if typeRow ~= nil then
                addList[i] = typeRow.Hash;
                usedHashes[typeRow.Hash] = true;
            end
        elseif strSlotType ~= nil then
            -- Empty: pick a legal unlocked policy to fill it.
            local hash, name = pickPolicyForSlot(pCulture, strSlotType, usedHashes);
            if hash ~= nil then
                addList[i] = hash;
                usedHashes[hash] = true;
                names[#names + 1] = name;
                filledAny = true;
                Log.info("CityProduction: filling slot " .. i .. " ("
                         .. strSlotType .. ") with '" .. tostring(name) .. "'");
            else
                Log.warn("CityProduction: no unlocked policy fits empty slot "
                         .. i .. " (" .. tostring(strSlotType) .. ")");
            end
        end
    end

    if not filledAny then return {}; end
    local ok, err = pcall(function() pCulture:RequestPolicyChanges(clearList, addList); end);
    if not ok then
        Log.warn("CityProduction: RequestPolicyChanges failed: " .. tostring(err));
        return {};
    end
    Log.info("CityProduction: RequestPolicyChanges committed (" .. #clearList
             .. " slots cleared, " .. #names .. " new policies)");
    return names;
end

-- =======================================================================
-- Rock band (debug + playability): a rock band sits as a COMMAND_UNITS
-- end-turn blocker until it acts. A concert (TOURISM_BOMB) only has valid
-- targets when the band is ADJACENT to a foreign city; PlaceUnit can't drop
-- it into foreign territory, so the debug generator lands it a few hexes out.
-- So: if the band can perform (has activation plots) -> perform the concert
-- (fires real PostTourismBomb -> the reveal gate); else MOVE_TO toward the
-- nearest foreign city (gives it an order = unblocks, AND walks it into range
-- over a turn or two — rock bands legally enter foreign territory). Runs in the
-- HexCursorAddin UI context, which HAS UnitManager + UnitOperationTypes (same as
-- UnitMovement.lua). Returns a short status string or nil.
-- =======================================================================

-- Operation/param hash, enum-or-fallback (UnitOperationTypes may be absent in
-- some contexts; GameInfo.UnitOperations[name].Hash and DB.MakeHash always work).
local function unitOpHash(name, enumKey)
    if UnitOperationTypes ~= nil and UnitOperationTypes[enumKey] ~= nil then
        return UnitOperationTypes[enumKey];
    end
    if GameInfo ~= nil and GameInfo.UnitOperations ~= nil
       and GameInfo.UnitOperations[name] ~= nil then
        return GameInfo.UnitOperations[name].Hash;
    end
    if DB ~= nil and DB.MakeHash ~= nil then return DB.MakeHash(name); end
    return nil;
end

local function nearestForeignCityFrom(lp, bx, by)
    local bestX, bestY, bestD = nil, nil, nil;
    for i = 0, 63 do
        local p = Players ~= nil and Players[i] or nil;
        if p ~= nil and i ~= lp and (p.IsAlive == nil or p:IsAlive()) and p.GetCities ~= nil then
            local cs = p:GetCities();
            if cs ~= nil then
                for _, c in cs:Members() do
                    if c ~= nil then
                        local cx, cy = c:GetX(), c:GetY();
                        local d = (Map ~= nil and Map.GetPlotDistance)
                                  and Map.GetPlotDistance(bx, by, cx, cy)
                                  or (math.abs(cx - bx) + math.abs(cy - by));
                        if bestD == nil or d < bestD then bestX, bestY, bestD = cx, cy, d; end
                    end
                end
            end
        end
    end
    return bestX, bestY;
end

-- The first activation (concert-target) plot for a rock band, or nil.
local function bandConcertPlot(u)
    local rb = u.GetRockBand and u:GetRockBand() or nil;
    if rb == nil or rb.GetActivationHighlightPlots == nil then return nil, nil; end
    local plots = rb:GetActivationHighlightPlots();
    if plots ~= nil and #plots > 0 and Map ~= nil and Map.GetPlotByIndex ~= nil then
        local p = Map.GetPlotByIndex(plots[1]);
        if p ~= nil then return p:GetX(), p:GetY(); end
    end
    return nil, nil;
end

-- A passable LAND hex adjacent to the city (cx,cy), nearest to (fromX,fromY) so
-- the move path is shortest. You CANNOT MOVE_TO an enemy city CENTER (the band
-- just no-ops and stays "ready", keeping the end-turn blocker — root-caused
-- 2026-05-31). A band must stand ADJACENT to concert anyway, so we path to an
-- adjacent tile it can actually occupy. Returns (x,y) or nil.
local function adjacentPassableHex(cx, cy, fromX, fromY)
    if Map == nil or Map.GetAdjacentPlot == nil then return nil; end
    local ndir = (DirectionTypes ~= nil and DirectionTypes.NUM_DIRECTION_TYPES) or 6;
    local bestX, bestY, bestD = nil, nil, nil;
    for dir = 0, ndir - 1 do
        local p = Map.GetAdjacentPlot(cx, cy, dir);
        if p ~= nil then
            local water = (p.IsWater ~= nil) and p:IsWater() or false;
            local impassable = (p.IsImpassable ~= nil) and p:IsImpassable() or false;
            if not water and not impassable then
                local px, py = p:GetX(), p:GetY();
                local d = (Map.GetPlotDistance ~= nil)
                          and Map.GetPlotDistance(px, py, fromX, fromY)
                          or (math.abs(px - fromX) + math.abs(py - fromY));
                if bestD == nil or d < bestD then bestX, bestY, bestD = px, py, d; end
            end
        end
    end
    return bestX, bestY;
end

-- Perform-or-move the player's rock band. Returns a status string or nil.
local function handleRockBand(pid, pPlayer)
    if UnitManager == nil or UnitManager.RequestOperation == nil then return nil; end
    if GameInfo == nil or GameInfo.Units == nil or GameInfo.Units["UNIT_ROCK_BAND"] == nil then return nil; end
    local rbIdx = GameInfo.Units["UNIT_ROCK_BAND"].Index;
    local pUnits = pPlayer:GetUnits();
    if pUnits == nil then return nil; end

    -- NORMAL-PLAY behavior (2026-05-31): just SKIP the band's turn so it stops
    -- blocking end-turn, WITHOUT hijacking it on a concert mission. Alt+P is the
    -- generic "let me end my turn" key — it must NOT march the player's real rock
    -- band off toward a foreign city. The player keeps control; real rock-band
    -- support will go through a deliberate command, not this fallback. The concert
    -- auto-drive logic was the DebugConcert test rig (now flag-off).
    for _, u in pUnits:Members() do
        local t = (u.GetUnitType and u:GetUnitType()) or (u.GetType and u:GetType());
        if t == rbIdx then
            local hSkip = unitOpHash("UNITOPERATION_SKIP_TURN", "SKIP_TURN");
            if hSkip ~= nil then
                pcall(function() UnitManager.RequestOperation(u, hSkip, {}); end);
                Log.info("CityProduction: rock band skipped (cleared blocker; player keeps control)");
                return "Rock band turn skipped";
            end
            return nil;
        end
    end
    return nil;
end

-- =======================================================================
-- Top-level: clear every end-turn blocker we know how to default
-- =======================================================================

function CityProduction.unblockAll()
    local pid = localPlayerID();
    if pid < 0 then
        Speech.emit("No active player", "meta");
        return;
    end
    local pPlayer = Players[pid];
    if pPlayer == nil then
        Speech.emit("Player not available", "meta");
        return;
    end
    local pCities = pPlayer:GetCities();
    if pCities == nil then
        Speech.emit("No cities", "meta");
        return;
    end

    -- Count cities up front. If zero, the whole point of "unblock
    -- end-turn" is moot: research / civic without a city generate 0
    -- science / 0 culture per turn so auto-picking them is misleading
    -- ("Research set to Pottery" when nothing is actually researching).
    -- Found a city first, then this hotkey makes sense. Per Noel
    -- 2026-05-26.
    local cityCount = 0;
    for _ in pCities:Members() do
        cityCount = cityCount + 1;
    end
    if cityCount == 0 then
        Speech.emit("No cities to unblock. Found a city first.", "meta");
        return;
    end

    -- Pass 1: production. Iterate cities, queue defaults into any
    -- city with an empty production queue.
    local queued = {};
    local skipped = 0;
    for _, pCity in pCities:Members() do
        if cityIsBlocked(pCity) then
            local cityName = Locale.Lookup(pCity:GetName());
            local queuedName = queueDefault(pCity);
            if queuedName ~= nil then
                table.insert(queued, queuedName .. " in " .. cityName);
                Log.info("CityProduction.unblockAll: queued " .. queuedName
                         .. " in " .. cityName);
            else
                skipped = skipped + 1;
                Log.warn("CityProduction.unblockAll: could not queue anything in "
                         .. cityName);
            end
        end
    end

    -- Pass 2: research. If no current tech, pick the cheapest
    -- available and commit it.
    local researchPicked = nil;
    if needsResearch(pPlayer) then
        local tHash, tName = cheapestResearch(pPlayer);
        if tHash ~= nil then
            researchPicked = setResearch(pid, tHash, tName);
            if researchPicked ~= nil then
                Log.info("CityProduction.unblockAll: researching " .. researchPicked);
            end
        end
    end

    -- Pass 3: civic.
    local civicPicked = nil;
    if needsCivic(pPlayer) then
        local cHash, cName = cheapestCivic(pPlayer);
        if cHash ~= nil then
            civicPicked = setCivic(pid, cHash, cName);
            if civicPicked ~= nil then
                Log.info("CityProduction.unblockAll: studying " .. civicPicked);
            end
        end
    end

    -- Pass 4: government policy slots (NOTIFICATION_FILL_CIVIC_SLOT blocker).
    -- Auto-fill empties so the turn can end; stopgap until the Government
    -- screen is accessible. See fillEmptyPolicySlots + project_governors_panel_gap.
    local policiesSlotted = {};
    if needsPolicy(pPlayer) then
        policiesSlotted = fillEmptyPolicySlots(pPlayer);
    end

    -- Pass 5: rock band (COMMAND_UNITS blocker / concert test). Perform the
    -- concert if in range, else move toward a foreign city. See handleRockBand.
    local rbStatus = handleRockBand(pid, pPlayer);

    -- Announce. Order: production first, then research, then civic,
    -- then skip count. All routed as event kind; the gateway queues
    -- same-kind-back-to-back automatically (event coalesce=false), so
    -- we don't need the prior `spoke`-flag NOINTERRUPT bookkeeping.
    --
    -- Speech actor must be explicit per line. Earlier wording
    -- ("Queued Warrior in Cape Town. Researching Pottery.") read to
    -- Noel as a single phrase — "Warrior researching Pottery" — and
    -- gave him the mental model that the unit was doing the research.
    -- City-level + civ-level actions sound continuous in Tolk's
    -- rapid-fire delivery; subject prefix per line resolves it.
    local spoke = false;

    if #queued == 1 then
        Speech.emit("Queued " .. queued[1], "event");
        spoke = true;
    elseif #queued > 1 then
        Speech.emit("Queued " .. tostring(#queued) .. " cities. "
                    .. table.concat(queued, ", "), "event");
        spoke = true;
    end

    if researchPicked ~= nil then
        Speech.emit("Research set to " .. researchPicked, "event");
        spoke = true;
    end
    if civicPicked ~= nil then
        Speech.emit("Civic set to " .. civicPicked, "event");
        spoke = true;
    end

    if #policiesSlotted == 1 then
        Speech.emit("Policy added: " .. policiesSlotted[1], "event");
        spoke = true;
    elseif #policiesSlotted > 1 then
        Speech.emit(tostring(#policiesSlotted) .. " policies added: "
                    .. table.concat(policiesSlotted, ", "), "event");
        spoke = true;
    end

    if rbStatus ~= nil then
        Speech.emit(rbStatus, "event");
        spoke = true;
    end

    if skipped > 0 then
        Speech.emit(tostring(skipped) .. " cities had nothing to queue",
                    "meta");
        spoke = true;
    end

    if not spoke then
        Speech.emit("No blockers to clear", "meta");
    end
end

local function Initialize()
    Log.info("CityProduction.lua: loaded");
end
Initialize();
