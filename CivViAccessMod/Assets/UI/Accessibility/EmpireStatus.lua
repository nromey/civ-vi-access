-- EmpireStatus.lua — on-demand "state of your empire" report, rendered in
-- the launcher's WebView2 window via the report bridge ([[Report]] /
-- docs/REPORT_BRIDGE.md). The first real consumer of that bridge.
--
-- Answers "what's going on / what needs attention before I end the turn?"
-- (Noel 2026-06-01: "I'm missing things when turns end"). One key builds a
-- structured HTML report the screen reader navigates in browse mode:
--
--   Needs attention   to-do list of end-turn blockers (empty production,
--                      no research/civic, idle units) — only when non-empty
--   Yields            science / culture / faith / gold, per turn + stored
--   Research & Civic  current pick + turns left (or "nothing selected")
--   Cities            per city: pop, producing (+turns), growth
--   Units             counts by state + the units that still need orders
--   City-states       how many met + which we're suzerain of
--
-- Every section is independently pcall-guarded: a single bad engine call
-- degrades that section to "(unavailable)" rather than killing the report.
-- Runs in the HexCursorAddin UI VM (UnitManager / GameInfo / Players all
-- present there). include("EmpireStatus") to gain the global.

include("Log");
include("Report");

EmpireStatus = EmpireStatus or {};

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function lp()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    if not ok or id == nil then return -1; end
    return id;
end

-- HTML-escape dynamic text (city / leader / unit names). The launcher
-- trusts our body markup, so we escape values here.
local function esc(s)
    s = tostring(s or "");
    s = s:gsub("&", "&amp;");
    s = s:gsub("<", "&lt;");
    s = s:gsub(">", "&gt;");
    return s;
end

-- Round + signed string for per-turn values ("+3", "0", "−2"). Uses the
-- minus sign U+2212 so screen readers don't read it as a hyphen mid-word.
local function signed(n)
    n = math.floor((n or 0) + 0.5);
    if n > 0 then return "+" .. tostring(n); end
    if n < 0 then return "−" .. tostring(-n); end
    return "0";
end

local function round(n)
    return math.floor((n or 0) + 0.5);
end

-- ceil((cost - progress) / perTurn), or nil if it can't be computed
-- (no cost, or zero/negative per-turn yield => "never at this rate").
local function turnsToComplete(cost, progress, perTurn)
    if cost == nil or cost <= 0 then return nil; end
    local remaining = cost - (progress or 0);
    if remaining <= 0 then return 0; end
    if perTurn == nil or perTurn <= 0 then return nil; end
    return math.ceil(remaining / perTurn);
end

-- Resolve a production-queue type hash to a localized name by scanning the
-- production tables (covers buildings, wonders-as-buildings, units,
-- districts, projects). Tries the direct name API first if present.
local function nameForHash(hash)
    local tables = { GameInfo.Units, GameInfo.Buildings, GameInfo.Districts, GameInfo.Projects };
    for _, t in ipairs(tables) do
        if t ~= nil then
            for row in t() do
                if row.Hash == hash and row.Name ~= nil then
                    return Locale.Lookup(row.Name);
                end
            end
        end
    end
    return nil;
end

-- ---------------------------------------------------------------------------
-- Section builders. Each appends HTML fragments to `b` (a table of strings)
-- and is wrapped by the caller in pcall.
-- ---------------------------------------------------------------------------

