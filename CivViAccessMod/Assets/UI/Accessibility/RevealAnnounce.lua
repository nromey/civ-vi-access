-- RevealAnnounce — Tier 1 of the spatial-awareness loop (sense -> locate -> act).
--
-- As fog of war lifts (a unit explores), summarize what was just uncovered in
-- ONE terse line per move: "Uncovered 6 hexes: 4 plains, 2 rainforest. Resources:
-- horses." This is the AWARENESS layer; the scanner (tier 2) then locates a
-- feature and the routes builder (tier 3) travels to it. See
-- docs/SPATIAL_AWARENESS_PLAN.md.
--
-- THE FIREHOSE PROBLEM (the whole reason this needs care): the engine fires
-- Events.PlotVisibilityChanged ONCE PER PLOT, and it re-fires every time a tile
-- flips REVEALED<->VISIBLE as units walk through already-known territory. Naively
-- announcing per event would bury the player. Two mechanisms tame it:
--   1. COALESCE: accumulate plots on PlotVisibilityChanged, emit ONE summary on
--      Events.GameCoreEventPublishComplete (fires once after each event batch —
--      i.e. once per move, not once per hex).
--   2. DEDUP: an m_everSeen set; a plot is only ever counted the FIRST time it's
--      revealed, so re-entering known territory says nothing.
-- A LoadGameViewStateDone gate absorbs the big startup/load reveal volley silently
-- (same gate the era-complete handler uses) so we don't narrate the whole starting
-- area on load.
--
-- LIVE-TUNE (deliberately NOT pre-tuned blind): the verbosity threshold (suppress
-- 1-2 routine hexes? always announce resources / rivers / another civ's border?)
-- waits on a live test — fire it, read Lua.log, tune. MVP = summarize every batch.
--
-- Hosted by RevealListeners (the live InGame UI-VM addin that already subscribes
-- to engine Events.*); RevealListeners calls RevealAnnounce.Initialize(). These
-- visibility events are UI-side, so the UI addin's VM is the right home.

include("ScreenReader");                -- Speech.emit
include("ScreenReaderPlotUtils");       -- TerrainName / FeatureName / ResourceName (global)
include("Log");

RevealAnnounce = RevealAnnounce or {};

-- ===========================================================================
--  State
-- ===========================================================================
local m_everSeen = {};      -- set: plotIndex -> true once counted as revealed
local m_pending  = {};      -- array of plotIndex accumulated since last flush
local m_ready    = false;   -- gate: absorb the startup/load reveal volley silently

local function localPlayer()
    return (Game ~= nil and Game.GetLocalPlayer ~= nil) and Game.GetLocalPlayer() or -1;
end

-- Is the plot now genuinely revealed to the LOCAL player? PlotVisibilityChanged
-- is NOT player-scoped (fires for any player's visibility change), so we filter
-- to plots the local player can actually see — other players' changes report
-- IsRevealed(local) == false and drop out. Guarded: if the visibility API is
-- absent we fall back to accepting (better to over-announce than silently break).
local function revealedToLocal(plotIndex)
    if PlayersVisibility == nil then return true; end
    local lp = localPlayer();
    local vis = (lp >= 0) and PlayersVisibility[lp] or nil;
    if vis == nil or vis.IsRevealed == nil then return true; end
    local ok, isRev = pcall(function() return vis:IsRevealed(plotIndex); end);
    if not ok then return true; end
    return isRev == true;
end

-- A short label for one plot: the salient FEATURE if present (rainforest,
-- mountains, forest...), else the terrain (plains, grassland, hills...). Matches
-- how a player thinks of a tile ("that's rainforest", not "that's plains").
local function plotLabel(plot)
    if plot == nil then return nil; end
    if FeatureName ~= nil then
        local f = FeatureName(plot);
        if f ~= nil and f ~= "" then return f; end
    end
    if TerrainName ~= nil then
        local t = TerrainName(plot);
        if t ~= nil and t ~= "" then return t; end
    end
    return nil;
end

-- ===========================================================================
--  Summary builder
-- ===========================================================================
-- Turn the pending plot batch into one spoken line. Counts plots by label and
-- collects any resources (high-value while exploring — what you settle toward).
local function buildSummary(plotIndices)
    if Map == nil or Map.GetPlotByIndex == nil then return nil; end
    local n = 0;
    local counts, order = {}, {};      -- label -> count, plus insertion order
    local resCounts, resOrder = {}, {};

    for _, idx in ipairs(plotIndices) do
        local plot = Map.GetPlotByIndex(idx);
        if plot ~= nil then
            n = n + 1;
            local label = plotLabel(plot) or "unknown";
            if counts[label] == nil then order[#order + 1] = label; end
            counts[label] = (counts[label] or 0) + 1;
            if ResourceName ~= nil then
                local r = ResourceName(plot);
                if r ~= nil and r ~= "" then
                    if resCounts[r] == nil then resOrder[#resOrder + 1] = r; end
                    resCounts[r] = (resCounts[r] or 0) + 1;
                end
            end
        end
    end
    if n == 0 then return nil; end

    local terrainParts = {};
    for _, label in ipairs(order) do
        terrainParts[#terrainParts + 1] = tostring(counts[label]) .. " " .. label;
    end
    local line = "Uncovered " .. tostring(n) .. " "
        .. (n == 1 and "hex" or "hexes") .. ": " .. table.concat(terrainParts, ", ");

    if #resOrder > 0 then
        local resParts = {};
        for _, r in ipairs(resOrder) do
            resParts[#resParts + 1] = (resCounts[r] > 1) and (tostring(resCounts[r]) .. " " .. r) or r;
        end
        line = line .. ". Resources: " .. table.concat(resParts, ", ");
    end
    return line;
end

local function speak(text)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then
        -- "status" kind: informational, non-interrupting (per terse-default).
        Speech.emit(text, "status");
    end
end

-- ===========================================================================
--  Event handlers
-- ===========================================================================
local function OnPlotVisibilityChanged(x, y, visibilityType)
    if Map == nil or Map.GetPlotIndex == nil then return; end
    local idx = Map.GetPlotIndex(x, y);
    if idx == nil or idx < 0 then return; end
    if m_everSeen[idx] then return; end        -- dedup: only the first reveal counts
    if not revealedToLocal(idx) then return; end
    m_everSeen[idx] = true;
    m_pending[#m_pending + 1] = idx;
end

-- Fires once after each game-core event batch (i.e. once per move) — the seam
-- where we coalesce the batch into one announce. Before m_ready we silently drain
-- (the plots are already in m_everSeen, so they won't re-announce later).
local function OnGameCoreEventPublishComplete()
    if #m_pending == 0 then return; end
    if not m_ready then m_pending = {}; return; end
    local summary = buildSummary(m_pending);
    m_pending = {};
    speak(summary);
end

local function OnLoadGameViewStateDone()
    m_ready = true;
end

-- ===========================================================================
--  Debug — test the SUMMARY FORMATTING against real map data without needing
--  fog (synthesizing a fog reveal is impractical). Grabs the plots in `radius`
--  around the selected unit (or the local player's first city) and runs them
--  through the same summary path. Validates naming + counting + resource callout.
--    LuaEvents.CivViAccess_DebugRevealAround()        -- radius 2
--    LuaEvents.CivViAccess_DebugRevealAround(3)
-- ===========================================================================
local function debugAround(radius)
    radius = radius or 2;
    local cx, cy = nil, nil;
    if UI ~= nil and UI.GetHeadSelectedUnit ~= nil then
        local u = UI.GetHeadSelectedUnit();
        if u ~= nil then cx, cy = u:GetX(), u:GetY(); end
    end
    if cx == nil then
        local p = Players and Players[localPlayer()] or nil;
        local cities = p and p.GetCities and p:GetCities() or nil;
        if cities ~= nil then
            for _, c in cities:Members() do if c ~= nil then cx, cy = c:GetX(), c:GetY(); break; end end
        end
    end
    if cx == nil then Log.warn("RevealAnnounce debug: no selected unit or city to center on"); return; end

    local idxs = {};
    if Map ~= nil and Map.GetPlotIndex ~= nil then
        for dx = -radius, radius do
            for dy = -radius, radius do
                local px, py = cx + dx, cy + dy;
                local idx = Map.GetPlotIndex(px, py);
                if idx ~= nil and idx >= 0 then idxs[#idxs + 1] = idx; end
            end
        end
    end
    local summary = buildSummary(idxs);
    Log.info("RevealAnnounce debug: " .. tostring(summary));
    speak(summary or "No hexes to summarize");
end

-- ===========================================================================
--  Init — called by the host addin (RevealListeners) in its live UI VM.
-- ===========================================================================
function RevealAnnounce.Initialize()
    if Events ~= nil then
        if Events.PlotVisibilityChanged ~= nil then Events.PlotVisibilityChanged.Add(OnPlotVisibilityChanged); end
        if Events.GameCoreEventPublishComplete ~= nil then Events.GameCoreEventPublishComplete.Add(OnGameCoreEventPublishComplete); end
        if Events.LoadGameViewStateDone ~= nil then Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone); end
    end
    if LuaEvents ~= nil and LuaEvents.CivViAccess_DebugRevealAround ~= nil then
        LuaEvents.CivViAccess_DebugRevealAround.Add(debugAround);
    end
    Log.info("RevealAnnounce.lua: tier-1 reveal announce ready (coalesce + dedup + load-gate)");
end

Log.info("RevealAnnounce.lua: loaded");
