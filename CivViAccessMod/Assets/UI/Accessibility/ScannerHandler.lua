-- ScannerHandler.lua — maps a (key, mods) keypress to a ScannerNav entry point
-- and speaks the result. Mirrors Civ V Access's ScannerHandler modifier ladder:
--   PageDown / PageUp                = next / prev ITEM (the most-pressed axis)
--   Shift + PageDown/Up              = next / prev SUBCATEGORY
--   Ctrl  + PageDown/Up              = next / prev CATEGORY
--   Alt   + PageDown/Up              = next / prev INSTANCE
--   Home                             = jump cursor to the current entry
--   End                              = speak distance/direction to it
--   Backspace                        = return cursor to pre-jump cell
--
-- It receives keys FORWARDED from the WorldInput capture-all wrap (which owns raw
-- map input in its own VM) via LuaEvents.CivViAccess_ScannerInput, so this runs in
-- the HexCursorAddin VM next to the cursor and ScannerNav. Keys are matched with
-- the engine's Keys.* constants (NOT raw VK literals — Civ VI's Keys enum is its
-- own numbering, e.g. Keys.Y=25; the probe confirmed GetKey returns those values).

include("Log");
include("ScreenReader");
include("InputRouter");
include("HexGeom");   -- direction-vocabulary mode lives here (Shift+D cycles it)

ScannerHandler = ScannerHandler or {};

local MOD_NONE  = InputRouter.MOD_NONE;
local MOD_SHIFT = InputRouter.MOD_SHIFT;
local MOD_CTRL  = InputRouter.MOD_CTRL;
local MOD_ALT   = InputRouter.MOD_ALT;

local VK_NEXT  = (Keys ~= nil) and Keys.VK_NEXT  or nil;   -- PageDown
local VK_PRIOR = (Keys ~= nil) and Keys.VK_PRIOR or nil;   -- PageUp
local VK_HOME  = (Keys ~= nil) and Keys.VK_HOME  or nil;
local VK_END   = (Keys ~= nil) and Keys.VK_END   or nil;
local VK_BACK  = (Keys ~= nil) and Keys.VK_BACK  or nil;   -- Backspace
local VK_HELP  = (Keys ~= nil) and Keys.VK_OEM_2 or nil;   -- / and ? (the help key)
local VK_D     = (Keys ~= nil) and Keys.D        or nil;   -- Shift+D = cycle direction vocabulary

-- Spoken cheat-sheet (the `?` key), from the localized text file
-- (LOC_CIVVIACCESS_SCANNER_HELP in Assets/Text/en_US/CivVIAccessStrings.xml —
-- reword there). The map context has no HandlerStack `?` help, so the scanner
-- speaks its own ladder on demand. Re-readable any time.
local CHEAT_SHEET = Locale.Lookup("LOC_CIVVIACCESS_SCANNER_HELP");

-- The key set the WorldInput wrap must consume + forward. Exposed so the wrap and
-- this dispatcher share one definition of "scanner keys" (the wrap reads it by the
-- same Keys.* constants on its side). Lists the bare keys; the wrap forwards them
-- with whatever modifier is held and this dispatcher routes by (key, mods).
ScannerHandler.KEYS = { VK_NEXT, VK_PRIOR, VK_HOME, VK_END, VK_BACK, VK_HELP };

local function speak(text, kind)
    if text ~= nil and text ~= "" then
        Speech.emit(text, kind or "nav");
    end
end

-- Returns true if the (key, mods) was a scanner key we handled.
function ScannerHandler.dispatch(key, mods)
    if ScannerNav == nil then return false; end

    if key == VK_NEXT or key == VK_PRIOR then
        local dir = (key == VK_NEXT) and 1 or -1;
        if     mods == MOD_NONE  then speak(ScannerNav.cycleItem(dir));        return true;
        elseif mods == MOD_SHIFT then speak(ScannerNav.cycleSubcategory(dir)); return true;
        elseif mods == MOD_CTRL  then speak(ScannerNav.cycleCategory(dir));    return true;
        elseif mods == MOD_ALT   then speak(ScannerNav.cycleInstance(dir));    return true;
        end
        return false;
    elseif key == VK_HOME and mods == MOD_NONE then
        speak(ScannerNav.jumpToEntry());        return true;
    elseif key == VK_END and mods == MOD_NONE then
        speak(ScannerNav.distanceFromCursor()); return true;
    elseif key == VK_BACK and mods == MOD_NONE then
        speak(ScannerNav.returnToPreJump());    return true;
    elseif key == VK_HELP and mods == MOD_SHIFT then
        -- `?` (Shift+/) reads the ladder; bare/Ctrl+/ stay unit-stats/recenter.
        -- The cheat-sheet is a PAGE of text — it used to fire as ONE picker-kind
        -- utterance, which (a) the notification reminder clobbered and (b) the
        -- history ring excluded (picker = browse chatter), so it was
        -- unrecoverable (Noel 2026-06-12). Long help belongs in the PAGER:
        -- sentence-walkable, every part re-readable.
        if LuaEvents ~= nil and LuaEvents.CivViAccess_OpenPager ~= nil then
            LuaEvents.CivViAccess_OpenPager("Scanner help", CHEAT_SHEET);
        else
            speak(CHEAT_SHEET, "picker");
        end
        return true;
    end
    -- NOTE: direction-vocabulary cycle moved from Shift+D to Ctrl+D and now lives in
    -- NavKeys.dispatch (task #14 finalized the D-family: bare=cursor E, Shift=unit E,
    -- Ctrl=vocab). Shift+D here would never fire anyway — NavKeys claims it first.
    return false;
end

if VK_NEXT == nil or VK_PRIOR == nil then
    Log.warn("ScannerHandler: Keys.VK_NEXT/VK_PRIOR missing — PageUp/Down scanner cycle won't bind. Verify Civ VI Keys enum.");
end
Log.info("ScannerHandler.lua: loaded");
