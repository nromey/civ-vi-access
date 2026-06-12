-- SpeechHistory.lua — the "say again" key grown into a history walk. Pager
-- arc deliverable 1 (Noel 2026-06-12, after three same-day speech losses:
-- Robert's diplomacy line, the reveal payload, notification detail — speech
-- that gets interrupted was simply GONE).
--
--   Shift+R once   -> repeat the LAST utterance verbatim, any kind — even a
--                     tile glance ("what did it just say?").
--   Shift+R again  -> walk BACK through the meaningful-announce ring, newest
--                     first: "Back 2. Uncovered 6 hexes: ..." ("what did I
--                     miss?"). nav/picker browse chatter is excluded from the
--                     ring so the walk surfaces events, not your own
--                     cursoring.
--   Any new announce resets the walk; at the oldest entry it says "End of
--   history" and stays.
--
-- Fed by the LuaEvents.CivViAccess_SpeechEmitted broadcast that Speech.emit
-- fires in EVERY VM (ScreenReader.lua — originally added for the one-deep
-- Shift+R), so announces from the reveal / diplomacy / picker VMs all land
-- here. The one-deep _lastSpoken collector in HexCursorAddin is superseded;
-- its InputAction handler now delegates here as a fallback (the wrap
-- normally consumes Shift+R first).
--
-- DEPTH is hardcoded until the accessibility options tab exists
-- (project_accessibility_settings_group) — then it becomes a setting.
-- The PAGER (deliverable 3) will render any history entry too long for one
-- utterance; until then entries re-speak whole.

include("Log");
include("ScreenReader");

SpeechHistory = SpeechHistory or {};

local DEPTH = 20;
local SKIP_IN_RING = { nav = true, picker = true };

local _ring = {};        -- [1] = newest meaningful utterance
local _lastSpoken = nil; -- literal last utterance, any kind
local _walkIndex = 0;    -- 0 = not walking; else ring position last spoken
local _suppress = false; -- true while re-speaking (don't record ourselves)

function SpeechHistory.onSpeechEmitted(text, kind)
    if _suppress then return; end
    if text == nil or text == "" then return; end
    _lastSpoken = text;
    _walkIndex = 0;                       -- fresh speech resets the walk
    if SKIP_IN_RING[kind] then return; end
    table.insert(_ring, 1, text);
    if #_ring > DEPTH then table.remove(_ring); end
end

-- Entries longer than this open in the PAGER (sentence-walk) instead of
-- re-speaking as one interruptible blob — Noel's "if it's long, it'd use the
-- pager" design (2026-06-12). Threshold becomes a setting with the
-- accessibility tab.
local PAGER_THRESHOLD = 240;

-- prefix: spoken position tag for short entries ("Back 2"). pagerTitle:
-- non-nil marks the text as pager-eligible (history content, not status
-- chatter like "End of history") and titles the reader when it opens.
local function say(text, prefix, pagerTitle)
    if pagerTitle ~= nil and #text > PAGER_THRESHOLD
       and LuaEvents ~= nil and LuaEvents.CivViAccess_OpenPager ~= nil then
        LuaEvents.CivViAccess_OpenPager(pagerTitle, text);
        return;
    end
    local spoken = (prefix ~= nil) and (prefix .. ". " .. text) or text;
    _suppress = true;
    pcall(function() Speech.emit(spoken, "selection"); end);
    _suppress = false;
end

function SpeechHistory.repeatOrStep()
    if _walkIndex == 0 then
        if _lastSpoken == nil or _lastSpoken == "" then
            say("Nothing to repeat");
            return;
        end
        -- First press: literal repeat. Marks the walk as started at "1" so
        -- the next press knows to step into the ring.
        _walkIndex = 1;
        say(_lastSpoken, nil, "Last announce");
        return;
    end
    -- Walking. From the literal repeat, step to the first ring entry that
    -- isn't the thing we just repeated; afterwards, one older per press.
    local pos;
    if _walkIndex == 1 then
        pos = (_ring[1] ~= nil and _ring[1] == _lastSpoken) and 2 or 1;
    else
        pos = _walkIndex + 1;
    end
    if _ring[pos] == nil then
        say("End of history");
        return;
    end
    _walkIndex = pos;
    say(_ring[pos], "Back " .. pos, "Back " .. pos);
end

-- Ctrl+R = step FORWARD (toward newest) while walking (Noel 2026-06-12:
-- "we can go back, but is there a way to go forward?"). Inverse of the
-- Shift+R back-step; at the top it says so and stays.
function SpeechHistory.stepForward()
    if _walkIndex == 0 then
        say("Not in history. Shift R walks back.");
        return;
    end
    local pos = _walkIndex - 1;
    if _walkIndex <= 1 or _ring[pos] == nil then
        say("At the newest");
        return;
    end
    _walkIndex = pos;
    say(_ring[pos], "Back " .. pos, "Back " .. pos);
end

-- Forwarded from the capture-all wrap: Shift+R back, Ctrl+R forward
-- (mods bit0 = Shift, bit1 = Ctrl).
local KEY_R = Keys and Keys.R;
function SpeechHistory.dispatch(key, mods)
    mods = mods or 0;
    if KEY_R ~= nil and key == KEY_R then
        if mods == 1 then SpeechHistory.repeatOrStep(); return true; end
        if mods == 2 then SpeechHistory.stepForward(); return true; end
    end
    return false;
end

local function Initialize()
    Log.info("SpeechHistory.lua: file loaded (Shift+R repeat + history walk, depth " .. DEPTH .. ")");
    if LuaEvents ~= nil and LuaEvents.CivViAccess_SpeechEmitted ~= nil then
        LuaEvents.CivViAccess_SpeechEmitted.Add(SpeechHistory.onSpeechEmitted);
        Log.info("SpeechHistory.Initialize: subscribed to CivViAccess_SpeechEmitted");
    else
        Log.warn("SpeechHistory.Initialize: CivViAccess_SpeechEmitted unavailable");
    end
end
Initialize();
