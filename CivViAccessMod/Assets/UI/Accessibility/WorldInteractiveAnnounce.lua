-- Announce "World interactive" once at the start of a new game.
--
-- Fires on Events.LocalPlayerTurnBegin for turn 1 only — by which point
-- all blocking popups (expansion intro, first-turn advisor) have
-- dismissed and the engine has handed control to the player. Without
-- this, a blind player has no audible cue that control has returned
-- and the map is now navigable.
--
-- This is the bridge between the new-game flow (waypoints 03-06) and
-- the in-game loop. Spoken before the first-turn unit orientation
-- (waypoint 08, in ScreenReaderEventHandlers.lua) so the player hears
-- the "you can act now" cue before the unit-specific briefing starts.
--
-- Registered under <AddGameplayScripts> in CivViAccessMod.modinfo.

include("ScreenReader");
include("Log");

Log.info("WorldInteractiveAnnounce.lua: file loaded");

local _announced = false;

local function announceWorldInteractive()
    -- Only fire once per game session. Even if for some reason
    -- LocalPlayerTurnBegin fires again on turn 1 (multiplayer resync,
    -- hotseat handoff, etc.), we don't want to repeat this line.
    if _announced then
        return;
    end

    local currentTurn = Game.GetCurrentGameTurn();
    local startTurn = GameConfiguration.GetStartTurn();

    -- Only on the literal first turn. Subsequent turns get the
    -- per-turn "Turn N." announce from TurnAnnouncements.lua.
    if currentTurn ~= startTurn then
        return;
    end

    _announced = true;
    Speech.emit(
        Locale.Lookup("LOC_CIVVIACCESS_WORLD_INTERACTIVE"), "critical");
end

local function Initialize()
    if Events == nil or Events.LocalPlayerTurnBegin == nil then
        Log.warn("WorldInteractiveAnnounce: Events.LocalPlayerTurnBegin not available");
        return;
    end
    Events.LocalPlayerTurnBegin.Add(announceWorldInteractive);
    Log.info("WorldInteractiveAnnounce: subscribed to LocalPlayerTurnBegin");
end

Initialize();
