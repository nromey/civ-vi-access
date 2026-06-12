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
--
-- ALL shared state lives on Notifications._state (a table attached to
-- the shared Notifications global). The `or` preserves state across
-- repeated chunk loads — see the double-init note in Initialize().
-- Chunk-local `local S = Notifications._state` is just a shorthand
-- pointer to the SAME table; mutations through S.foo affect the
-- shared store.
--
-- _state layout:
--   seenIds[playerID][notificationID] = true    -- dedup
--   pending = { ... }                           -- arrival speech queue
--   batchStartAt, holdUntil, drainScheduled     -- timing for drain
--   cache[playerID] = { order = {ids...}, entries = {[id]=entry} }
--     entry = { id, playerID, summary, typeName, addedAt, read,
--               blocker, dismissable }
--   navIndex                                    -- cycle position
--   reminderEnabled, lastUserActivity,
--   lastReminderAt, currentBackoffSeconds       -- idle reminder

Notifications._state = Notifications._state or {
    seenIds              = {},
    pending              = {},
    batchStartAt         = 0,
    holdUntil            = 0,
    drainScheduled       = false,
    cache                = {},
    navIndex             = 0,
    reminderEnabled      = true,
    lastUserActivity     = 0,
    lastReminderAt       = 0,
    currentBackoffSeconds = IDLE_THRESHOLD_INITIAL,
    -- textKeys[playerID]["typeName::summary"] = canonical notification ID.
    -- Engine fires fresh IDs for the same logical reminder ("Move a
    -- unit..." each turn) — without text-keyed dedup, cache fills with
    -- N duplicate entries and speech fires N times. We keep the FIRST
    -- ID's entry in cache; subsequent same-text arrivals refresh its
    -- timestamp but don't add new entries or trigger new speech.
    -- Confirmed via Lua.log 2026-05-25: six NOTIFICATION_COMMAND_UNITS
    -- arrivals with IDs 0/1/2/5/7/8 all summary="Move a unit...".
    textKeys             = {},
};
local S = Notifications._state;

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
    if S.seenIds[playerID] == nil then S.seenIds[playerID] = {}; end
    if S.seenIds[playerID][notificationID] then return false; end
    S.seenIds[playerID][notificationID] = true;
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
    S.lastUserActivity = timeNow();
    -- Engagement signal: shrink backoff back to the initial threshold so
    -- a notification arriving five minutes from now starts the reminder
    -- clock from 20s, not 300s.
    S.currentBackoffSeconds = IDLE_THRESHOLD_INITIAL;
end

-- =======================================================================
-- Cache operations
-- =======================================================================

local function ensureCacheFor(playerID)
    if S.cache[playerID] == nil then
        S.cache[playerID] = { order = {}, entries = {} };
    end
    return S.cache[playerID];
end

local function cacheAdd(playerID, entry)
    local bucket = ensureCacheFor(playerID);
    if bucket.entries[entry.id] ~= nil then return; end
    bucket.entries[entry.id] = entry;
    table.insert(bucket.order, entry.id);
    S.navIndex = 0;
end

local function cacheRemove(playerID, notificationID)
    local bucket = S.cache[playerID];
    if bucket == nil or bucket.entries[notificationID] == nil then return; end
    local entry = bucket.entries[notificationID];
    bucket.entries[notificationID] = nil;
    for i, id in ipairs(bucket.order) do
        if id == notificationID then
            table.remove(bucket.order, i);
            break;
        end
    end
    -- Free the text-key claim if this entry was the canonical for
    -- its (typeName, summary). A future same-text arrival can then
    -- establish a new canonical instead of getting silently absorbed.
    if entry ~= nil and S.textKeys[playerID] ~= nil then
        local textKey = entry.typeName .. "::" .. entry.summary;
        if S.textKeys[playerID][textKey] == notificationID then
            S.textKeys[playerID][textKey] = nil;
        end
    end
    S.navIndex = 0;
end

local function cacheMarkRead(playerID, notificationID)
    local bucket = S.cache[playerID];
    if bucket == nil or bucket.entries[notificationID] == nil then return; end
    bucket.entries[notificationID].read = true;
end

-- Build the sorted "what to walk" list: pending entries (unread by
-- default; pass includeRead=true to walk everything), sorted by
-- (blocker desc, dismissable asc, addedAt asc).
local function sortedListFor(playerID, includeRead)
    local list = {};
    local bucket = S.cache[playerID];
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

-- Synthesize a virtual entry from the engine's active end-turn
-- blocker when our cache is empty but the turn still can't end.
-- Closes the misalignment we hit 2026-05-27: engine dismissed our
-- cached COMMAND_UNITS entry briefly (Warrior went out-of-moves),
-- our cycle then said "no notifications" while the engine's blocker
-- was still active because the Settler hadn't acted. Cycle and
-- pendingCount both call this when cache is empty.
local function synthesizeFromEngineBlocker(pid)
    if NotificationManager == nil then return nil; end
    if NotificationManager.GetFirstEndTurnBlocking == nil then return nil; end
    local okId, blockerId = pcall(NotificationManager.GetFirstEndTurnBlocking, pid);
    -- blockerId == 0 means "no blocker" per the engine (NOT a valid
    -- notification ID for our purposes); blockerId < 0 is the
    -- explicit-nothing sentinel. Either way, skip the Find call.
    if not okId or blockerId == nil or blockerId <= 0 then return nil; end
    if NotificationManager.Find == nil then return nil; end
    local okN, notif = pcall(NotificationManager.Find, pid, blockerId);
    if not okN or notif == nil then return nil; end
    local summary = "";
    local okS, s = pcall(function() return notif:GetSummary(); end);
    if okS and s ~= nil and s ~= "" then summary = Locale.Lookup(s); end
    if summary == "" then return nil; end
    return {
        id          = blockerId,
        playerID    = pid,
        summary     = summary,
        typeName    = "ENGINE_BLOCKER",
        addedAt     = timeNow(),
        read        = false,
        blocker     = true,
        dismissable = false,
        synthesized = true,
    };
end

-- Public: pending count for a player. Counts ALL cached entries
-- (read + unread) — read means "user has heard this once," not
-- "resolved." Pending = "still needs action." If our cache is empty
-- but the engine still has an end-turn blocker active (the engine-
-- vs-cache desync case from 2026-05-27), count that as 1.
function Notifications.pendingCount(playerID)
    if playerID == nil or playerID < 0 then return 0; end
    local n = #sortedListFor(playerID, true);
    if n == 0 then
        local synth = synthesizeFromEngineBlocker(playerID);
        if synth ~= nil then return 1; end
    end
    return n;
end

-- =======================================================================
-- Layer 1 — inline announce
-- =======================================================================

local function drain()
    S.drainScheduled = false;
    if #S.pending == 0 then return; end
    local now = timeNow();
    if now - S.batchStartAt < DEBOUNCE_SECONDS or now < S.holdUntil then
        -- Still cooling. Re-arm so the next PublishComplete reattempts.
        S.drainScheduled = true;
        return;
    end
    local queue = S.pending;
    S.pending = {};
    for _, e in ipairs(queue) do
        playArrivalEarcon();
        Speech.emit("Notification. " .. e.summary, "meta");
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

    -- Text-key dedup. Engine fires fresh IDs for the same logical
    -- reminder (NOTIFICATION_COMMAND_UNITS every turn, etc.). When the
    -- same (typeName, summary) fires under a new ID, MIGRATE the
    -- existing cache entry to the new ID rather than just refreshing
    -- the timestamp. Original behavior was "refresh and return": the
    -- old canonical kept the cache slot, then engine eventually fired
    -- NotificationDismissed for the OLD id (since it was the one
    -- that "expired"), which cleared our cache while the NEW id was
    -- still alive engine-side. Cycle then said "no notifications"
    -- with a live blocker still gating turn-end. Confirmed via Lua.log
    -- 2026-05-27: id=0 added → id=1 added (same text, dedup ate it) →
    -- id=0 dismissed → cache empty → engine's id=1 still active.
    --
    -- Migration semantics: move entry to new ID, keep read state
    -- (user has already heard this text), suppress arrival re-speak.
    local textKey = typeName .. "::" .. summary;
    if S.textKeys[playerID] == nil then S.textKeys[playerID] = {}; end
    local canonicalID = S.textKeys[playerID][textKey];
    if canonicalID ~= nil
       and S.cache[playerID] ~= nil
       and S.cache[playerID].entries[canonicalID] ~= nil
       and canonicalID ~= notificationID then
        local bucket = S.cache[playerID];
        local entry = bucket.entries[canonicalID];
        bucket.entries[canonicalID] = nil;
        entry.id = notificationID;
        entry.addedAt = timeNow();
        bucket.entries[notificationID] = entry;
        for i, id in ipairs(bucket.order) do
            if id == canonicalID then
                bucket.order[i] = notificationID;
                break;
            end
        end
        S.textKeys[playerID][textKey] = notificationID;
        Log.info("Notifications: migrated dedup entry "
                 .. tostring(canonicalID) .. " -> " .. tostring(notificationID)
                 .. " textKey=" .. textKey);
        return;
    end
    S.textKeys[playerID][textKey] = notificationID;

    -- Layer 1: queue for inline speech.
    S.pending[#S.pending + 1] = {
        playerID = playerID,
        notificationID = notificationID,
        summary = summary,
        typeName = typeName,
    };
    S.batchStartAt = timeNow();
    S.drainScheduled = true;

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
    S.currentBackoffSeconds = IDLE_THRESHOLD_INITIAL;
end

-- =======================================================================
-- Layer 2 — center: cycle, idle reminder, toggles
-- =======================================================================

-- Speak a cache entry with index + total + blocker + read/unread tag.
-- Marks the entry read as a side effect (cycling counts as "heard").
-- In chatty mode (Verbosity.isOn()) the cycle line appends a
-- read/unread tag so the user can tell which entries are fresh vs.
-- already-heard at a glance — the "task list" model Noel sketched
-- 2026-05-27.
local function speakEntry(entry, idx, total)
    local parts = { "Notification " .. tostring(idx) .. " of " .. tostring(total) };
    if entry.blocker then table.insert(parts, "blocker"); end
    local chatty = Verbosity ~= nil and Verbosity.isOn and Verbosity.isOn();
    if chatty then
        table.insert(parts, entry.read and "read" or "unread");
    end
    Speech.emit(table.concat(parts, ", ") .. ". " .. entry.summary, "selection");
    entry.read = true;
end

-- Walk forward through notifications. Always includes both read AND
-- unread — read just means "you've heard this once," not "hide from
-- the list" (that was the buried-state bug). Falls back to a
-- synthesized engine-blocker entry when the cache is empty but the
-- turn still can't end.
local function pickCycleList(pid)
    local list = sortedListFor(pid, true);  -- include read AND unread
    if #list == 0 then
        local synth = synthesizeFromEngineBlocker(pid);
        if synth ~= nil then
            list = { synth };
        end
    end
    return list;
end

function Notifications.cycleNext()
    recordUserActivity();
    local pid = localPlayerID();
    local list = pickCycleList(pid);
    if #list == 0 then
        Speech.emit("No notifications", "meta");
        return;
    end
    if S.navIndex < 1 or S.navIndex > #list then
        S.navIndex = 1;
    else
        S.navIndex = (S.navIndex % #list) + 1;
    end
    speakEntry(list[S.navIndex], S.navIndex, #list);
end

function Notifications.cyclePrev()
    recordUserActivity();
    local pid = localPlayerID();
    local list = pickCycleList(pid);
    if #list == 0 then
        Speech.emit("No notifications", "meta");
        return;
    end
    if S.navIndex < 1 or S.navIndex > #list then
        S.navIndex = #list;
    else
        S.navIndex = S.navIndex - 1;
        if S.navIndex < 1 then S.navIndex = #list; end
    end
    speakEntry(list[S.navIndex], S.navIndex, #list);
end

-- Activate the cycle's current notification — the keyboard form of the
-- sighted LEFT-CLICK on a notification icon (Noel 2026-06-12: the engine's
-- bare-Enter blocker activation never opened our policy flow). This is
-- exactly what the vanilla panel's TryActivate does: NotificationManager.Find
-- + pNotification:Activate(true). The engine then fires
-- Events.NotificationActivated; the real NotificationPanel dispatches its
-- per-type handler (FILL_CIVIC_SLOT -> open policies, CHOOSE_TECH -> tech
-- chooser, ...) and our screen wrappers intercept from there.
function Notifications.activateCurrent()
    recordUserActivity();
    local pid = localPlayerID();
    local list = pickCycleList(pid);
    if #list == 0 then
        Speech.emit("No notifications", "meta");
        return;
    end
    if S.navIndex < 1 or S.navIndex > #list then S.navIndex = 1; end
    local entry = list[S.navIndex];
    if entry == nil or entry.id == nil then
        Speech.emit("Nothing to activate", "meta");
        return;
    end
    local pNotification = nil;
    pcall(function()
        if NotificationManager ~= nil and NotificationManager.Find ~= nil then
            pNotification = NotificationManager.Find(pid, entry.id);
        end
    end);
    if pNotification == nil then
        Speech.emit("Can't activate this notification", "meta");
        return;
    end
    Log.info("Notifications.activateCurrent: id=" .. tostring(entry.id)
             .. " type=" .. tostring(entry.typeName));
    Speech.emit("Activating. " .. (entry.summary or ""), "event");
    pcall(function() pNotification:Activate(true); end);
end

-- Shift+Enter, forwarded from the capture-all wrap (mods bit0 = Shift).
local KEY_RETURN = Keys and Keys.VK_RETURN;
function Notifications.dispatch(key, mods)
    mods = mods or 0;
    if KEY_RETURN ~= nil and key == KEY_RETURN and mods == 1 then
        Notifications.activateCurrent();
        return true;
    end
    return false;
end

function Notifications.toggleReminder()
    recordUserActivity();
    S.reminderEnabled = not S.reminderEnabled;
    if S.reminderEnabled then
        Speech.emit("Notification reminders on", "event");
    else
        Speech.emit("Notification reminders off", "event");
    end
end

-- Periodic idle reminder. Fires when:
--   * reminder is enabled, AND
--   * there are pending notifications (read OR unread — read means
--     "heard once," not "resolved"), AND
--   * time since last user activity exceeds the current backoff window.
-- After firing, backoff doubles (capped) so the user isn't yelled at if
-- they're deliberately ignoring. User activity (any hotkey, any
-- notification cycle) resets the backoff window to the initial value.
local function maybeFireReminder()
    if not S.reminderEnabled then return; end
    local pid = localPlayerID();
    if pid < 0 then return; end
    local count = Notifications.pendingCount(pid);
    if count == 0 then return; end
    local now = timeNow();
    if now - S.lastUserActivity < S.currentBackoffSeconds then return; end
    if now - S.lastReminderAt < S.currentBackoffSeconds then return; end

    -- Update state BEFORE the emit. If Speech.emit's print() triggers
    -- the engine to publish another event (loops back through
    -- onPublishComplete → maybeFireReminder), the reentrant call sees
    -- the freshly-stamped lastReminderAt and bails on the backoff
    -- check. Confirmed via Lua.log 2026-05-26: "1 thing to do" emitted
    -- twice back-to-back; reentrancy is the only consistent
    -- explanation given the within-VM same-table state.
    S.lastReminderAt = now;
    S.currentBackoffSeconds = math.min(S.currentBackoffSeconds * 2, IDLE_THRESHOLD_MAX);

    playReminderEarcon();
    local text = (count == 1) and "1 thing to do"
                              or (tostring(count) .. " things to do");
    Speech.emit(text, "meta");
end

-- =======================================================================
-- Engine event wiring
-- =======================================================================

local function onNotificationDismissed(playerID, notificationID)
    Log.info("NotificationDismissed: pid=" .. tostring(playerID)
             .. " id=" .. tostring(notificationID));
    cacheRemove(playerID, notificationID);
end

local function onNotificationActivated(playerID, notificationID, _activatedByUser)
    cacheMarkRead(playerID, notificationID);
end

local function onPublishComplete()
    if S.drainScheduled then drain(); end
    maybeFireReminder();
end

local function onLocalPlayerTurnBegin()
    S.holdUntil = timeNow() + TURN_START_HOLD_SECONDS;
    -- New turn = fresh task list. Reset backoff so the user hears about
    -- existing blockers within the standard window after turn-start
    -- speech finishes.
    S.currentBackoffSeconds = IDLE_THRESHOLD_INITIAL;
end

-- Treat any hotkey press as activity. Cheap to track and reliable —
-- engine input event fires before our handlers run.
local function onInputActionTriggered(_actionID)
    S.lastUserActivity = timeNow();
end

-- Guard against double-init. Civ VI's load model runs this file from
-- both AddGameplayScripts AND via include() from the addin. The guard
-- MUST live on the Notifications table (shared global namespace) and
-- NOT as a file-local, because each load gets its own chunk-local
-- scope — a `local _initialized` would be false in both loads, both
-- Initialize() calls would proceed, both would register handlers, and
-- every notification would speak twice + the reminder would count
-- duplicates. Bug shipped in initial 0.5.2 and surfaced on Noel test
-- 2026-05-25 ("repeated the founding, just literally read the two
-- notifications twice").
local function Initialize()
    if Notifications._initialized then return; end
    Notifications._initialized = true;
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
    S.lastUserActivity = timeNow();
    Log.info("Notifications: subscriptions complete");
end

Initialize();
