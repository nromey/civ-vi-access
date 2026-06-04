-- LeaderMeetAnnounce.lua — make the otherwise-silent leader / diplomacy screen
-- READABLE. Called from HexCursorAddin's Events.ShowLeaderScreen handler.
--
-- v1 (2026-06-01): speak WHO (leader of civ) + their MOOD rendered as an
-- expression ([[LeaderMoodExpressions]]) + how to leave. Escape dismisses the
-- screen cleanly (DiplomacyActionView KeyHandler → CloseFocusedState → Close).
--
-- v2 (2026-06-01): speak WHAT THE LEADER SAYS — the greeting / statement line.
-- The text the screen shows lives in DiplomacyActionView's own VM:
-- ApplyStatement() does Controls.LeaderResponseText:SetText(leaderstr) (and
-- VoiceoverText for the cinema first-meet), built via DiplomacyManager.FindTextKey
-- (DiplomacyActionView.lua:575-620). We can't cheaply rebuild that text (it needs
-- the statement handler / ExtractStatement machinery), so we READ the populated
-- control cross-context. ContextPtr:LookUpControl resolves absolute paths across
-- contexts in this codebase (HexCursorAddin already reads "/InGame/ProductionPanel"
-- that way), so we read "/InGame/DiplomacyActionView/<control>".
--
-- Timing: the text may be set slightly after Events.ShowLeaderScreen, so we read
-- on the screen-shown hook AND subscribe to Events.DiplomacyStatement (fires in
-- this VM too) as a deferred catch. Deduped per encounter so it speaks once.
-- INSTRUMENTED: logs which candidate control path produced text, so the live
-- test pins the exact path to lock in.
--
-- Mood chain (recon 2026-06-01 from DiplomacyActionView.lua /
-- DiplomacyStatementSupport.lua):
--   pPlayer:GetDiplomaticAI():GetDiplomaticStateIndex(localPlayer)
--     -> GameInfo.DiplomaticStates[iState].Hash -> our conceptual bucket.

include("ScreenReader");
include("LeaderMoodExpressions");
include("Log");

LeaderMeetAnnounce = LeaderMeetAnnounce or {};

-- Candidate absolute control paths for the leader's spoken line, tried in
-- order. LeaderResponseText (conversation mode) is VALIDATED 2026-06-02 — it's
-- the path that returned the leader's line on a meet / re-open. VoiceoverText
-- is kept for the first-meet cinematic (not yet observed live), where the
-- spoken line lives in the cinema label instead. (LeaderReasonText was an
-- unvalidated guess and dropped once LeaderResponseText proved out.)
local RESPONSE_TEXT_PATHS = {
    "/InGame/DiplomacyActionView/LeaderResponseText",
    "/InGame/DiplomacyActionView/VoiceoverText",
};

-- Per-encounter state so the greeting speaks exactly once and a new
-- encounter can speak again.
local _greetingSpoken = false;
local _lastGreeting = nil;

local function lp()
    return (Game ~= nil and Game.GetLocalPlayer ~= nil) and Game.GetLocalPlayer() or -1;
end

-- ShowLeaderScreen hands us a leader TYPE name ("LEADER_TOKUGAWA"), not a player.
-- Find the foreign player whose leader type matches.
local function playerForLeader(leaderName, localPlayerID)
    if leaderName == nil then return nil, nil; end
    local maxP = (GameDefines and GameDefines.MAX_CIV_PLAYERS) or 64;
    for pid = 0, maxP - 1 do
        if pid ~= localPlayerID then
            local cfg = PlayerConfigurations and PlayerConfigurations[pid] or nil;
            if cfg ~= nil and cfg.GetLeaderTypeName ~= nil then
                local ok, ltn = pcall(function() return cfg:GetLeaderTypeName(); end);
                if ok and ltn == leaderName then return pid, cfg; end
            end
        end
    end
    return nil, nil;
end

-- Map a DiplomaticStates row to a LeaderMoodExpressions bucket. Uses .Hash vs the
-- DiplomaticStates enum; a nil/missing constant simply won't match -> "neutral".
-- (Civ VI states cover most buckets; guarded/afraid/deceptive have no direct
-- vanilla state and stay reserved in the phrase table for a future signal.)
local function moodBucket(stateRow)
    if stateRow == nil then return "neutral"; end
    local DS = DiplomaticStates;
    local h = stateRow.Hash;
    if DS ~= nil and h ~= nil then
        if     h == DS.WAR             then return "war";
        elseif h == DS.DENOUNCED       then return "hostile";
        elseif h == DS.UNFRIENDLY      then return "unfriendly";
        elseif h == DS.ALLIED          then return "allied";
        elseif h == DS.DECLARED_FRIEND then return "allied";
        elseif h == DS.FRIENDLY        then return "friendly";
        end
    end
    return "neutral";
