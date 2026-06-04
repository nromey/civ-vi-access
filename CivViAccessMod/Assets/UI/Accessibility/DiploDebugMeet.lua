-- DEBUG TOOL: force a REAL first contact each turn, to test the accessible
-- diplomacy screen against a genuine, PERSISTENT session.
--
-- WHY: the Alt+M debug "meet" only opens the diplo OVERVIEW with m_eventID 0,
-- which the engine immediately self-closes — a transient flash, useless for
-- testing input focus (cost ~a dozen cycles 2026-06-04; see
-- reference_civ_vi_diplomacy_input_wall + feedback_validate_test_harness). A
-- genuine first contact (meeting an UNMET civ) opens a persistent session:
--   GetDiplomacy():SetHasMet(otherID) -> Events.DiplomacyMeet
--     -> LeaderView ShowFirstMeetingLeader -> DiplomacyActionView opens
--     -> LuaEvents.DiploScene_SceneOpened -> our DiplomacyAccess  (the real test)
--
-- SetHasMet is a gameplay-state WRITE, so it MUST run in the GameCore VM — hence
-- a gameplay script (AddGameplayScripts), not the UI addin. (The same call is
-- used by the ColdWar / Tutorial scenario start scripts, so it's supported.) We
-- trigger on Events.LocalPlayerTurnBegin, which fires in GameCore, meeting ONE
-- unmet major civ per turn: just End Turn and a fresh real meet opens, re-armable.
--
-- DEV ONLY. Set DEBUG_FORCE_MEET = false (or strip this file from
-- AddGameplayScripts) before release. Noel 2026-06-04.

include("Log");

local DEBUG_FORCE_MEET = true;   -- master switch
local START_TURN       = 2;      -- skip turn 1 so first-turn popups don't collide

-- First alive, major, NOT-yet-met player (other than us), or nil.
local function firstUnmetMajor(localID)
    local pLocal = Players and Players[localID] or nil;
    if pLocal == nil or pLocal.GetDiplomacy == nil then return nil; end
    local localDip = pLocal:GetDiplomacy();
    if localDip == nil or localDip.HasMet == nil then return nil; end
    local maxP = (GameDefines and GameDefines.MAX_MAJOR_PLAYERS) or 64;
    for pid = 0, maxP - 1 do
        if pid ~= localID then
            local p = Players and Players[pid] or nil;
            local ok, unmet = pcall(function()
                return p ~= nil and p:IsAlive() and p:IsMajor() and not localDip:HasMet(pid);
            end);
            if ok and unmet == true then return pid; end
        end
    end
    return nil;
end

local function onLocalPlayerTurnBegin()
    if not DEBUG_FORCE_MEET then return; end
    if Game == nil or Game.GetLocalPlayer == nil then return; end
    local localID = Game.GetLocalPlayer();
    if localID == nil or localID < 0 then return; end
    local turn = (Game.GetCurrentGameTurn ~= nil) and Game.GetCurrentGameTurn() or 0;
    if turn < START_TURN then return; end

    local target = firstUnmetMajor(localID);
    if target == nil then
        Log.info("DiploDebugMeet: no unmet major civ left to force-meet (turn "
                 .. tostring(turn) .. "). Start an earlier game / one with civs you "
                 .. "have not met to get a real first contact.");
        return;
    end

    Log.info("DiploDebugMeet: forcing first contact local=" .. tostring(localID)
             .. " other=" .. tostring(target) .. " turn=" .. tostring(turn));
    -- Set both directions so the meet is mutual (scenario scripts do all pairs).
    local pDip = Players[localID]:GetDiplomacy();
    if pDip ~= nil and pDip.SetHasMet ~= nil then
        local ok, err = pcall(function() pDip:SetHasMet(target); end);
        if not ok then Log.warn("DiploDebugMeet: local SetHasMet failed: " .. tostring(err)); end
    else
        Log.warn("DiploDebugMeet: SetHasMet not available in this VM");
        return;
    end
    local pOtherDip = Players[target] and Players[target].GetDiplomacy
                      and Players[target]:GetDiplomacy() or nil;
    if pOtherDip ~= nil and pOtherDip.SetHasMet ~= nil then
        pcall(function() pOtherDip:SetHasMet(localID); end);
    end
end

if Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
    Events.LocalPlayerTurnBegin.Add(onLocalPlayerTurnBegin);
    -- Confirm the meet actually processed (this firing => SetHasMet triggered the
    -- real first-contact path; absence => it only set a flag and we must try a
    -- different trigger).
    if Events.DiplomacyMeet ~= nil then
        Events.DiplomacyMeet.Add(function(p1, p2)
            Log.info("DiploDebugMeet: Events.DiplomacyMeet fired p1=" .. tostring(p1)
                     .. " p2=" .. tostring(p2) .. " (real first contact processed)");
        end);
    end
    Log.info("DiploDebugMeet: loaded (DEBUG_FORCE_MEET=" .. tostring(DEBUG_FORCE_MEET)
             .. ", START_TURN=" .. tostring(START_TURN) .. ")");
else
    Log.warn("DiploDebugMeet: Events.LocalPlayerTurnBegin unavailable — not loaded");
end