local function sectionYields(b, pPlayer)
    local science, culture, faithY, faithB, goldNet, goldBal;
    local pTechs = pPlayer:GetTechs();
    if pTechs ~= nil and pTechs.GetScienceYield ~= nil then science = pTechs:GetScienceYield(); end
    local pCulture = pPlayer:GetCulture();
    if pCulture ~= nil and pCulture.GetCultureYield ~= nil then culture = pCulture:GetCultureYield(); end
    local pReligion = pPlayer:GetReligion();
    if pReligion ~= nil and pReligion.GetFaithYield ~= nil then
        faithY = pReligion:GetFaithYield();
        if pReligion.GetFaithBalance ~= nil then faithB = pReligion:GetFaithBalance(); end
    end
    local pTreasury = pPlayer:GetTreasury();
    if pTreasury ~= nil and pTreasury.GetGoldYield ~= nil then
        goldNet = pTreasury:GetGoldYield() - (pTreasury.GetTotalMaintenance ~= nil
                  and pTreasury:GetTotalMaintenance() or 0);
        if pTreasury.GetGoldBalance ~= nil then goldBal = pTreasury:GetGoldBalance(); end
    end

    b[#b + 1] = "<h2>Yields per turn</h2>";
    b[#b + 1] = "<ul>";
    if science ~= nil then b[#b + 1] = "<li>Science: " .. signed(science) .. " per turn</li>"; end
    if culture ~= nil then b[#b + 1] = "<li>Culture: " .. signed(culture) .. " per turn</li>"; end
    if faithY ~= nil then
        local f = "<li>Faith: " .. signed(faithY) .. " per turn";
        if faithB ~= nil then f = f .. " (" .. round(faithB) .. " stored)"; end
        b[#b + 1] = f .. "</li>";
    end
    if goldNet ~= nil then
        local g = "<li>Gold: " .. signed(goldNet) .. " per turn";
        if goldBal ~= nil then g = g .. " (" .. round(goldBal) .. " in treasury)"; end
        b[#b + 1] = g .. "</li>";
    end
    b[#b + 1] = "</ul>";
end

-- Returns currentResearchName or nil (also appends the section).
local function sectionResearchCivic(b, pPlayer, scienceYield, cultureYield)
    b[#b + 1] = "<h2>Research and civic</h2>";
    b[#b + 1] = "<ul>";

    -- Research
    local researchLine = "Research: nothing selected";
    local pTechs = pPlayer:GetTechs();
    if pTechs ~= nil and pTechs.GetResearchingTech ~= nil then
        local idx = pTechs:GetResearchingTech();
        if idx ~= nil and idx >= 0 then
            local row = GameInfo.Technologies[idx];
            if row ~= nil then
                local nm = Locale.Lookup(row.Name);
                local prog = pTechs.GetResearchProgress ~= nil and pTechs:GetResearchProgress(idx) or 0;
                local turns = turnsToComplete(row.Cost, prog, scienceYield);
                researchLine = "Research: " .. esc(nm);
                if turns ~= nil then researchLine = researchLine .. ", " .. turns .. " turns left"; end
            end
        end
    end
    b[#b + 1] = "<li>" .. researchLine .. "</li>";

    -- Civic
    local civicLine = "Civic: nothing selected";
    local pCulture = pPlayer:GetCulture();
    if pCulture ~= nil and pCulture.GetProgressingCivic ~= nil then
        local idx = pCulture:GetProgressingCivic();
        if idx ~= nil and idx >= 0 then
            local row = GameInfo.Civics[idx];
            if row ~= nil then
                local nm = Locale.Lookup(row.Name);
                local prog = pCulture.GetCulturalProgress ~= nil and pCulture:GetCulturalProgress(idx) or 0;
                local turns = turnsToComplete(row.Cost, prog, cultureYield);
                civicLine = "Civic: " .. esc(nm);
                if turns ~= nil then civicLine = civicLine .. ", " .. turns .. " turns left"; end
            end
        end
    end
    b[#b + 1] = "<li>" .. civicLine .. "</li>";

    b[#b + 1] = "</ul>";
end

-- Returns count of cities with an empty production queue (for the
-- needs-attention summary), and appends the Cities table.
local function sectionCities(b, pPlayer)
    local pCities = pPlayer:GetCities();
    b[#b + 1] = "<h2>Cities</h2>";
    local count = 0;
    local blocked = 0;
    local rows = {};
    if pCities ~= nil then
        for _, pCity in pCities:Members() do
            count = count + 1;
            local name = Locale.Lookup(pCity:GetName());
            local pop = pCity.GetPopulation ~= nil and pCity:GetPopulation() or "?";

            -- Production
            local prodCell = "—";
            local pQueue = pCity.GetBuildQueue ~= nil and pCity:GetBuildQueue() or nil;
            if pQueue ~= nil then
                local hash = pQueue.GetCurrentProductionTypeHash ~= nil
                             and pQueue:GetCurrentProductionTypeHash() or 0;
                if hash ~= nil and hash ~= 0 then
                    local pname = nil;
                    if pQueue.GetCurrentProductionTypeName ~= nil then
                        local okN, n = pcall(function() return pQueue:GetCurrentProductionTypeName(); end);
                        if okN and n ~= nil and n ~= "" then pname = Locale.Lookup(n); end
                    end
                    if pname == nil then pname = nameForHash(hash); end
                    prodCell = esc(pname or "building");
                    local okT, turns = pcall(function() return pQueue:GetTurnsLeft(); end);
                    if okT and turns ~= nil and turns > 0 then
                        prodCell = prodCell .. " (" .. turns .. ")";
                    end
                else
                    prodCell = "<strong>nothing</strong>";
                    blocked = blocked + 1;
                end
            end

            -- Growth
            local growCell = "—";
            local pGrowth = pCity.GetGrowth ~= nil and pCity:GetGrowth() or nil;
            if pGrowth ~= nil and pGrowth.GetTurnsUntilGrowth ~= nil then
                local okG, g = pcall(function() return pGrowth:GetTurnsUntilGrowth(); end);
                if okG and g ~= nil and g > 0 then growCell = g .. " turns"; end
            end

            rows[#rows + 1] = "<tr><td>" .. esc(name) .. "</td><td>" .. tostring(pop)
                .. "</td><td>" .. prodCell .. "</td><td>" .. growCell .. "</td></tr>";
        end
    end

    if count == 0 then
        b[#b + 1] = "<p>No cities founded yet.</p>";
    else
        b[#b + 1] = "<table><tr><th>City</th><th>Pop</th><th>Producing (turns)</th><th>Grows in</th></tr>";
        for _, r in ipairs(rows) do b[#b + 1] = r; end
        b[#b + 1] = "</table>";
    end
    return blocked;
end

-- Returns count of units needing orders (for needs-attention) and appends
-- the Units section.
local function sectionUnits(b, pPlayer)
    local pUnits = pPlayer:GetUnits();
    local needsOrders, fortified, sleeping, sentry, other = 0, 0, 0, 0, 0;
    local needList = {};

    local AT = ActivityTypes or {};
    if pUnits ~= nil and pUnits.Members ~= nil then
        for _, u in pUnits:Members() do
            local ready = u.IsReadyToMove ~= nil and u:IsReadyToMove() or false;
            if ready then
                needsOrders = needsOrders + 1;
                local nm = "unit";
                local row = u.GetUnitType ~= nil and GameInfo.Units[u:GetUnitType()] or nil;
                if row ~= nil and row.Name ~= nil then nm = Locale.Lookup(row.Name); end
                local x = u.GetX ~= nil and u:GetX() or "?";
                local y = u.GetY ~= nil and u:GetY() or "?";
                needList[#needList + 1] = "<li>" .. esc(nm) .. " at " .. tostring(x)
                    .. ", " .. tostring(y) .. "</li>";
            else
                local act = (UnitManager ~= nil and UnitManager.GetActivityType ~= nil)
                            and UnitManager.GetActivityType(u) or nil;
                local fortifyTurns = u.GetFortifyTurns ~= nil and u:GetFortifyTurns() or 0;
                if act == AT.ACTIVITY_SLEEP then
                    sleeping = sleeping + 1;
                elseif act == AT.ACTIVITY_SENTRY then
                    sentry = sentry + 1;
                elseif fortifyTurns ~= nil and fortifyTurns > 0 then
                    fortified = fortified + 1;
                else
                    other = other + 1;
                end
            end
        end
    end

    b[#b + 1] = "<h2>Units</h2>";
    b[#b + 1] = "<ul>";
    b[#b + 1] = "<li>Need orders: <strong>" .. needsOrders .. "</strong></li>";
    if fortified > 0 then b[#b + 1] = "<li>Fortified: " .. fortified .. "</li>"; end
    if sleeping > 0 then b[#b + 1] = "<li>Sleeping: " .. sleeping .. "</li>"; end
    if sentry > 0 then b[#b + 1] = "<li>On alert / sentry: " .. sentry .. "</li>"; end
    if other > 0 then b[#b + 1] = "<li>Other (moving / busy): " .. other .. "</li>"; end
    b[#b + 1] = "</ul>";

    if needsOrders > 0 then
        b[#b + 1] = "<h3>Units needing orders</h3>";
        b[#b + 1] = "<ul>";
        for _, li in ipairs(needList) do b[#b + 1] = li; end
        b[#b + 1] = "</ul>";
    end
    return needsOrders;
end

local function sectionCityStates(b, pPlayer, localPlayerID)
    local met = 0;
    local suzerainOf = {};
    local pDiplo = pPlayer.GetDiplomacy ~= nil and pPlayer:GetDiplomacy() or nil;
    local maxP = (GameDefines and GameDefines.MAX_PLAYERS) or 64;
    for pid = 0, maxP - 1 do
        local p = Players ~= nil and Players[pid] or nil;
        if p ~= nil and pid ~= localPlayerID and p.IsMinor ~= nil and p:IsMinor() then
            local hasMet = pDiplo ~= nil and pDiplo.HasMet ~= nil and pDiplo:HasMet(pid) or false;
            if hasMet then
                met = met + 1;
                local inf = p.GetInfluence ~= nil and p:GetInfluence() or nil;
                if inf ~= nil and inf.GetSuzerain ~= nil then
                    local suz = inf:GetSuzerain();
                    if suz == localPlayerID then
                        local cfg = PlayerConfigurations and PlayerConfigurations[pid] or nil;
                        local nm = (cfg ~= nil and cfg.GetCivilizationShortDescription ~= nil)
                                   and Locale.Lookup(cfg:GetCivilizationShortDescription()) or ("City-state " .. pid);
                        suzerainOf[#suzerainOf + 1] = esc(nm);
                    end
                end
            end
        end
    end

    b[#b + 1] = "<h2>City-states</h2>";
    b[#b + 1] = "<ul>";
    b[#b + 1] = "<li>Met: " .. met .. "</li>";
    if #suzerainOf > 0 then
        b[#b + 1] = "<li>Suzerain of: " .. table.concat(suzerainOf, ", ") .. "</li>";
    else
        b[#b + 1] = "<li>Suzerain of: none</li>";
    end
    b[#b + 1] = "</ul>";
end

-- Safe section runner: append "(unavailable)" note on failure instead of
-- aborting the whole report.
local function run(b, label, fn)
    local ok, result = pcall(fn);
    if not ok then
        Log.warn("EmpireStatus: section '" .. label .. "' failed: " .. tostring(result));
        b[#b + 1] = "<p class='muted'>" .. label .. " unavailable.</p>";
        return nil;
    end
    return result;
end

-- ---------------------------------------------------------------------------
-- Public entry
-- ---------------------------------------------------------------------------

function EmpireStatus.show()
    local pid = lp();
    if pid < 0 then
        Speech.emit("No active player", "meta");
        return;
    end
    local pPlayer = Players ~= nil and Players[pid] or nil;
    if pPlayer == nil then
        Speech.emit("Player not available", "meta");
        return;
    end

    Speech.emit("Building empire status report", "meta");

    local turn = (Game and Game.GetCurrentGameTurn) and Game.GetCurrentGameTurn() or 0;
    local title = "Empire Status — Turn " .. tostring(turn);

    -- Pre-fetch yields so research/civic ETA can use them.
    local scienceYield, cultureYield = nil, nil;
    pcall(function()
        local pt = pPlayer:GetTechs();
        if pt ~= nil and pt.GetScienceYield ~= nil then scienceYield = pt:GetScienceYield(); end
        local pc = pPlayer:GetCulture();
        if pc ~= nil and pc.GetCultureYield ~= nil then cultureYield = pc:GetCultureYield(); end
    end);

    local body = {};

    -- We build the detail sections first (they compute the counts the
    -- needs-attention summary references), then splice the summary in at
    -- the top by building it into a separate table and concatenating.
    local detail = {};
    run(detail, "Yields", function() sectionYields(detail, pPlayer); end);
    run(detail, "Research and civic", function()
        sectionResearchCivic(detail, pPlayer, scienceYield, cultureYield);
    end);
    local blockedCities = run(detail, "Cities", function() return sectionCities(detail, pPlayer); end);
    local idleUnits = run(detail, "Units", function() return sectionUnits(detail, pPlayer); end);
    run(detail, "City-states", function() sectionCityStates(detail, pPlayer, pid); end);

    -- Needs-attention summary (only when something actually needs doing).
    local todo = {};
    if (blockedCities or 0) > 0 then
        todo[#todo + 1] = "<li>" .. blockedCities .. " "
            .. ((blockedCities == 1) and "city has" or "cities have")
            .. " nothing in production</li>";
    end
    do
        local needsResearch = false;
        pcall(function()
            local pt = pPlayer:GetTechs();
            needsResearch = pt ~= nil and pt.GetResearchingTech ~= nil and pt:GetResearchingTech() < 0;
        end);
        if needsResearch then todo[#todo + 1] = "<li>No research selected</li>"; end
    end
    do
        local needsCivic = false;
        pcall(function()
            local pc = pPlayer:GetCulture();
            needsCivic = pc ~= nil and pc.GetProgressingCivic ~= nil and pc:GetProgressingCivic() < 0;
        end);
        if needsCivic then todo[#todo + 1] = "<li>No civic selected</li>"; end
    end
    if (idleUnits or 0) > 0 then
        todo[#todo + 1] = "<li>" .. idleUnits .. " "
            .. ((idleUnits == 1) and "unit needs" or "units need") .. " orders</li>";
    end

    if #todo > 0 then
        body[#body + 1] = "<h2>Needs attention</h2><ul>";
        for _, li in ipairs(todo) do body[#body + 1] = li; end
        body[#body + 1] = "</ul>";
    else
        body[#body + 1] = "<p class='muted'>Nothing needs attention — ready to end the turn.</p>";
    end

    for _, frag in ipairs(detail) do body[#body + 1] = frag; end

    Report.show(title, body);
end

Log.info("EmpireStatus.lua: loaded");
