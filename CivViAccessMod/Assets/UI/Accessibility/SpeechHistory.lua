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

local function say(text)
    _suppress = true;
    pcall(function() Speech.emit(text, "selection"); end);
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
        say(_lastSpoken);
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
    say("Back " .. pos .. ". " .. _ring[pos]);
end

-- Shift+R, forwarded from the capture-all wrap (mods bit0 = Shift).
local KEY_R = Keys and Keys.R;
function SpeechHistory.dispatch(key, mods)
    if KEY_R ~= nil and key == KEY_R and (mods or 0) == 1 then
        SpeechHistory.repeatOrStep();
        return true;
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
