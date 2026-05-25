-- Screen-reader announcement of in-game engine notifications.
--
-- Civ VI's notification system is how the game tells the player "you
-- need to make a decision" — choose research, choose civic, production
-- queue empty, war declared, wonder built. Most are end-turn blockers;
-- without speaking them, a blind player has no audible cue that the
-- game is waiting on them.
--
-- This is Stage 1 of the notifications work (see CHANGELOG 0.5.1).
-- Scope:
--   * Dedup by (playerID, notificationID) — the engine rebroadcasts
--     undismissed notifications on load and on turn-end blockers, and
--     the bare event handler that lived in ScreenReaderEventHandlers
--     would re-speak them every time.
--   * 200ms debounce — bursts (war declared by N civs, multi-city
--     famine events) collapse into one drain pass so subsequent
--     speeches don't truncate each other.
--   * 500ms turn-start hold — engine fires a popup storm around
--     LocalPlayerTurnBegin (research choice, civic choice, advisor
--     prompts). Hold the notification batch so those popups speak
--     first; otherwise the notification line cuts them mid-word.
--   * Arrival earcon — engine sound paired with the spoken line.
--     Placeholder uses NOTIFICATION_MISC_POSITIVE, an engine sound
--     key from NotificationPanel.lua's AddSound table. Will be
--     replaced with a custom ElevenLabs earcon when those land
--     (see [[project-elevenlabs-earcons]]).
--
-- Out of scope for Stage 1 (planned for Stage 2):
--   * Notifications center / review buffer (port of Civ V Access's
--     MessageBuffer pattern).
--   * Periodic idle reminder ("there are things you need to do").
--   * Read/unread state tracking.
--   * Activation (Enter to read full / Space to trigger natural action).
--   * Toggle UI.
--
-- Tick pump: drain coalesces onto Events.GameCoreEventPublishComplete
-- (fires per Lua frame in the in-game context — confirmed via Civ VI
-- engine source: CivicsChooser/ResearchChooser/MinimapPanel/WorldTracker
-- all subscribe). When we have pending notifications and the debounce
-- + turn-start-hold gates open, the next PublishComplete drains them.
--
-- Hotseat / multiplayer: dedup keys are per-player so an active-player
-- swap doesn't false-suppress the new player's notifications. We do
-- not yet handle the engine's load-time rebroadcast wave for non-local
-- players; single-player only-currently. Add a LocalPlayerChanged
-- handler when hotseat support lands.

include("ScreenReader");
include("Log");

Log.info("Notifications.lua: file loaded");

local DEBOUNCE_SECONDS         = 0.2;
local TURN_START_HOLD_SECONDS  = 0.5;
local ARRIVAL_SOUND_KEY        = "NOTIFICATION_MISC_POSITIVE";

local _seenIds         = {};   -- _seenIds[playerID][notificationID] = true
local _pending         = {};   -- queue of { playerID, notificationID, summary, typeName }
local _batchStartAt    = 0;
local _holdUntil       = 0;
local _drainScheduled  = false;

local function timeNow()
    if os ~= nil and os.clock ~= nil then
        local ok, v = pcall(os.clock);
        if ok and v ~= nil then return v; end
    end
    return 0;
end

local function markSeen(playerID, notificationID)
    if _seenIds[playerID] == nil then _seenIds[playerID] = {}; end
    if _seenIds[playerID][notificationID] then return false; end
    _seenIds[playerID][notificationID] = true;
    return true;
end

local function playArrivalEarcon()
    if UI ~= nil and UI.PlaySound ~= nil then
        pcall(UI.PlaySound, ARRIVAL_SOUND_KEY);
    end
end

local function drain()
    _drainScheduled = false;
    if #_pending == 0 then return; end
    local now = timeNow();
    if now - _batchStartAt < DEBOUNCE_SECONDS or now < _holdUntil then
        -- Still cooling. Re-arm so the next PublishComplete reattempts.
        _drainScheduled = true;
        return;
    end
    local queue = _pending;
    _pending = {};
    for _, e in ipairs(queue) do
        playArrivalEarcon();
        OutputMessageToScreenReader("Notification. " .. e.summary, true);
    end
end

local function onNotificationAdded(playerID, notificationID)
    if Game == nil or playerID ~= Game.GetLocalPlayer() then return; end
    if NotificationManager == nil or NotificationManager.Find == nil then return; end
    if not markSeen(playerID, notificationID) then return; end

    local ok, notification = pcall(NotificationManager.Find, playerID, notificationID);
    if not ok or notification == nil then return; end

    local typeName = "?";
    local okType, t = pcall(function() return notification:GetTypeName(); end);
    if okType and t ~= nil then typeName = tostring(t); end

    local summary = "";
    local okSum, s = pcall(function() return notification:GetSummary(); end);
    if okSum and s ~= nil and s ~= "" then summary = Locale.Lookup(s); end
    if summary == "" then
        local okMsg, m = pcall(function() return notification:GetMessage(); end);
        if okMsg and m ~= nil and m ~= "" then summary = Locale.Lookup(m); end
    end

    Log.info("NotificationAdded type=" .. typeName
             .. " id=" .. tostring(notificationID)
             .. " summary=" .. (summary ~= "" and summary or "(none)"));

    if summary == "" then return; end

    _pending[#_pending + 1] = {
        playerID = playerID,
        notificationID = notificationID,
        summary = summary,
        typeName = typeName,
    };
    _batchStartAt = timeNow();
    _drainScheduled = true;
end

local function onPublishComplete()
    if _drainScheduled then drain(); end
end

local function onLocalPlayerTurnBegin()
    _holdUntil = timeNow() + TURN_START_HOLD_SECONDS;
end

local function Initialize()
    if Events == nil then
        Log.error("Notifications: Events table not available");
        return;
    end
    if Events.NotificationAdded ~= nil then
        Events.NotificationAdded.Add(onNotificationAdded);
    else
        Log.warn("Notifications: Events.NotificationAdded not available");
    end
    if Events.GameCoreEventPublishComplete ~= nil then
        Events.GameCoreEventPublishComplete.Add(onPublishComplete);
    else
        Log.warn("Notifications: Events.GameCoreEventPublishComplete not available — drain will not fire");
    end
    if Events.LocalPlayerTurnBegin ~= nil then
        Events.LocalPlayerTurnBegin.Add(onLocalPlayerTurnBegin);
    end
    Log.info("Notifications: subscriptions complete");
end

Initialize();
