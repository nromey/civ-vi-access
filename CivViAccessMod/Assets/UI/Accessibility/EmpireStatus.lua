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

-- Gold / yield magnitude to 1 decimal, trailing ".0" dropped, U+2212 minus
-- for negatives. Gold maintenance is fractional and the expense breakdown
-- rows must sum to the total, so we keep one decimal rather than whole-
-- rounding each (which would drift the children off the parent). City
-- yields (food / gold) can go negative, hence the sign handling.
local function yld(n)
    local v = math.floor((n or 0) * 10 + 0.5) / 10;
    local neg = v < 0;
    if neg then v = -v; end
    local s;
    if v == math.floor(v) then s = tostring(math.floor(v)); else s = string.format("%.1f", v); end
    if neg then return "−" .. s; end
    return s;
end

-- Signed 1-decimal gold for per-turn rows ("+5", "−8.2", "0").
local function goldSigned(n)
    local v = math.floor((n or 0) * 10 + 0.5) / 10;
    if v > 0 then return "+" .. yld(v); end
    return yld(v); -- yld() already prefixes − for negatives, and gives "0" for 0
end

-- One city's per-turn yield as a table cell, or "—" if unavailable. Uses the
-- same pCity:GetYield(YieldTypes.X) the engine Reports screen reads
-- (CitySupport.lua:316-332); values are plain floats, so yld() keeps a decimal.
local function cityYieldCell(pCity, yt)
    if yt == nil or pCity == nil or pCity.GetYield == nil then return "—"; end
    local ok, v = pcall(function() return pCity:GetYield(yt); end);
    if not ok or v == nil then return "—"; end
    return yld(v);
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

