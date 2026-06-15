-- EotReport.lua — end-of-turn report: "what happened last turn", rendered in
-- the launcher's Edge app-mode browser window via the report bridge
-- ([[Report]] / docs/REPORT_BRIDGE.md). The bridge's second real consumer
-- (sibling to EmpireStatus.lua — that one is a NOW snapshot, this is DELTA).
--
-- Speaks the "press N" availability hint exactly ONCE (the first turn a
-- report exists), then stays silent — the report is always on N, no per-turn
-- nag. The hotkey opens the full report. Content: techs / civics
-- completed, eurekas / inspirations triggered (the Civ V Access never had
-- this), production completed, cities founded, treasury change + income,
-- population / unit deltas, and current research / civic ETA.
--
-- HOW THE DELTA IS COMPUTED (all VM-safe — no cross-VM LuaEvents):
--   * SNAPSHOT DIFF at the turn boundary for state the engine doesn't hand us
--     as an event in this VM: completed techs/civics (HasTech/HasCivic set
--     diff), boosts (HasBoostBeenTriggered set diff), gold (GetGoldBalance),
--     population, unit count.
--   * ENGINE-EVENT ACCUMULATION for things that ARE clean engine events
--     (fire in every VM): production completed (Events.CityProductionCompleted)
--     and cities founded (Events.CityAddedToMap). Accumulated during the turn,
--     reported at the next turn-begin, then cleared.
--
-- Flow: on each Events.LocalPlayerTurnBegin we snapshot the player, diff
-- against the previous snapshot + the accumulated events to produce the
-- "last turn" delta, announce availability, then reset the accumulator. The
-- first turn (no prior snapshot) just primes — nothing to report yet.
--
-- Runs in the HexCursorAddin UI VM. include("EotReport") to gain the global.

include("Log");
include("Report");

EotReport = EotReport or {};

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _snap = nil;        -- previous turn-begin snapshot
local _accum = nil;       -- events accumulated during the current turn
local _lastDelta = nil;   -- the most recent computed "last turn" delta
local _haveReport = false;
local _hintSpoken = false; -- spoke the "press N" availability hint once already

local function lp()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    if not ok or id == nil then return -1; end
    return id;
end

local function esc(s)
    s = tostring(s or "");
    s = s:gsub("&", "&amp;"); s = s:gsub("<", "&lt;"); s = s:gsub(">", "&gt;");
    return s;
end

local function signed(n)
    n = math.floor((n or 0) + 0.5);
    if n > 0 then return "+" .. tostring(n); end
    if n < 0 then return "−" .. tostring(-n); end
    return "0";
end

local function round(n) return math.floor((n or 0) + 0.5); end

local function turnsToComplete(cost, progress, perTurn)
    if cost == nil or cost <= 0 then return nil; end
    local remaining = cost - (progress or 0);
    if remaining <= 0 then return 0; end
    if perTurn == nil or perTurn <= 0 then return nil; end
    return math.ceil(remaining / perTurn);
end

local function newAccum()
    return { production = {}, founded = {} };
end

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------

local function snapshot(pPlayer)
    local s = { hasTech = {}, hasCivic = {}, boostTech = {}, boostCivic = {} };
    s.turn = (Game and Game.GetCurrentGameTurn) and Game.GetCurrentGameTurn() or 0;

    local tr = pPlayer.GetTreasury ~= nil and pPlayer:GetTreasury() or nil;
    s.gold = (tr ~= nil and tr.GetGoldBalance ~= nil) and tr:GetGoldBalance() or 0;

    local pt = pPlayer.GetTechs ~= nil and pPlayer:GetTechs() or nil;
    if pt ~= nil then
        s.researchIdx = pt.GetResearchingTech ~= nil and pt:GetResearchingTech() or -1;
        local hasBoost = pt.HasBoostBeenTriggered ~= nil;
        for row in GameInfo.Technologies() do
            if pt:HasTech(row.Index) then s.hasTech[row.Index] = true; end
            if hasBoost and pt:HasBoostBeenTriggered(row.Index) then s.boostTech[row.Index] = true; end
        end
    end

    local pc = pPlayer.GetCulture ~= nil and pPlayer:GetCulture() or nil;
    if pc ~= nil then
        s.civicIdx = pc.GetProgressingCivic ~= nil and pc:GetProgressingCivic() or -1;
        local hasBoost = pc.HasBoostBeenTriggered ~= nil;
        for row in GameInfo.Civics() do
            if pc:HasCivic(row.Index) then s.hasCivic[row.Index] = true; end
            if hasBoost and pc:HasBoostBeenTriggered(row.Index) then s.boostCivic[row.Index] = true; end
        end
    end

    s.cityCount, s.pop = 0, 0;
    local cs = pPlayer.GetCities ~= nil and pPlayer:GetCities() or nil;
    if cs ~= nil and cs.Members ~= nil then
        for _, c in cs:Members() do
            s.cityCount = s.cityCount + 1;
            s.pop = s.pop + ((c.GetPopulation ~= nil and c:GetPopulation()) or 0);
        end
    end

    s.unitCount = 0;
    local us = pPlayer.GetUnits ~= nil and pPlayer:GetUnits() or nil;
    if us ~= nil and us.Members ~= nil then
        for _ in us:Members() do s.unitCount = s.unitCount + 1; end
    end

    return s;
