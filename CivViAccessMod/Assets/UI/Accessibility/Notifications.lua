-- Screen-reader announcement + notifications center for in-game engine
-- notifications.
--
-- Civ VI's notification system is how the game tells the player "you
-- need to make a decision" — choose research, choose civic, production
-- queue empty, war declared, wonder built. Most are end-turn blockers;
-- without speaking them, a blind player has no audible cue that the
-- game is waiting on them.
--
-- This file ships two layers:
--
-- LAYER 1 — Inline announce (Stage 1, 0.5.1). Speaks each new
-- notification once via Tolk, paired with an arrival earcon.
--   * Dedup by (playerID, notificationID) — the engine rebroadcasts
--     undismissed notifications on load and on turn-end blockers.
--   * 200ms debounce — bursts (war declared by N civs, multi-city
--     famine events) collapse into one drain pass.
--   * 500ms turn-start hold — engine fires a popup storm around
--     LocalPlayerTurnBegin (research/civic choice, advisor prompts);
--     the hold lets those popups speak first.
--   * Arrival earcon paired with the spoken line.
--
-- LAYER 2 — Notifications center (Stage 2, 0.5.2). The arrival speech
-- can get missed (interrupted by other speech, user away from keyboard,
-- arrival storm overload). The center is the "task list" persistence
-- layer:
--   * Cache mirrors the engine's pending-notification list. Updated
--     from NotificationAdded / NotificationDismissed events. Civ VI
--     has no global enumeration API; the cache IS our enumeration.
--   * Read/unread state per entry, with sort priority:
--       (a) end-turn blockers first (CanUserDismiss=false OR
--           GetEndTurnBlocking ~= NO_ENDTURN_BLOCKING)
--       (b) then non-dismissable
--       (c) then everything else, oldest first
--   * Ctrl+[ / Ctrl+] hotkeys walk prev/next pending. Each press speaks
--     the entry with index ("Notification 2 of 3, blocker: Choose
--     research") and marks it read.
--   * Idle reminder. After IDLE_THRESHOLD_INITIAL seconds of no user
--     input AND pending count > 0, plays a reminder earcon + speaks
--     "N things to do". Exponential backoff (20s → 40s → 80s, capped
--     at IDLE_THRESHOLD_MAX) so repeated reminders don't nag you to
--     death if you're deliberately ignoring.
--   * Alt+N toggles the reminder on/off, speaks new state. Earcon-only
--     vs chime+speech toggle deferred until the options screen exists.
--
-- Tick pump: drain coalesces onto Events.GameCoreEventPublishComplete
-- (fires per Lua frame in the in-game context — confirmed via Civ VI
-- engine source: CivicsChooser/ResearchChooser/MinimapPanel/WorldTracker
-- all subscribe). PublishComplete also drives the idle-reminder timer.
--
-- Hotseat / multiplayer: cache keys are per-player so an active-player
-- swap doesn't false-suppress the new player's notifications. We do
-- not yet handle the engine's load-time rebroadcast wave for non-local
-- players; single-player only-currently. Add a LocalPlayerChanged
-- handler when hotseat support lands.
--
-- Out of scope (planned for future):
--   * Filter cycle (Shift+[/]) — needs notification-type taxonomy.
--   * Activation hotkey (Space) that triggers the notification's
--     natural action (open tech tree, focus plot). Requires mapping
--     into NotificationPanel's g_notificationHandlers per type.
--   * Ctrl+Ctrl+[/] for oldest/newest jump — minor convenience.
--   * Earcon on/off toggle, chime-only vs chime+speech toggle —
--     belongs in the options screen, not a hotkey cluster.

include("ScreenReader");
include("Log");

Log.info("Notifications.lua: file loaded");

Notifications = Notifications or {};

-- =======================================================================
-- Layer 1 constants
-- =======================================================================

local DEBOUNCE_SECONDS         = 0.2;
local TURN_START_HOLD_SECONDS  = 0.5;
local ARRIVAL_SOUND_KEY        = "NOTIFICATION_MISC_POSITIVE";

-- =======================================================================
-- Layer 2 constants
-- =======================================================================

local IDLE_THRESHOLD_INITIAL   = 20;    -- seconds before first reminder
local IDLE_THRESHOLD_MAX       = 300;   -- backoff ceiling (5 min)
local REMINDER_SOUND_KEY       = "NOTIFICATION_MISC_NEUTRAL";

-- =======================================================================
-- State
-- =======================================================================

-- Layer 1: pending speech queue + dedup + timing.
local _seenIds         = {};   -- _seenIds[playerID][notificationID] = true
local _pending         = {};   -- queue of pending-speech entries
local _batchStartAt    = 0;
local _holdUntil       = 0;
local _drainScheduled  = false;

-- Layer 2: cache of currently-pending notifications, by player.
-- _cache[pid] = {
--     order = { notificationID, ... },                 -- insertion order
--     entries = {
--         [notificationID] = {
--             id              = notificationID,
--             playerID        = pid,
--             summary         = "...",
--             typeName        = "...",
--             addedAt         = timestamp,
--             read            = false,
--             blocker         = bool,    -- end-turn-blocking
--             dismissable     = bool,    -- CanUserDismiss
--         }
--     },
-- }
local _cache = {};

-- Cycle nav: index into the most-recently-snapshotted sorted-pending
-- list. Reset on dismiss / add / sort change so we don't dereference a
-- stale index.
local _navIndex = 0;

-- Idle-reminder state.
local _reminderEnabled        = true;
local _lastUserActivity       = 0;
local _lastReminderAt         = 0;
local _currentBackoffSeconds  = IDLE_THRESHOLD_INITIAL;

-- =======================================================================
-- Helpers
-- =======================================================================

local function timeNow()
    if os ~= nil and os.clock ~= nil then
        local ok, v = pcall(os.clock);
        if ok and v ~= nil then return v; end
    end
    return 0;
end

local function localPlayerID()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    if not ok or id == nil then return -1; end
    return id;
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

local function playReminderEarcon()
    if UI ~= nil and UI.PlaySound ~= nil then
        pcall(UI.PlaySound, REMINDER_SOUND_KEY);
    end
end

local function recordUserActivity()
    _lastUserActivity = timeNow();
    -- Engagement signal: shrink backoff back to the initial threshold so
    -- a notification arriving five minutes from now starts the reminder
    -- clock from 20s, not 300s.
    _currentBackoffSeconds = IDLE_THRESHOLD_INITIAL;
end

-- =======================================================================
-- Cache operations
-- =======================================================================

local function ensureCacheFor(playerID)
    if _cache[playerID] == nil then
        _cache[playerID] = { order = {}, entries = {} };
    end
    return _cache[playerID];
end

local function cacheAdd(playerID, entry)
    local bucket = ensureCacheFor(playerID);
    if bucket.entries[entry.id] ~= nil then return; end
    bucket.entries[entry.id] = entry;
    table.insert(bucket.order, entry.id);
    _navIndex = 0;
end

local function cacheRemove(playerID, notificationID)
    local bucket = _cache[playerID];
    if bucket == nil or bucket.entries[notificationID] == nil then return; end
    bucket.entries[notificationID] = nil;
    for i, id in ipairs(bucket.order) do
        if id == notificationID then
            table.remove(bucket.order, i);
            break;
        end
    end
    _navIndex = 0;
end

local function cacheMarkRead(playerID, notificationID)
    local bucket = _cache[playerID];
    if bucket == nil or bucket.entries[notificationID] == nil then return; end
    bucket.entries[notificationID].read = true;
end

-- Build the sorted "what to walk" list: pending entries (unread by
-- default; pass includeRead=true to walk everything), sorted by
-- (blocker desc, dismissable asc, addedAt asc).
local function sortedListFor(playerID, includeRead)
    local list = {};
    local bucket = _cache[playerID];
    if bucket == nil then return list; end
    for _, id in ipairs(bucket.order) do
        local entry = bucket.entries[id];
        if entry ~= nil and (includeRead or not entry.read) then
            table.insert(list, entry);
        end
    end
    table.sort(list, function(a, b)
        if a.blocker ~= b.blocker then return a.blocker; end
        if a.dismissable ~= b.dismissable then return not a.dismissable; end
        return a.addedAt < b.addedAt;
    end);
    return list;
end

-- =======================================================================
-- Layer 1 — inline announce
-- =======================================================================

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

    -- End-turn blocker classification. Both signals matter:
    -- GetEndTurnBlocking returns a flag enum; NO_ENDTURN_BLOCKING means
    -- it isn't actually halting the turn. CanUserDismiss=false signals
    -- "the user has to handle this, can't right-click it away."
    local blocker = false;
    local okEtb, etb = pcall(function() return notification:GetEndTurnBlocking(); end);
    if okEtb and etb ~= nil and EndTurnBlockingTypes ~= nil
       and etb ~= EndTurnBlockingTypes.NO_ENDTURN_BLOCKING then
        blocker = true;
    end

    local dismissable = true;
    local okDis, dis = pcall(function() return notification:CanUserDismiss(); end);
    if okDis and dis ~= nil then dismissable = dis; end

    Log.info("NotificationAdded type=" .. typeName
             .. " id=" .. tostring(notificationID)
             .. " blocker=" .. tostring(blocker)
             .. " dismissable=" .. tostring(dismissable)
             .. " summary=" .. (summary ~= "" and summary or "(none)"));

    if summary == "" then return; end

    -- Layer 1: queue for inline speech.
    _pending[#_pending + 1] = {
        playerID = playerID,
        notificationID = notificationID,
        summary = summary,
        typeName = typeName,
    };
    _batchStartAt = timeNow();
    _drainScheduled = true;

    -- Layer 2: cache for the center.
    cacheAdd(playerID, {
        id          = notificationID,
        playerID    = playerID,
        summary     = summary,
        typeName    = typeName,
        addedAt     = timeNow(),
        read        = false,
        blocker     = blocker,
        dismissable = dismissable,
    });

    -- A fresh notification resets the idle-reminder backoff: the moment
    -- a new task arrives, the user should hear about it 20s later if
    -- they're idle, not 300s later.
    _currentBackoffSeconds = IDLE_THRESHOLD_INITIAL;
end

-- =======================================================================
-- Layer 2 — center: cycle, idle reminder, toggles
-- =======================================================================

-- Speak a cache entry with index + total + blocker tag. Marks read.
local function speakEntry(entry, idx, total)
    local parts = { "Notification " .. tostring(idx) .. " of " .. tostring(total) };
    if entry.blocker then table.insert(parts, "blocker"); end
    OutputMessageToScreenReader(table.concat(parts, ", ") .. ". " .. entry.summary);
    entry.read = true;
end

-- Walk forward through pending notifications. First press from idle
-- snaps to the highest-priority entry (blocker first, oldest first
-- within tier). Subsequent presses advance; wraps at end.
function Notifications.cycleNext()
    recordUserActivity();
    local pid = localPlayerID();
    local list = sortedListFor(pid, false);  -- unread only
    if #list == 0 then
        -- Fall back to showing read entries — useful for re-checking
        -- "what did I just dismiss?" Otherwise the center feels empty
        -- the instant you finish your first walk.
        list = sortedListFor(pid, true);
        if #list == 0 then
            OutputMessageToScreenReader("No notifications");
            return;
        end
    end
    if _navIndex < 1 or _navIndex > #list then
        _navIndex = 1;
    else
        _navIndex = (_navIndex % #list) + 1;
    end
    speakEntry(list[_navIndex], _navIndex, #list);
end

function Notifications.cyclePrev()
    recordUserActivity();
    local pid = localPlayerID();
    local list = sortedListFor(pid, false);
    if #list == 0 then
        list = sortedListFor(pid, true);
        if #list == 0 then
            OutputMessageToScreenReader("No notifications");
            return;
        end
    end
    if _navIndex < 1 or _navIndex > #list then
        _navIndex = #list;
    else
        _navIndex = _navIndex - 1;
        if _navIndex < 1 then _navIndex = #list; end
    end
    speakEntry(list[_navIndex], _navIndex, #list);
end

function Notifications.toggleReminder()
    recordUserActivity();
    _reminderEnabled = not _reminderEnabled;
    if _reminderEnabled then
        OutputMessageToScreenReader("Notification reminders on");
    else
        OutputMessageToScreenReader("Notification reminders off");
    end
end

-- Periodic idle reminder. Fires when:
--   * reminder is enabled, AND
--   * there are unread pending notifications, AND
--   * time since last user activity exceeds the current backoff window.
-- After firing, backoff doubles (capped) so the user isn't yelled at if
-- they're deliberately ignoring. User activity (any hotkey, any
-- notification cycle) resets the backoff window to the initial value.
local function maybeFireReminder()
    if not _reminderEnabled then return; end
    local pid = localPlayerID();
    if pid < 0 then return; end
    local list = sortedListFor(pid, false);
    if #list == 0 then return; end
    local now = timeNow();
    if now - _lastUserActivity < _currentBackoffSeconds then return; end
    if now - _lastReminderAt < _currentBackoffSeconds then return; end

    playReminderEarcon();
    local count = #list;
    local text = (count == 1) and "1 thing to do"
                              or (tostring(count) .. " things to do");
    OutputMessageToScreenReader(text, true);
    _lastReminderAt = now;
    _currentBackoffSeconds = math.min(_currentBackoffSeconds * 2, IDLE_THRESHOLD_MAX);
end

-- =======================================================================
-- Engine event wiring
-- =======================================================================

local function onNotificationDismissed(playerID, notificationID)
    cacheRemove(playerID, notificationID);
end

local function onNotificationActivated(playerID, notificationID, _activatedByUser)
    cacheMarkRead(playerID, notificationID);
end

local function onPublishComplete()
    if _drainScheduled then drain(); end
    maybeFireReminder();
end

local function onLocalPlayerTurnBegin()
    _holdUntil = timeNow() + TURN_START_HOLD_SECONDS;
    -- New turn = fresh task list. Reset backoff so the user hears about
    -- existing blockers within the standard window after turn-start
    -- speech finishes.
    _currentBackoffSeconds = IDLE_THRESHOLD_INITIAL;
end

-- Treat any hotkey press as activity. Cheap to track and reliable —
-- engine input event fires before our handlers run.
local function onInputActionTriggered(_actionID)
    _lastUserActivity = timeNow();
end

-- Guard against double-init. Civ VI's load model can run this file
-- from both AddGameplayScripts AND via include() from an addin; without
-- the guard, Events.NotificationAdded would get the handler twice and
-- every notification would speak twice + the reminder would fire twice.
local _initialized = false;

local function Initialize()
    if _initialized then return; end
    _initialized = true;
    if Events == nil then
        Log.error("Notifications: Events table not available");
        return;
    end
    if Events.NotificationAdded ~= nil then
        Events.NotificationAdded.Add(onNotificationAdded);
    else
        Log.warn("Notifications: Events.NotificationAdded not available");
    end
    if Events.NotificationDismissed ~= nil then
        Events.NotificationDismissed.Add(onNotificationDismissed);
    end
    if Events.NotificationActivated ~= nil then
        Events.NotificationActivated.Add(onNotificationActivated);
    end
    if Events.GameCoreEventPublishComplete ~= nil then
        Events.GameCoreEventPublishComplete.Add(onPublishComplete);
    else
        Log.warn("Notifications: Events.GameCoreEventPublishComplete not available — drain + reminder will not fire");
    end
    if Events.LocalPlayerTurnBegin ~= nil then
        Events.LocalPlayerTurnBegin.Add(onLocalPlayerTurnBegin);
    end
    if Events.InputActionTriggered ~= nil then
        Events.InputActionTriggered.Add(onInputActionTriggered);
    end
    _lastUserActivity = timeNow();
    Log.info("Notifications: subscriptions complete");
end

Initialize();