-- Economy section. Gold gets the Civ V "economic log" treatment: treasury,
-- gross income, the EXPENSE breakdown, and net. Civ VI exposes the expense
-- split (GetBuildingMaintenance / GetDistrictMaintenance / GetUnitMaintenance
-- / GetWMDMaintenance, plus an inferred residual) but NOT a per-source INCOME
-- breakdown — GetGoldYield is a single gross number (ReportScreen.lua confirms
-- no per-source income API). So we surface gross income + where the gold goes
-- + net, and don't fabricate income sources. Science / culture / faith follow.
local function sectionEconomy(b, pPlayer)
    local pTreasury = pPlayer.GetTreasury ~= nil and pPlayer:GetTreasury() or nil;

    b[#b + 1] = "<h2>Gold</h2>";
    if pTreasury == nil then
        b[#b + 1] = "<p class='muted'>Treasury unavailable.</p>";
    else
        local bal     = pTreasury.GetGoldBalance ~= nil and pTreasury:GetGoldBalance() or nil;
        local income  = pTreasury.GetGoldYield ~= nil and pTreasury:GetGoldYield() or nil;       -- gross
        local expense = pTreasury.GetTotalMaintenance ~= nil and pTreasury:GetTotalMaintenance() or nil;
        local net = (income ~= nil and expense ~= nil) and (income - expense) or nil;

        b[#b + 1] = "<ul>";
        if bal ~= nil then b[#b + 1] = "<li>Treasury: " .. yld(bal) .. " gold</li>"; end
        if income ~= nil then b[#b + 1] = "<li>Income: " .. goldSigned(income) .. " per turn</li>"; end
        if expense ~= nil then b[#b + 1] = "<li>Expenses: " .. goldSigned(-expense) .. " per turn</li>"; end
        if net ~= nil then b[#b + 1] = "<li>Net: <strong>" .. goldSigned(net) .. "</strong> per turn</li>"; end
        b[#b + 1] = "</ul>";

        -- Expense breakdown (only the categories that are non-zero).
        if expense ~= nil and expense > 0 then
            local mUnit = pTreasury.GetUnitMaintenance ~= nil and pTreasury:GetUnitMaintenance() or 0;
            local mBld  = pTreasury.GetBuildingMaintenance ~= nil and pTreasury:GetBuildingMaintenance() or 0;
            local mDis  = pTreasury.GetDistrictMaintenance ~= nil and pTreasury:GetDistrictMaintenance() or 0;
            local mWMD  = pTreasury.GetWMDMaintenance ~= nil and pTreasury:GetWMDMaintenance() or 0;
            local mOther = expense - mUnit - mBld - mDis - mWMD;
            b[#b + 1] = "<h3>Where the gold goes</h3><ul>";
            if mUnit > 0 then b[#b + 1] = "<li>Unit maintenance: " .. yld(mUnit) .. "</li>"; end
            if mBld  > 0 then b[#b + 1] = "<li>Building maintenance: " .. yld(mBld) .. "</li>"; end
            if mDis  > 0 then b[#b + 1] = "<li>District maintenance: " .. yld(mDis) .. "</li>"; end
            if mWMD  > 0 then b[#b + 1] = "<li>WMD maintenance: " .. yld(mWMD) .. "</li>"; end
            if mOther > 0.05 then b[#b + 1] = "<li>Other: " .. yld(mOther) .. "</li>"; end
            b[#b + 1] = "</ul>";
        end
    end

    -- Science / culture / faith per turn.
    local science, culture, faithY, faithB;
    local pTechs = pPlayer:GetTechs();
    if pTechs ~= nil and pTechs.GetScienceYield ~= nil then science = pTechs:GetScienceYield(); end
    local pCulture = pPlayer:GetCulture();
    if pCulture ~= nil and pCulture.GetCultureYield ~= nil then culture = pCulture:GetCultureYield(); end
    local pReligion = pPlayer:GetReligion();
    if pReligion ~= nil and pReligion.GetFaithYield ~= nil then
        faithY = pReligion:GetFaithYield();
        if pReligion.GetFaithBalance ~= nil then faithB = pReligion:GetFaithBalance(); end
    end

    b[#b + 1] = "<h2>Science, culture, and faith</h2><ul>";
    if science ~= nil then b[#b + 1] = "<li>Science: " .. signed(science) .. " per turn</li>"; end
    if culture ~= nil then b[#b + 1] = "<li>Culture: " .. signed(culture) .. " per turn</li>"; end
    if faithY ~= nil then
        local f = "<li>Faith: " .. signed(faithY) .. " per turn";
        if faithB ~= nil then f = f .. " (" .. round(faithB) .. " stored)"; end
        b[#b + 1] = f .. "</li>";
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

            -- Per-turn yields (Civ V Economic Overview's Cities tab). The
            -- Production column is the mine-effect acceptance test: improving a
            -- worked tile lifts the city's production rate here.
            local YT = YieldTypes or {};
            local foodC  = cityYieldCell(pCity, YT.FOOD);
            local prodYC = cityYieldCell(pCity, YT.PRODUCTION);
            local goldC  = cityYieldCell(pCity, YT.GOLD);
            local sciC   = cityYieldCell(pCity, YT.SCIENCE);
            local cultC  = cityYieldCell(pCity, YT.CULTURE);
            local faithC = cityYieldCell(pCity, YT.FAITH);

            rows[#rows + 1] = "<tr><td>" .. esc(name) .. "</td><td>" .. tostring(pop)
                .. "</td><td>" .. foodC .. "</td><td>" .. prodYC .. "</td><td>" .. goldC
                .. "</td><td>" .. sciC .. "</td><td>" .. cultC .. "</td><td>" .. faithC
                .. "</td><td>" .. prodCell .. "</td><td>" .. growCell .. "</td></tr>";
        end
    end

    if count == 0 then
        b[#b + 1] = "<p>No cities founded yet.</p>";
    else
        b[#b + 1] = "<table><tr><th>City</th><th>Pop</th><th>Food</th><th>Prod</th>"
            .. "<th>Gold</th><th>Sci</th><th>Cult</th><th>Faith</th>"
            .. "<th>Producing (turns)</th><th>Grows in</th></tr>";
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

-- Territory + exploration. One pass over the map grid (on-demand keypress, so
-- a full W*H scan is fine — not a per-frame cost): how much is revealed,
-- how much land we own + have improved, and the nearest fog edge from the
-- capital so the user knows which way to send a scout. Uses the same
-- PlayersVisibility / plot APIs the cursor + board query already rely on.
local function sectionTerritory(b, pPlayer, pid)
    b[#b + 1] = "<h2>Territory and exploration</h2>";
    if Map == nil or Map.GetGridSize == nil or Map.GetPlot == nil then
        b[#b + 1] = "<p class='muted'>Map data unavailable.</p>";
        return;
    end
    local W, H = Map.GetGridSize();
    local pVis = (PlayersVisibility ~= nil) and PlayersVisibility[pid] or nil;

    -- Capital is the reference point for the nearest fog edge.
    local capX, capY;
    local cs = pPlayer.GetCities ~= nil and pPlayer:GetCities() or nil;
    if cs ~= nil and cs.GetCapitalCity ~= nil then
        local cap = cs:GetCapitalCity();
        if cap ~= nil and cap.GetX ~= nil then capX, capY = cap:GetX(), cap:GetY(); end
    end

    local total, revealed, owned, improved = 0, 0, 0, 0;
    local fogDist, fogX, fogY;
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local plot = Map.GetPlot(x, y);
            if plot ~= nil then
                total = total + 1;
                local isRev = true;
                if pVis ~= nil and pVis.IsRevealed ~= nil then isRev = pVis:IsRevealed(x, y); end
                if isRev then
                    revealed = revealed + 1;
                    local owner = plot.GetOwner ~= nil and plot:GetOwner() or -1;
                    if owner == pid then
                        owned = owned + 1;
                        local imp = plot.GetImprovementType ~= nil and plot:GetImprovementType() or -1;
                        if imp ~= nil and imp >= 0 then improved = improved + 1; end
                    end
                elseif capX ~= nil and Map.GetPlotDistance ~= nil then
                    local d = Map.GetPlotDistance(capX, capY, x, y);
                    if fogDist == nil or d < fogDist then fogDist = d; fogX = x; fogY = y; end
                end
            end
        end
    end

    local pct = (total > 0) and math.floor((revealed / total) * 100 + 0.5) or 0;
    b[#b + 1] = "<ul>";
    b[#b + 1] = "<li>Map explored: " .. pct .. "% (" .. revealed .. " of " .. total .. " tiles)</li>";
    b[#b + 1] = "<li>Tiles owned: " .. owned .. "</li>";
    if owned > 0 then
        local ipct = math.floor((improved / owned) * 100 + 0.5);
        b[#b + 1] = "<li>Tiles improved: " .. improved .. " (" .. ipct .. "% of owned)</li>";
    end
    if fogDist ~= nil then
        local dirStr;
        if HexGeom ~= nil and HexGeom.directionString ~= nil and capX ~= nil then
            local okD, ds = pcall(function() return HexGeom.directionString(capX, capY, fogX, fogY); end);
            if okD and ds ~= nil and ds ~= "" then dirStr = ds; end
        end
        -- directionString carries its own distance (hex / bearing modes), so we
        -- append only the location phrase, never ", N tiles" on top.
        if dirStr ~= nil then
            b[#b + 1] = "<li>Nearest unexplored tile: " .. dirStr .. " from your capital</li>";
        else
            b[#b + 1] = "<li>Nearest unexplored tile: " .. fogDist .. " tiles from your capital</li>";
        end
    elseif revealed >= total and total > 0 then
        b[#b + 1] = "<li>The whole map is explored.</li>";
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
    run(detail, "Economy", function() sectionEconomy(detail, pPlayer); end);
    run(detail, "Research and civic", function()
        sectionResearchCivic(detail, pPlayer, scienceYield, cultureYield);
    end);
    local blockedCities = run(detail, "Cities", function() return sectionCities(detail, pPlayer); end);
    local idleUnits = run(detail, "Units", function() return sectionUnits(detail, pPlayer); end);
    run(detail, "City-states", function() sectionCityStates(detail, pPlayer, pid); end);
    run(detail, "Territory", function() sectionTerritory(detail, pPlayer, pid); end);

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