end

local function moodExpression(pid, localPlayerID)
    local pPlayer = Players and Players[pid] or nil;
    if pPlayer == nil or pPlayer.GetDiplomaticAI == nil then return nil; end
    local ok, ai = pcall(function() return pPlayer:GetDiplomaticAI(); end);
    if not ok or ai == nil or ai.GetDiplomaticStateIndex == nil then return nil; end
    local ok2, iState = pcall(function() return ai:GetDiplomaticStateIndex(localPlayerID); end);
    if not ok2 or iState == nil then return nil; end
    local row = GameInfo.DiplomaticStates and GameInfo.DiplomaticStates[iState] or nil;
    local bucket = moodBucket(row);
    local turn = (Game and Game.GetCurrentGameTurn) and Game.GetCurrentGameTurn() or 0;
    return LeaderMoodExpressions.pick(bucket, pid + turn);
end

-- Read the leader's spoken line from DiplomacyActionView's control tree.
-- Returns (cleanText, pathThatWorked) or nil. Cross-context absolute
-- LookUpControl is the same technique HexCursorAddin uses for
-- "/InGame/ProductionPanel".
local function readResponseText()
    if ContextPtr == nil or ContextPtr.LookUpControl == nil then return nil; end
    for _, path in ipairs(RESPONSE_TEXT_PATHS) do
        local ok, ctrl = pcall(function() return ContextPtr:LookUpControl(path); end);
        if ok and ctrl ~= nil and ctrl.GetText ~= nil then
            local okT, raw = pcall(function() return ctrl:GetText(); end);
            if okT and raw ~= nil then
                local clean = stripIconTags(raw);
                if clean ~= nil and clean ~= "" then
                    return clean, path;
                end
            end
        end
    end
    return nil;
end

-- Speak the greeting once per encounter (deduped). Returns true if spoken.
local function trySpeakGreeting()
    if _greetingSpoken then return true; end
    local text, path = readResponseText();
    if text == nil then return false; end
    if text == _lastGreeting then
        -- Same text we already have; mark spoken to stop retrying.
        _greetingSpoken = true;
        return true;
    end
    _lastGreeting = text;
    _greetingSpoken = true;
    -- Queue after the who+mood preamble (status tier never clobbers the
    -- critical-tier preamble in flight). The "Press Escape to exit" hint is
    -- appended HERE so it lands LAST — after what the leader says — per Noel's
    -- ordering (introduce -> mood -> speech -> Escape), in the same emit so it
    -- can't be separated from the greeting (immediate or deferred).
    Speech.emit(text .. " Press Escape to exit.", "status");
    Log.info("LeaderMeetAnnounce: greeting (via " .. tostring(path) .. "): " .. text);
    return true;
end

-- Called on Events.ShowLeaderScreen(leaderName, isLocalPlayer).
function LeaderMeetAnnounce.OnLeaderScreen(leaderName, isLocalPlayer)
    if isLocalPlayer == true then return; end    -- our own leader; nothing to announce
    local localPlayerID = lp();
    if localPlayerID < 0 then return; end
    -- New encounter — allow the greeting to speak again.
    _greetingSpoken = false;
    _lastGreeting = nil;
    local pid, cfg = playerForLeader(leaderName, localPlayerID);
    if cfg == nil then
        Log.warn("LeaderMeetAnnounce: no player matched leader " .. tostring(leaderName));
        return;
    end
    local name = (cfg.GetLeaderName ~= nil) and Locale.Lookup(cfg:GetLeaderName())
                 or tostring(leaderName);
    -- Short description ("Japan") not full ("Japanese Empire"): the full form
    -- needs an article ("the Japanese Empire") we'd have to special-case, and
    -- the short form matches DiplomacyAccess so the civ isn't named two ways
    -- (Noel 2026-06-03).
    local civ  = (cfg.GetCivilizationShortDescription ~= nil)
                 and Locale.Lookup(cfg:GetCivilizationShortDescription()) or nil;
    local line = name;
    if civ ~= nil and civ ~= "" then line = line .. " of " .. civ; end
    local expr = moodExpression(pid, localPlayerID);
    if expr ~= nil and expr ~= "" then line = line .. " " .. expr; end
    line = line .. ".";
    -- NOTE: the "Press Escape to exit" hint is intentionally NOT here — it's
    -- appended to the greeting (trySpeakGreeting) so it comes LAST, after what
    -- the leader says (Noel 2026-06-02: introduce -> mood -> speech -> Escape).
    Speech.emit(line, "critical");
    Log.info("LeaderMeetAnnounce: " .. line);

    -- Try to read + speak what the leader says. The text may not be set on
    -- the control yet at ShowLeaderScreen time; the Events.DiplomacyStatement
    -- subscription below catches the deferred case.
    trySpeakGreeting();
