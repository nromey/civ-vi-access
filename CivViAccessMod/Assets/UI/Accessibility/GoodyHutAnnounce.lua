-- GoodyHutAnnounce.lua — speak the reward from a tribal village (goody hut).
--
-- When a unit enters a tribal village the engine grants a random reward and
-- floats the reward text in the world view ("+50 Gold", "Eureka!", etc.) —
-- generated engine-side (C++), so it's silent for a screen reader. We subscribe
-- Events.GoodyHutReward and speak it.
--
-- Reward families (GameInfo.GoodyHuts / GoodyHutSubTypes):
--   Gold / Faith  — small/medium/large yield  (have a Description)
--   Science       — one free Tech, or 1-2 tech boosts (boosts: no Description)
--   Culture       — one Relic (Description), or 1-2 civic boosts (no Description)
--   Military      — free Scout / unit upgrade / +XP / full heal (Description)
--   Survivors     — Builder / Trader / Settler / +1 pop (Description)
-- GoodyHutSubTypes.Description is a LOC key; ~14 of 18 subtypes have one, the
-- pure-boost subtypes don't (those fall back to a family-level phrase).
--
-- SIGNATURE NOT YET KNOWN: no base or expansion Lua reads this event's args, so
-- on every fire we LOG all args ("GoodyHutAnnounce: args ...") to discover the
-- real shape from a live trigger, while still making a best-effort announce.
-- Once the live log shows the arg order, lock resolveReward() to it and trim
-- the probing. Runs in the HexCursorAddin UI VM (Events.* fire in every VM).

include("Log");

GoodyHutAnnounce = GoodyHutAnnounce or {};

local function lp()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

-- Family-level phrase for a goody hut TYPE hash (used when a subtype has no
-- Description, e.g. tech/civic boosts).
local function familyPhrase(typeRow)
    if typeRow == nil then return nil; end
    local t = typeRow.GoodyHutType;
    if t == "GOODYHUT_SCIENCE" then return "a technology boost"; end
    if t == "GOODYHUT_CULTURE" then return "a civic boost"; end
    if t == "GOODYHUT_GOLD"    then return "gold"; end
    if t == "GOODYHUT_FAITH"   then return "faith"; end
    if t == "GOODYHUT_MILITARY" then return "a military reward"; end
    if t == "GOODYHUT_SURVIVORS" then return "survivors"; end
    return nil;
end

-- Best-effort: probe each event arg against the GoodyHutSubTypes and GoodyHuts
-- tables and return a spoken reward phrase, or nil if nothing resolves.
local function resolveReward(args)
    if GameInfo == nil then return nil; end
    -- (1) An arg that is a GoodyHutSubTypes key -> its Description, else family.
    if GameInfo.GoodyHutSubTypes ~= nil then
        for _, v in ipairs(args) do
            local row = nil;
            pcall(function() row = GameInfo.GoodyHutSubTypes[v]; end);
            if row ~= nil then
                if row.Description ~= nil and row.Description ~= "" then
                    return Locale.Lookup(row.Description);
                end
                local tRow = nil;
                pcall(function() tRow = GameInfo.GoodyHuts[row.GoodyHut]; end);
                local fam = familyPhrase(tRow);
                if fam ~= nil then return fam; end
            end
        end
    end
    -- (2) An arg that is a GoodyHuts (family) key -> family phrase.
    if GameInfo.GoodyHuts ~= nil then
        for _, v in ipairs(args) do
            local tRow = nil;
            pcall(function() tRow = GameInfo.GoodyHuts[v]; end);
            local fam = familyPhrase(tRow);
            if fam ~= nil then return fam; end
        end
    end
    return nil;
end

local function onGoodyHutReward(...)
    local args = { ... };

    -- Log every arg so we can learn the real signature from a live trigger.
    local parts = {};
    for i = 1, select("#", ...) do
        parts[#parts + 1] = i .. "=" .. tostring((select(i, ...)));
    end
    Log.info("GoodyHutAnnounce: args " .. table.concat(parts, " "));

    -- If the first arg looks like a player id, ignore other players' rewards.
    local localID = lp();
    local first = args[1];
    if type(first) == "number" and first >= 0 and localID >= 0 and first ~= localID then
        return;
    end

    local reward = resolveReward(args);
    if reward ~= nil and reward ~= "" then
        Speech.emit("Tribal village: you received " .. reward .. ".", "event");
    else
        -- Couldn't resolve yet (we'll know why from the logged args).
        Speech.emit("You received a reward from a tribal village.", "event");
    end
end

local function Initialize()
    if Events ~= nil and Events.GoodyHutReward ~= nil then
        Events.GoodyHutReward.Add(onGoodyHutReward);
        Log.info("GoodyHutAnnounce: subscribed to Events.GoodyHutReward");
    else
        Log.warn("GoodyHutAnnounce: Events.GoodyHutReward unavailable");
    end
end
Initialize();

Log.info("GoodyHutAnnounce.lua: loaded");