end

-- Names completed between prev and cur (set diff). `infoTable` is GameInfo
-- .Technologies or .Civics; `field` is "hasTech"/"hasCivic"/"boostTech"/etc.
local function completedNames(prev, cur, field, infoTable)
    local out = {};
    for idx in pairs(cur[field]) do
        if prev[field][idx] ~= true then
            local row = infoTable[idx];
            if row ~= nil and row.Name ~= nil then out[#out + 1] = Locale.Lookup(row.Name); end
        end
    end
    return out;
end

-- ---------------------------------------------------------------------------
-- Delta -> HTML
-- ---------------------------------------------------------------------------

local function bulletList(b, items)
    b[#b + 1] = "<ul>";
    for _, it in ipairs(items) do b[#b + 1] = "<li>" .. it .. "</li>"; end
    b[#b + 1] = "</ul>";
end

local function renderDelta(prev, cur, accum, pPlayer)
    local b = {};
    local anything = false;

    -- Science / culture yields for ETA + income.
    local scienceYield, cultureYield, faithYield, goldNet;
    pcall(function()
        local pt = pPlayer:GetTechs();
        if pt ~= nil and pt.GetScienceYield ~= nil then scienceYield = pt:GetScienceYield(); end
        local pc = pPlayer:GetCulture();
        if pc ~= nil and pc.GetCultureYield ~= nil then cultureYield = pc:GetCultureYield(); end
        local pr = pPlayer:GetReligion();
        if pr ~= nil and pr.GetFaithYield ~= nil then faithYield = pr:GetFaithYield(); end
        local tr = pPlayer:GetTreasury();
        if tr ~= nil and tr.GetGoldYield ~= nil then
            goldNet = tr:GetGoldYield() - (tr.GetTotalMaintenance ~= nil and tr:GetTotalMaintenance() or 0);
        end
    end);

    -- Completed research / civics
    local techsDone = completedNames(prev, cur, "hasTech", GameInfo.Technologies);
    local civicsDone = completedNames(prev, cur, "hasCivic", GameInfo.Civics);
    if #techsDone > 0 or #civicsDone > 0 then
        anything = true;
        b[#b + 1] = "<h2>Completed</h2>";
        local items = {};
        for _, n in ipairs(techsDone) do items[#items + 1] = "Researched <strong>" .. esc(n) .. "</strong>"; end
        for _, n in ipairs(civicsDone) do items[#items + 1] = "Adopted civic <strong>" .. esc(n) .. "</strong>"; end
        bulletList(b, items);
    end

    -- Boosts (eureka / inspiration) — the Civ V Access analogue never had this.
    local techBoosts = completedNames(prev, cur, "boostTech", GameInfo.Technologies);
    local civicBoosts = completedNames(prev, cur, "boostCivic", GameInfo.Civics);
    if #techBoosts > 0 or #civicBoosts > 0 then
        anything = true;
        b[#b + 1] = "<h2>Boosts triggered</h2>";
        local items = {};
        for _, n in ipairs(techBoosts) do items[#items + 1] = "Eureka: <strong>" .. esc(n) .. "</strong> (science boosted)"; end
        for _, n in ipairs(civicBoosts) do items[#items + 1] = "Inspiration: <strong>" .. esc(n) .. "</strong> (culture boosted)"; end
        bulletList(b, items);
    end

    -- Production completed + cities founded (accumulated engine events)
    if accum ~= nil and (#accum.production > 0 or #accum.founded > 0) then
        anything = true;
        b[#b + 1] = "<h2>Cities</h2>";
        local items = {};
        for _, p in ipairs(accum.production) do
            local line = esc(p.city) .. " completed " .. (p.item and ("<strong>" .. esc(p.item) .. "</strong>") or "production");
            items[#items + 1] = line;
        end
        for _, f in ipairs(accum.founded) do
            items[#items + 1] = "Founded <strong>" .. esc(f) .. "</strong>";
        end
        bulletList(b, items);
    end

    -- Economy: gold change + income
    do
        local goldDelta = (cur.gold or 0) - (prev.gold or 0);
        b[#b + 1] = "<h2>Economy</h2><ul>";
        b[#b + 1] = "<li>Treasury: " .. round(cur.gold) .. " gold (" .. signed(goldDelta) .. " last turn)</li>";
        if goldNet ~= nil then b[#b + 1] = "<li>Gold income: " .. signed(goldNet) .. " per turn</li>"; end
        if scienceYield ~= nil then b[#b + 1] = "<li>Science: " .. signed(scienceYield) .. " per turn</li>"; end
        if cultureYield ~= nil then b[#b + 1] = "<li>Culture: " .. signed(cultureYield) .. " per turn</li>"; end
        if faithYield ~= nil then b[#b + 1] = "<li>Faith: " .. signed(faithYield) .. " per turn</li>"; end
        b[#b + 1] = "</ul>";
    end

    -- Empire deltas (cities / population / units)
    do
        local cityDelta = (cur.cityCount or 0) - (prev.cityCount or 0);
        local popDelta = (cur.pop or 0) - (prev.pop or 0);
        local unitDelta = (cur.unitCount or 0) - (prev.unitCount or 0);
        if cityDelta ~= 0 or popDelta ~= 0 or unitDelta ~= 0 then
            anything = true;
            b[#b + 1] = "<h2>Empire</h2><ul>";
            if cityDelta ~= 0 then b[#b + 1] = "<li>Cities: " .. signed(cityDelta) .. " (now " .. cur.cityCount .. ")</li>"; end
            if popDelta ~= 0 then b[#b + 1] = "<li>Population: " .. signed(popDelta) .. " (now " .. cur.pop .. ")</li>"; end
            if unitDelta ~= 0 then b[#b + 1] = "<li>Units: " .. signed(unitDelta) .. " (now " .. cur.unitCount .. ")</li>"; end
            b[#b + 1] = "</ul>";
        end
    end

    -- In progress now (research / civic ETA) — carry-forward context.
    do
        b[#b + 1] = "<h2>In progress</h2><ul>";
        local researchLine = "Research: nothing selected";
        local pt = pPlayer:GetTechs();
        if pt ~= nil and cur.researchIdx ~= nil and cur.researchIdx >= 0 then
            local row = GameInfo.Technologies[cur.researchIdx];
            if row ~= nil then
                local prog = pt.GetResearchProgress ~= nil and pt:GetResearchProgress(cur.researchIdx) or 0;
                local turns = turnsToComplete(row.Cost, prog, scienceYield);
                researchLine = "Research: " .. esc(Locale.Lookup(row.Name));
                if turns ~= nil then researchLine = researchLine .. ", " .. turns .. " turns left"; end
            end
        end
        b[#b + 1] = "<li>" .. researchLine .. "</li>";

        local civicLine = "Civic: nothing selected";
        local pc = pPlayer:GetCulture();
        if pc ~= nil and cur.civicIdx ~= nil and cur.civicIdx >= 0 then
            local row = GameInfo.Civics[cur.civicIdx];
            if row ~= nil then
                local prog = pc.GetCulturalProgress ~= nil and pc:GetCulturalProgress(cur.civicIdx) or 0;
                local turns = turnsToComplete(row.Cost, prog, cultureYield);
                civicLine = "Civic: " .. esc(Locale.Lookup(row.Name));
                if turns ~= nil then civicLine = civicLine .. ", " .. turns .. " turns left"; end
            end
        end
        b[#b + 1] = "<li>" .. civicLine .. "</li>";
        b[#b + 1] = "</ul>";
    end

    if not anything then
        table.insert(b, 1, "<p class='muted'>A quiet turn — no completions, boosts, or empire changes.</p>");
    end

    return b;
end

-- ---------------------------------------------------------------------------
-- Event accumulation (engine events; fire in all VMs)
-- ---------------------------------------------------------------------------

local function cityNameById(pPlayer, cityID)
    local cs = pPlayer.GetCities ~= nil and pPlayer:GetCities() or nil;
    if cs ~= nil and cs.FindID ~= nil then
        local c = cs:FindID(cityID);
        if c ~= nil and c.GetName ~= nil then return Locale.Lookup(c:GetName()); end
    end
    return "a city";
end

local function onCityProductionCompleted(playerID, cityID, orderType, unitType, canceled, typeModifier)
    if _accum == nil then return; end
    if playerID ~= lp() then return; end
    if canceled == true then return; end
    local pPlayer = Players ~= nil and Players[playerID] or nil;
    if pPlayer == nil then return; end
    -- Best-effort item name: a valid unitType index resolves to a unit; other
    -- production kinds (building / district / project) aren't cleanly named
    -- from these args, so we leave the item generic for those.
    local item = nil;
    if unitType ~= nil and unitType >= 0 and GameInfo.Units ~= nil then
        local row = GameInfo.Units[unitType];
        if row ~= nil and row.Name ~= nil then item = Locale.Lookup(row.Name); end
    end
    _accum.production[#_accum.production + 1] = { city = cityNameById(pPlayer, cityID), item = item };
end

local function onCityAddedToMap(playerID, cityID, x, y)
    if _accum == nil then return; end
    if playerID ~= lp() then return; end
    local pPlayer = Players ~= nil and Players[playerID] or nil;
    if pPlayer == nil then return; end
    _accum.founded[#_accum.founded + 1] = cityNameById(pPlayer, cityID);
end

-- ---------------------------------------------------------------------------
-- Turn boundary
-- ---------------------------------------------------------------------------

local function onLocalPlayerTurnBegin()
    local pid = lp();
    if pid < 0 then return; end
    local pPlayer = Players ~= nil and Players[pid] or nil;
    if pPlayer == nil then return; end

    local ok, cur = pcall(snapshot, pPlayer);
    if not ok or cur == nil then
        Log.warn("EotReport: snapshot failed: " .. tostring(cur));
        return;
    end

    if _snap ~= nil then
        local okD, delta = pcall(renderDelta, _snap, cur, _accum, pPlayer);
        if okD and delta ~= nil then
            _lastDelta = { turn = _snap.turn, html = delta };
            _haveReport = true;
            -- Teach the hotkey exactly once (the first turn a report exists),
            -- then stay silent — the report is always on N, no per-turn nag.
            -- Queued so it never clobbers the turn-begin "your turn" /
            -- notification speech.
            if not _hintSpoken then
                _hintSpoken = true;
                Speech.emit("End of turn report ready. Press N any turn to read it.", "status");
            end
        else
            Log.warn("EotReport: renderDelta failed: " .. tostring(delta));
        end
    end

    _snap = cur;
    _accum = newAccum();
end

-- ---------------------------------------------------------------------------
-- Public entry (hotkey)
-- ---------------------------------------------------------------------------

function EotReport.show()
    if not _haveReport or _lastDelta == nil then
        Speech.emit("No end of turn report yet. Play a turn first.", "meta");
        return;
    end
    Speech.emit("Opening end of turn report", "meta");
    -- "End of Turn 33 of 500" — same progress context as the empire report.
    Report.show("End of " .. Report.turnPhrase(_lastDelta.turn), _lastDelta.html);
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

local function Initialize()
    _accum = newAccum();
    if Events ~= nil then
        if Events.LocalPlayerTurnBegin ~= nil then
            Events.LocalPlayerTurnBegin.Add(onLocalPlayerTurnBegin);
        end
        if Events.CityProductionCompleted ~= nil then
            Events.CityProductionCompleted.Add(onCityProductionCompleted);
        end
        if Events.CityAddedToMap ~= nil then
            Events.CityAddedToMap.Add(onCityAddedToMap);
        end
    end
    Log.info("EotReport.lua: loaded");
end
Initialize();
