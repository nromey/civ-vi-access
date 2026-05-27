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
    Speech.emit(turnText, "critical");

    -- Augment with a notification count when non-zero. Queued
    -- (nointerrupt=true) so the primary turn announce doesn't get
    -- cut off mid-word. Notifications themselves are spoken by other
    -- handlers as they arrive; this is a "you have N pending" cue,
    -- not a content readback.
    local localPlayerID = Game.GetLocalPlayer();
    if localPlayerID == nil or localPlayerID < 0 then
        return;
    end
    -- pPlayer:GetNotifications() and NotificationManager have no
    -- per-player count API; our Notifications module owns the cache
    -- (subscribes to Events.NotificationAdded / Dismissed and tracks
    -- per-player). Read pending count from there.
    if Notifications == nil or Notifications.pendingCount == nil then
        return;
    end
    local count = Notifications.pendingCount(localPlayerID);
    if count ~= nil and count > 0 then
        -- status: queues behind the turn-begin critical announce
        -- regardless of arrival timing.
        Speech.emit(
            Locale.Lookup("LOC_CIVVIACCESS_TURN_NOTIFICATIONS_PENDING",
                          count),
            "status");
    end
end

-- Announce when end-turn becomes available (all blockers cleared).
-- Civ VI gates end-turn on EndTurnBlockingTypes (production, research,
-- civic, units-need-orders, etc.). Engine fires
-- Events.EndTurnBlockingChanged(prevType, newType) on each transition.
-- We announce only on transitions TO NO_ENDTURN_BLOCKING — going FROM
-- "no blocker" to "new blocker" is already handled by the notification
-- speech that arrives with the new blocker. Per Noel 2026-05-25, the
-- gap this fills is "I went through 4 turns and didn't know when I
-- could end turn" — explicit audible "you're ready" beats silent
-- "the green button activated."
local function announceEndTurnBlockingChanged(prevType, newType)
    if EndTurnBlockingTypes == nil then return; end
    if newType ~= EndTurnBlockingTypes.NO_ENDTURN_BLOCKING then return; end
    if prevType == EndTurnBlockingTypes.NO_ENDTURN_BLOCKING then return; end
    -- meta tier: fires asynchronously from the engine after a unit
    -- action clears the last blocker. event-tier action-confirm speech
    -- ("Warrior fortify") fires from the user's keypress and sets its
    -- own shield; meta is below event's priority so this queues behind
    -- the action-confirmation rather than clobbering it.
    -- Chatty mode adds the actual keystroke hint per Noel 2026-05-27.
    local chatty = Verbosity ~= nil and Verbosity.isOn and Verbosity.isOn();
    local msg = chatty and "Ready to end turn. Press Enter to end turn."
                        or "Ready to end turn";
    Speech.emit(msg, "meta");
end

local function Initialize()
    if Events == nil or Events.LocalPlayerTurnBegin == nil then
        Log.warn("TurnAnnouncements: Events.LocalPlayerTurnBegin not available");
        return;
    end
    Events.LocalPlayerTurnBegin.Add(announceTurnBegin);
    Log.info("TurnAnnouncements: subscribed to LocalPlayerTurnBegin");
    if Events.EndTurnBlockingChanged ~= nil then
        Events.EndTurnBlockingChanged.Add(announceEndTurnBlockingChanged);
        Log.info("TurnAnnouncements: subscribed to EndTurnBlockingChanged");
    end
end

Initialize();
