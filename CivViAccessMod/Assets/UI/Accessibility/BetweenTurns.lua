-- BetweenTurns.lua — the overnight briefing (Noel 2026-06-12, designed after
-- the first live war: a barbarian counter-attacked during the AI turn and the
-- only announce flew by mid-processing; another game, an unwatched barbarian
-- walked up and attacked his city).
--
-- Collects what happened to / near the player while the AI players ran, then
-- reads a short briefing at the start of the player's turn:
--
--   "Overnight: Your Warrior was attacked, lost 25 HP, 45 of 100 left.
--    Your Scout recovered 10 HP, 55 of 100. Enemy Barbarians Warrior
--    2 east of Amsterdam."
--
-- Quiet nights say nothing ("exceptions speak" — silence = nothing happened).
--
-- HP is tracked as a NET overnight change per own unit (first prevDamage vs
-- last newDamage), so heal ticks and attacks in the same night net out the way
-- the player experiences them. Recovery matters as much as damage: it answers
-- "rest here another turn, or walk to the city to finish mending?" (Noel).
--
-- The player's own heal tick lands AT turn activation — log 2026-06-12 shows
-- PlayerTurnActivated(0) firing AFTER LocalPlayerTurnBegin — so composing the
-- briefing directly in LocalPlayerTurnBegin would miss it. We arm on turn
-- begin and compose on the next GameCoreEventPublishComplete pump, after the
-- activation batch (with a direct fallback if that event is unavailable).
--
-- v1 scope: enemy military only (barbarians + civs at war), own losses +
-- net HP changes. Verbosity options (all foreign moves / off), the Enter
-- turn-gate, a re-read key, and city-damage speech ride later passes. City
-- damage events are LOGGED (BT_DEBUG) to capture their arg shape first —
-- same confirm-before-speaking pattern that served UnitCombat.

include("Log");
include("ScreenReader");
include("ScreenReaderPlotUtils");
include("HexGeom");

BetweenTurns = BetweenTurns or {};

-- Log raw city-damage args until the shape is confirmed from a live siege.
local BT_DEBUG = true;

local _collecting = false;
local _composeArmed = false;
local _moves  = {};   -- "pid:uid" -> { pid, uid, x, y }  last visible position
local _hp     = {};   -- "pid:uid" -> { startDamage, endDamage, maxHP } own units
local _losses = {};   -- array of own unit names destroyed overnight
local _built  = {};   -- array of { city, cityID, item } own production completed

local function reset()
    _moves, _hp, _losses, _built = {}, {}, {}, {};
end

local function localPlayer()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    return Game.GetLocalPlayer();
end

local function unitTypeName(unit)
    if unit == nil then return "unit"; end
    local info = GameInfo.Units[unit:GetUnitType()];
    if info == nil or info.Name == nil then return "unit"; end
    return Locale.Lookup(info.Name);
end

local function isHostile(pid, lp)
    local hostile = false;
    pcall(function()
        local p = Players[pid];
        if p ~= nil and p.IsBarbarian ~= nil and p:IsBarbarian() then
            hostile = true;
            return;
        end
        local diplo = (Players[lp] ~= nil) and Players[lp]:GetDiplomacy() or nil;
        if diplo ~= nil and diplo.IsAtWarWith ~= nil then
            hostile = diplo:IsAtWarWith(pid);
        end
    end);
    return hostile;
end

local function isMilitary(unit)
    local mil = false;
    pcall(function()
        mil = (unit:GetCombat() > 0) or (unit:GetRangedCombat() > 0)
           or (unit:GetBombardCombat() > 0);
    end);
    return mil;
end

local function isVisible(lp, x, y)
    local vis = false;
    pcall(function() vis = PlayersVisibility[lp]:IsVisible(x, y); end);
    return vis;
end

