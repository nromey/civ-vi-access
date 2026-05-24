-- Per-turn-begin announcements for the local player.
--
-- Subscribes to Events.LocalPlayerTurnBegin (engine event) and speaks
-- a terse "Turn N." line via Tolk, plus a notification count if any
-- are pending. Skips turn 1 entirely — waypoint 08's first-turn
-- orientation handler (in ScreenReaderEventHandlers.lua, extended)
-- owns that moment, so we don't want to double-speak.
--
-- Registered under <AddGameplayScripts> in CivViAccessMod.modinfo so
-- it runs in the in-game Lua context where Game / Players are reachable.
-- The frontend context never loads this file — there are no turns in
-- the main menu.
--
-- Terse by design. This event fires every turn for the rest of the
-- game (hundreds of times in a long playthrough); long announces would
-- become unbearable. Future verbose mode (see project_verbosity_someday)
-- can add era + year context.

include("ScreenReader");
include("Log");

Log.info("TurnAnnouncements.lua: file loaded");

local function announceTurnBegin()
    local currentTurn = Game.GetCurrentGameTurn();
    local startTurn = GameConfiguration.GetStartTurn();

    -- Turn 1 is handled by the first-turn orientation flow in
    -- ScreenReaderEventHandlers.lua (waypoint 08). Speaking "Turn 1"
    -- here would step on the much richer orientation briefing, so
    -- we explicitly skip.
    if currentTurn == startTurn then
        Log.info("TurnAnnouncements: skipping turn-begin announce on turn "
                 .. tostring(currentTurn) .. " (first turn)");
        return;
    end

    local turnText = Locale.Lookup(
        "LOC_CIVVIACCESS_TURN_BEGIN_FORMAT", currentTurn);
    OutputMessageToScreenReader(turnText);

    -- Augment with a notification count when non-zero. Queued
    -- (nointerrupt=true) so the primary turn announce doesn't get
    -- cut off mid-word. Notifications themselves are spoken by other
    -- handlers as they arrive; this is a "you have N pending" cue,
    -- not a content readback.
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == nil or localPlayerID < 0 then
        return;
    end
    local pPlayer = Players[localPlayerID];
    if pPlayer == nil then
        return;
    end
    local notifications = pPlayer:GetNotifications();
    if notifications == nil then
        return;
    end
    local count = notifications:GetCount();
    if count ~= nil and count > 0 then
        OutputMessageToScreenReader(
            Locale.Lookup("LOC_CIVVIACCESS_TURN_NOTIFICATIONS_PENDING",
                          count),
            true);
    end
end

local function Initialize()
    if Events == nil or Events.LocalPlayerTurnBegin == nil then
        Log.warn("TurnAnnouncements: Events.LocalPlayerTurnBegin not available");
        return;
    end
    Events.LocalPlayerTurnBegin.Add(announceTurnBegin);
    Log.info("TurnAnnouncements: subscribed to LocalPlayerTurnBegin");
end

Initialize();