end

-- Events.DiplomacyStatement fires (in this VM too) when a leader statement is
-- applied — including the first-meet greeting and any later thing they say.
-- By the time it fires, ApplyStatement has set the response control, so this
-- is the reliable read point if ShowLeaderScreen was too early.
local function onDiplomacyStatement(fromPlayer, toPlayer, kVariants)
    local localPlayerID = lp();
    if localPlayerID < 0 then return; end
    if fromPlayer == localPlayerID then return; end   -- our own statements
    if toPlayer ~= localPlayerID and fromPlayer ~= localPlayerID then return; end
    -- Read on this event (text is populated now). Not gated on _greetingSpoken
    -- being false here — trySpeakGreeting handles the dedupe — but we DO reset
    -- per encounter in OnLeaderScreen so a fresh statement can speak.
    trySpeakGreeting();
end

local function onHideLeaderScreen()
    _greetingSpoken = false;
    _lastGreeting = nil;
end

-- ---------------------------------------------------------------------------
-- Debug: open diplomacy with a met leader on demand, so we can test the meet
-- announce + lock in the greeting control path WITHOUT waiting for a natural
-- first contact (they're rare). Mirrors the mod's FireTuner debug convention
-- (CivViAccess_Debug*). From the FireTuner console, InGame state:
--   LuaEvents.CivViAccess_DebugMeetLeader()      -- first met major civ
--   LuaEvents.CivViAccess_DebugMeetLeader(3)     -- a specific player ID
-- It raises the same event the diplomacy ribbon uses to open the real
-- DiplomacyActionView (so LeaderResponseText / VoiceoverText actually
-- populate), then drives our OnLeaderScreen so the who+mood preamble speaks;
-- the greeting read is deferred via the Events.DiplomacyStatement subscription.
-- ---------------------------------------------------------------------------
local function firstMetMajor(localPlayerID)
    local localDip = (Players and Players[localPlayerID] ~= nil
                      and Players[localPlayerID].GetDiplomacy ~= nil)
                     and Players[localPlayerID]:GetDiplomacy() or nil;
    local maxP = (GameDefines and GameDefines.MAX_MAJOR_PLAYERS) or 64;
    for pid = 0, maxP - 1 do
        if pid ~= localPlayerID then
            local p = Players and Players[pid] or nil;
            local ok = false;
            pcall(function()
                ok = p ~= nil and p:IsAlive() and p:IsMajor()
                     and (localDip == nil or localDip:HasMet(pid));
            end);
            if ok then return pid; end
        end
    end
    return nil;
end

-- #2 (first-contact screen) BUILD PROBE. The biggest unknown for building the
-- navigable diplomacy screen is whether OUR addin VM can reach the engine's
-- statement-extraction machinery (DiplomacyStatementSupport), or whether the
-- screen must drive it from inside the DiplomacyActionView Context via LuaEvent.
-- This turns that guess into a fact: it include()s the support file, logs which
-- functions are callable here, then runs a sample GREETING extraction and logs
-- the live valid-selection keys. Pure logging (no UI/speech), pcall-guarded.
-- Rides on Alt+M so the morning meet doubles as recon. Read Lua.log for
-- "DiploProbe:" lines.
local function probeStatementAccess(localID, otherID)
    pcall(function() include("DiplomacyStatementSupport"); end);
    local function avail(name, v) Log.info("DiploProbe: " .. name .. " = " .. tostring(v ~= nil)); end
    avail("GetStatementHandler", GetStatementHandler);
    avail("DiplomacySupport_RemoveInvalidSelections", DiplomacySupport_RemoveInvalidSelections);
    avail("DiplomacySupport_RemoveSelectionByKey", DiplomacySupport_RemoveSelectionByKey);
    avail("DiplomacyMoodTypes", DiplomacyMoodTypes);
    avail("DiplomacyInitiatorTypes", DiplomacyInitiatorTypes);
    if GetStatementHandler == nil then
        Log.warn("DiploProbe: GetStatementHandler unreachable from this VM -> the "
            .. "screen must drive extraction from the DiplomacyActionView Context "
            .. "(via LuaEvent), not ours.");
        return;
    end
    local ok, err = pcall(function()
        local handler = GetStatementHandler("GREETING");
        if handler == nil or handler.ExtractStatement == nil then
            Log.warn("DiploProbe: handler or ExtractStatement is nil");
            return;
        end
        local parsed = handler.ExtractStatement(handler, "GREETING", "NONE", localID,
            DiplomacyMoodTypes.ANY, DiplomacyInitiatorTypes.HUMAN);
        if DiplomacySupport_RemoveInvalidSelections ~= nil then
            DiplomacySupport_RemoveInvalidSelections(parsed, localID, otherID);
        end
        local keys = {};
        if parsed ~= nil and parsed.Selections ~= nil then
            for _, sel in ipairs(parsed.Selections) do
                keys[#keys + 1] = tostring(sel.Key) .. (sel.IsDisabled and "(disabled)" or "");
            end
        end
        Log.info("DiploProbe: GREETING valid selections (" .. #keys .. "): "
            .. table.concat(keys, ", "));
    end);
    if not ok then
        Log.warn("DiploProbe: sample extraction errored (" .. tostring(err)
            .. ") -> likely must run inside the diplomacy Context.");
    end
end

function LeaderMeetAnnounce.DebugMeet(playerID)
    local localID = lp();
    if localID < 0 then Speech.emit("Debug meet: no local player", "meta"); return; end
    local target = playerID;
    if target == nil or target < 0 then target = firstMetMajor(localID); end
    if target == nil then
        Speech.emit("Debug meet: no met major civ found", "meta");
        Log.warn("DebugMeet: no met major civ found");
        return;
    end
    local cfg = PlayerConfigurations and PlayerConfigurations[target] or nil;
    local ltn = (cfg ~= nil and cfg.GetLeaderTypeName ~= nil) and cfg:GetLeaderTypeName() or nil;
    Log.info("DebugMeet: opening diplomacy with player " .. tostring(target)
             .. " leader=" .. tostring(ltn));
    -- Recon for building the first-contact screen (#2): logs whether our VM can
    -- reach the statement extraction + the live selection list. See Lua.log
    -- "DiploProbe:" lines after the meet.
    probeStatementAccess(localID, target);
    Speech.emit("Debug: opening diplomacy", "meta");
    -- Open the real screen (the same event the diplomacy ribbon raises).
    -- VALIDATED 2026-06-02: this DOES raise Events.ShowLeaderScreen even for an
    -- already-met leader, so OnShowLeaderScreen -> OnLeaderScreen runs the
    -- announce on its own. We must NOT also call OnLeaderScreen here, or the
    -- preamble + greeting speak twice (the double Noel heard on first test).
    if LuaEvents ~= nil and LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView ~= nil then
        LuaEvents.DiplomacyRibbon_OpenDiplomacyActionView(target);
    else
        Speech.emit("Debug meet: open-diplomacy event unavailable", "meta");
    end
end

local function Initialize()
    if Events ~= nil and Events.DiplomacyStatement ~= nil then
        Events.DiplomacyStatement.Add(onDiplomacyStatement);
        Log.info("LeaderMeetAnnounce: subscribed to Events.DiplomacyStatement");
    end
    if Events ~= nil and Events.HideLeaderScreen ~= nil then
        Events.HideLeaderScreen.Add(onHideLeaderScreen);
    end
    if LuaEvents ~= nil then
        LuaEvents.CivViAccess_DebugMeetLeader.Add(function(pid)
            LeaderMeetAnnounce.DebugMeet(pid);
        end);
        Log.info("LeaderMeetAnnounce: debug hook CivViAccess_DebugMeetLeader registered");
    end
end
Initialize();

Log.info("LeaderMeetAnnounce.lua: loaded");