-- Nearest own unit or city to (x, y) — the mental anchor for an enemy
-- position ("2 east of Amsterdam" beats raw coordinates). Returns
-- name, anchorX, anchorY (nils if the player owns nothing).
local function nearestOwnAnchor(lp, x, y)
    local bestName, bestDist, bx, by = nil, nil, nil, nil;
    pcall(function()
        local p = Players[lp];
        if p == nil then return; end
        for _, u in p:GetUnits():Members() do
            local d = Map.GetPlotDistance(x, y, u:GetX(), u:GetY());
            if bestDist == nil or d < bestDist then
                bestDist, bestName = d, "your " .. unitTypeName(u);
                bx, by = u:GetX(), u:GetY();
            end
        end
        for _, c in p:GetCities():Members() do
            local d = Map.GetPlotDistance(x, y, c:GetX(), c:GetY());
            if bestDist == nil or d < bestDist then
                bestDist, bestName = d, Locale.Lookup(c:GetName());
                bx, by = c:GetX(), c:GetY();
            end
        end
    end);
    return bestName, bx, by;
end

-- ---------------------------------------------------------------------------
--  collection (between LocalPlayerTurnEnd and the compose pump)
-- ---------------------------------------------------------------------------

function BetweenTurns.onLocalTurnEnd()
    _collecting = true;
    reset();
end

function BetweenTurns.onUnitMoveComplete(pid, uid, x, y)
    if not _collecting then return; end
    local lp = localPlayer();
    if lp == -1 or pid == lp then return; end
    if not isHostile(pid, lp) then return; end
    if not isVisible(lp, x, y) then return; end
    local unit = nil;
    pcall(function() unit = Players[pid]:GetUnits():FindID(uid); end);
    if unit == nil or not isMilitary(unit) then return; end
    _moves[pid .. ":" .. uid] = { pid = pid, uid = uid, x = x, y = y };
end

function BetweenTurns.onUnitDamageChanged(pid, uid, newDamage, prevDamage)
    if not _collecting then return; end
    local lp = localPlayer();
    if pid ~= lp then return; end
    if type(newDamage) ~= "number" or type(prevDamage) ~= "number" then return; end
    local key = pid .. ":" .. uid;
    local rec = _hp[key];
    if rec == nil then
        local maxHP = 100;
        pcall(function()
            local u = Players[lp]:GetUnits():FindID(uid);
            if u ~= nil then maxHP = u:GetMaxDamage() or 100; end
        end);
        rec = { startDamage = prevDamage, maxHP = maxHP };
        _hp[key] = rec;
    end
    rec.endDamage = newDamage;
end

