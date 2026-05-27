-- Context-sensitive screen-reader help.
--
-- Each per-screen companion (OptionsAccess, MainMenuAccess, LoadGameMenuAccess,
-- and future ones) wires its F1 key to ContextHelp.Speak("<SCREEN_KEY>"). This
-- centralizes:
--   * one routing point for help speech (interrupt level, output channel)
--   * one location per screen for help text — easy to review, edit, and grep
--   * a clean future migration path to Civ VI's LOC_* localization tables
--     ([[localization-approach]]); call sites stay unchanged
--
-- For now the help text lives in this file as a Lua table. When the
-- accessibility-strings localization pipeline is set up (Crowdin / AI
-- translation for net-new strings), each entry becomes a LOC_CIVVIACCESS_HELP_*
-- key resolved via Locale.Lookup, with the table-form as fallback.

include("ScreenReader");

ContextHelp = {};

-- stripIconTags is a global from ScreenReader.lua. OutputMessageToScreenReader
-- auto-strips on the way out, but we strip earlier here too because the
-- composed help body can be long and we want the cleaned form in our
-- internal HELP_TEXTS / Locale.Lookup comparisons.

-- ===========================================================================
--  Help text by screen identifier
-- ===========================================================================
-- Convention: keys are SCREAMING_SNAKE_CASE matching the screen's role
-- (OPTIONS, MAIN_MENU, LOAD_GAME, ADVANCED_SETUP, etc.). When adding a new
-- screen's companion, add its help string here and wire its F1 to
-- ContextHelp.Speak("<KEY>").

local HELP_TEXTS = {

    OPTIONS =
        "Options keyboard help. " ..
        "Use this dialog to adjust various options related to Civilization VI's gameplay. " ..
        "Press Page Down or Tab to move to the next tab. " ..
        "Press Page Up to move to the previous tab. " ..
        "Use the Up and Down arrow keys to move between items in the current tab. " ..
        "Press Home or End to jump to the first or last item. " ..
        "Press the Left or Right arrow key to adjust sliders by 5 percent or to cycle through pulldown options. " ..
        "Hold the Control key and press Left or Right to adjust sliders by 20 percent. " ..
        "Press Enter or Space to activate buttons and toggle checkboxes. " ..
        "Press Escape to close Options without saving.",

};

-- ===========================================================================
--  API
-- ===========================================================================
-- Resolve a help key to its localized text. Lookup order:
--   1. Civ VI's localization table (LOC_CIVVIACCESS_HELP_<KEY>). Picks
--      automatically based on game language — translators just drop a
--      new XML into Assets/Text/<lang>/ and add it to the modinfo's
--      <UpdateDatabase> entries.
--   2. In-Lua HELP_TEXTS fallback. Used when a key hasn't been translated
--      yet (or for development before the XML is wired up).
-- Returns "" if neither resolves.
local function resolveHelp(key)
    if key == nil then return ""; end
    local locKey = "LOC_CIVVIACCESS_HELP_" .. tostring(key);
    if Locale ~= nil and Locale.Lookup ~= nil then
        local ok, v = pcall(Locale.Lookup, locKey);
        -- Locale.Lookup returns the key verbatim when no entry exists, so
        -- treat "result equals input" as "not found" and fall through.
        if ok and type(v) == "string" and v ~= "" and v ~= locKey then
            return v;
        end
    end
    local fallback = HELP_TEXTS[key];
    if fallback ~= nil then return fallback; end
    return "";
end

-- Speak the help for a screen key. Silent no-op if the key isn't registered
-- yet (so calling Speak from a new screen before its text is added doesn't
-- crash — just nothing happens).
function ContextHelp.Speak(key)
    local text = resolveHelp(key);
    if text == "" then return; end
    text = stripIconTags(text);
    if Speech ~= nil and Speech.emit ~= nil then
        Speech.emit(text, "status");
    end
end

-- Optional: query whether a help key is registered. Useful if a screen
-- wants to conditionally announce "Press F1 for help" only when help exists.
function ContextHelp.HasHelp(key)
    return resolveHelp(key) ~= "";
end