function BetweenTurns.onUnitKilledInCombat(killedPid, killedUid, killerPid, killerUid)
    if not _collecting then return; end
    local lp = localPlayer();
    if killedPid == lp then
        _hp[killedPid .. ":" .. killedUid] = nil;   -- superseded by the loss line
        local name = "unit";
        pcall(function()
            local u = Players[killedPid]:GetUnits():FindID(killedUid);
            if u ~= nil then name = unitTypeName(u); end
        end);
        _losses[#_losses + 1] = name;
    else
        _moves[killedPid .. ":" .. killedUid] = nil;  -- the dead don't menace
    end
end

-- Resolve a production-type HASH to a spoken name (the picker's queue-tab
-- approach: scan the GameInfo tables a city can produce from).
local function productionHashName(hash)
    if hash == nil or hash == 0 then return nil; end
    local name = nil;
    pcall(function()
        for _, tbl in ipairs({ "Units", "Buildings", "Districts", "Projects" }) do
            local t = GameInfo[tbl];
            if t ~= nil then
                for row in t() do
                    if row.Hash == hash then
                        if row.Name ~= nil then name = Locale.Lookup(row.Name); end
                        return;
                    end
                end
            end
        end
    end);
    return name;
end

-- Production completed (Noel 2026-06-12: the Warrior finished SILENTLY and
-- the queued Granary slid in as current with no announce). Arg shape per the
-- vanilla TutorialUIRoot handler: orderType 0 = ORDER_TRAIN indexes
-- GameInfo.Units; ORDER_CONSTRUCT = buildings; ORDER_ZONE = districts.
function BetweenTurns.onCityProductionCompleted(pid, cityID, orderType, objType, canceled)
    if not _collecting then return; end
    local lp = localPlayer();
    if pid ~= lp or canceled == true then return; end
    local item = nil;
    pcall(function()
        local row = nil;
        if OrderTypes ~= nil then
            if     orderType == OrderTypes.ORDER_TRAIN     then row = GameInfo.Units[objType];
            elseif orderType == OrderTypes.ORDER_CONSTRUCT then row = GameInfo.Buildings[objType];
            elseif orderType == OrderTypes.ORDER_ZONE      then row = GameInfo.Districts[objType];
            end
        end
        if row ~= nil and row.Name ~= nil then item = Locale.Lookup(row.Name); end
    end);
    local cityName = "a city";
    pcall(function()
        local c = Players[pid]:GetCities():FindID(cityID);
        if c ~= nil then cityName = Locale.Lookup(c:GetName()); end
    end);
    _built[#_built + 1] = { city = cityName, cityID = cityID, item = item };
end

-- City damage: shape UNCONFIRMED — log only (the UnitCombat pattern). Once a
-- live siege shows the args, wire "your city was attacked" into the briefing.
function BetweenTurns.onCityDamageEvent(...)
    if not BT_DEBUG then return; end
    local n = select("#", ...);
    local a = { ... };
    local parts = {};
    for i = 1, n do parts[i] = tostring(a[i]); end
    Log.info("BetweenTurns city-damage event n=" .. n .. " [" .. table.concat(parts, ", ") .. "]");
end

-- ---------------------------------------------------------------------------
--  compose + speak (armed at turn begin, fired after the activation pump so
--  the player's own heal tick is included)
-- ---------------------------------------------------------------------------

local MAX_MOVE_LINES = 3;

local function compose()
    local lp = localPlayer();
    if lp == -1 then reset(); return; end
    local bits = {};

    for _, name in ipairs(_losses) do
        bits[#bits + 1] = "Your " .. name .. " was destroyed";
    end

    -- Production completions, each with what the city moved on to — a queue
    -- continuing without a word was exactly the Granary surprise.
    for _, b in ipairs(_built) do
        local line = b.city .. " completed " .. (b.item or "its build");
        local nextName, idle = nil, true;
        pcall(function()
            local c = Players[lp]:GetCities():FindID(b.cityID);
            local q = (c ~= nil) and c:GetBuildQueue() or nil;
            if q ~= nil and q.GetCurrentProductionTypeHash ~= nil then
                local hash = q:GetCurrentProductionTypeHash();
                if hash ~= nil and hash ~= 0 then
                    idle = false;
                    nextName = productionHashName(hash);
                end
            end
        end);
        if idle then
            line = line .. ", production needed";
        elseif nextName ~= nil then
            line = line .. ", now building " .. nextName;
        end
        bits[#bits + 1] = line;
    end

    -- Net HP change per own unit: negative = hurt, positive = recovered.
    for key, rec in pairs(_hp) do
        if rec.endDamage ~= nil and rec.endDamage ~= rec.startDamage then
            local uid = tonumber(key:match(":(%d+)$"));
            local unit = nil;
            pcall(function() unit = Players[lp]:GetUnits():FindID(uid); end);
            if unit ~= nil then
                local name = unitTypeName(unit);
                local hpLeft = math.max(0, rec.maxHP - rec.endDamage);
                local delta = rec.endDamage - rec.startDamage;   -- damage up = hurt
                if delta > 0 then
                    bits[#bits + 1] = "Your " .. name .. " was attacked, lost "
                        .. delta .. " HP, " .. hpLeft .. " of " .. rec.maxHP .. " left";
                else
                    bits[#bits + 1] = "Your " .. name .. " recovered " .. (-delta)
                        .. " HP, " .. hpLeft .. " of " .. rec.maxHP;
                end
            end
        end
    end

    -- Enemy movement, nearest-anchored, closest threats first, capped.
    local moves = {};
    for _, m in pairs(_moves) do moves[#moves + 1] = m; end
    for _, m in ipairs(moves) do
        local anchor, ax, ay = nearestOwnAnchor(lp, m.x, m.y);
        m._anchor, m._ax, m._ay = anchor, ax, ay;
        m._dist = (ax ~= nil) and (Map.GetPlotDistance(m.x, m.y, ax, ay) or 999) or 999;
    end
    table.sort(moves, function(a, b) return a._dist < b._dist; end);
    for i = 1, math.min(#moves, MAX_MOVE_LINES) do
        local m = moves[i];
        local unit = nil;
        pcall(function() unit = Players[m.pid]:GetUnits():FindID(m.uid); end);
        if unit ~= nil then
            local line = StringifyUnit(unit);
            -- directionString carries the distance itself ("2 east").
            local dir = (m._ax ~= nil) and HexGeom.directionString(m._ax, m._ay, m.x, m.y) or nil;
            if dir ~= nil and m._anchor ~= nil then
                line = line .. " " .. dir .. " of " .. m._anchor;
            elseif m._anchor ~= nil then
                line = line .. " at " .. m._anchor;
            end
            bits[#bits + 1] = line;
        end
    end
    if #moves > MAX_MOVE_LINES then
        bits[#bits + 1] = (#moves - MAX_MOVE_LINES) .. " more enemy units moved";
    end

    reset();
    if #bits == 0 then return; end   -- quiet night = silence (exceptions speak)
    Speech.emit("Overnight: " .. table.concat(bits, ". ") .. ".", "status");
end

function BetweenTurns.onLocalTurnBegin()
    if not _collecting then return; end
    if Events ~= nil and Events.GameCoreEventPublishComplete ~= nil then
        _composeArmed = true;   -- compose after this event batch (heal tick included)
    else
        _collecting = false;
        compose();
    end
end

function BetweenTurns.onEventPumpComplete()
    if not _composeArmed then return; end
    _composeArmed = false;
    _collecting = false;
    compose();
end

local function Initialize()
    Log.info("BetweenTurns.lua: file loaded");
    if Events == nil then
        Log.warn("BetweenTurns.Initialize: Events table unavailable");
        return;
    end
    local subs = {
        { ev = "LocalPlayerTurnEnd",          fn = BetweenTurns.onLocalTurnEnd },
        { ev = "LocalPlayerTurnBegin",        fn = BetweenTurns.onLocalTurnBegin },
        { ev = "UnitMoveComplete",            fn = BetweenTurns.onUnitMoveComplete },
        { ev = "UnitDamageChanged",           fn = BetweenTurns.onUnitDamageChanged },
        { ev = "UnitKilledInCombat",          fn = BetweenTurns.onUnitKilledInCombat },
        { ev = "CityProductionCompleted",     fn = BetweenTurns.onCityProductionCompleted },
        { ev = "GameCoreEventPublishComplete", fn = BetweenTurns.onEventPumpComplete },
        -- Guard-subscribed: exact event name for city damage varies by ruleset;
        -- whichever exists gets LOGGED until its shape is confirmed.
        { ev = "CityDamageChanged",           fn = BetweenTurns.onCityDamageEvent },
        { ev = "DistrictDamageChanged",       fn = BetweenTurns.onCityDamageEvent },
    };
    for _, s in ipairs(subs) do
        if Events[s.ev] ~= nil then
            Events[s.ev].Add(s.fn);
            Log.info("BetweenTurns.Initialize: subscribed to Events." .. s.ev);
        end
    end
end
Initialize();
