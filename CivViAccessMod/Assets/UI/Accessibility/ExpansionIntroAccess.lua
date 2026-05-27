-- Expansion intro popup accessibility companion (R&F + GS slideshow).
--
-- Owns the screen-reader announce + keyboard input dispatch for the
-- "Welcome to Rise and Fall" / "Welcome to Gathering Storm" tutorial
-- slideshows. The Firaxis fork at Assets/UI/Additions/ExpansionIntro.lua
-- shadows BOTH engine ExpansionIntro.lua files (R&F + GS) as a single
-- file — relative path collision after Civ VI strips DLC prefixes
-- means we can only ship one — and detects active ruleset at show
-- time to pick the right per-expansion config.
--
-- The shadow includes this file and hands off:
--   Install(cfg)                  - register the per-ruleset config
--                                   (illustrations, descriptions LOC
--                                   tables, welcome text key)
--   NotifyShow()                  - popup just opened, page 1 shown
--   NotifyPageChange(pageIndex)   - Next/Previous moved the page
--   NotifyClose()                 - popup is dismissing
--   HandleKey(pInputStruct)       - returns true if we consumed input
--                                   (called before engine's OnInput)
--
-- Key bindings (active while the slideshow is visible):
--   Right / Down / N    next page (delegates to engine's OnNext)
--   Left / Up / P       previous page (delegates to engine's OnPrevious)
--   Enter / Space       activate Next button (advances or closes on
--                       last page)
--   Escape              close (engine already does this; we mirror)
--   T                   toggle "Don't show again" + announce new state
--   Ctrl+I              speak illustration description (placeholder
--                       until intro-diagrams describer batch lands)
--   Ctrl+T              re-speak current page description + details
--
-- See docs/flow-trace/05-expansion-intro-popup.md for the design.

include("ScreenReader");
include("Log");

ExpansionIntroAccess = {};

-- ===========================================================================
--  Constants
-- ===========================================================================
local KEY_UP_MSG   :number = (KeyEvents ~= nil and KeyEvents.KeyUp)   or 257;
local KEY_DOWN_MSG :number = (KeyEvents ~= nil and KeyEvents.KeyDown) or 256;

local function vk(name, fallback)
    if Keys ~= nil and Keys[name] ~= nil then
        return Keys[name];
    end
    return fallback;
end

local VK_RETURN  :number = vk("VK_RETURN", 0x0D);
local VK_ESCAPE  :number = vk("VK_ESCAPE", 0x1B);
local VK_SPACE   :number = vk("VK_SPACE",  0x20);
local VK_LEFT    :number = vk("VK_LEFT",   0x25);
local VK_UP      :number = vk("VK_UP",     0x26);
local VK_RIGHT   :number = vk("VK_RIGHT",  0x27);
local VK_DOWN    :number = vk("VK_DOWN",   0x28);
local VK_CONTROL :number = vk("VK_CONTROL",0x11);
local VK_I       :number = vk("VK_I",      0x49);
local VK_N       :number = vk("VK_N",      0x4E);
local VK_P       :number = vk("VK_P",      0x50);
local VK_T       :number = vk("VK_T",      0x54);

-- ===========================================================================
--  State
-- ===========================================================================
local m_cfg          :table   = nil;   -- per-ruleset config registered via Install
local m_visible      :boolean = false;
local m_ctrlDown     :boolean = false;
local m_pageIndex    :number  = 1;

-- ===========================================================================
--  Speech helpers
-- ===========================================================================
local function safeLookup(key)
    if key == nil or key == "" then return ""; end
    local ok, value = pcall(Locale.Lookup, key);
    if not ok or value == nil then return ""; end
    return stripIconTags(value);
end

-- Expansion intro speech: nointerrupt=true → status (page detail
-- continuation), false/nil → selection (page landing).
local function speak(text, nointerrupt)
    if text == nil or text == "" then return; end
    Speech.emit(text, nointerrupt and "status" or "selection");
end

local function descriptionForPage(idx)
    if m_cfg == nil or m_cfg.descriptions == nil then return ""; end
    return safeLookup(m_cfg.descriptions[idx]);
end

local function detailsForPage(idx)
    if m_cfg == nil or m_cfg.details == nil then return ""; end
    return safeLookup(m_cfg.details[idx]);
end

local function pageCount()
    if m_cfg == nil or m_cfg.descriptions == nil then return 0; end
    return #m_cfg.descriptions;
end

-- "Don't show again" state lives in the engine user options; read it
-- directly so toggle-T mirrors the engine checkbox state without
-- depending on whether we've focused the checkbox.
local function dontShowAgainEnabled()
    if m_cfg == nil or m_cfg.optionsHideKey == nil then return false; end
    if Options == nil or Options.GetUserOption == nil then return false; end
    local ok, v = pcall(Options.GetUserOption, "Tutorial", m_cfg.optionsHideKey);
    if not ok or v == nil then return false; end
    return v == 1;
end

local function setDontShowAgain(value)
    if m_cfg == nil or m_cfg.optionsHideKey == nil then return; end
    if Options == nil or Options.SetUserOption == nil then return; end
    pcall(Options.SetUserOption, "Tutorial", m_cfg.optionsHideKey, value and 1 or 0);
    if Options.SaveOptions ~= nil then
        pcall(Options.SaveOptions);
    end
    -- Also sync the UI checkbox so a sighted player sees the change
    -- when they look. The shadow exposes Controls.DontShowAgain
    -- globally; we touch it best-effort.
    if Controls ~= nil and Controls.DontShowAgain ~= nil
        and Controls.DontShowAgain.SetCheck ~= nil then
        pcall(function() Controls.DontShowAgain:SetCheck(value); end);
    end
end

-- ===========================================================================
--  Announce assembly
-- ===========================================================================
local function announcePage(pageIdx, includeWelcome, includeNavHint)
    if m_cfg == nil then return; end
    local n = pageCount();
    if n == 0 then return; end

    local parts = {};

    if includeWelcome and m_cfg.welcomeKey ~= nil then
        local welcome = safeLookup(m_cfg.welcomeKey);
        if welcome ~= "" then table.insert(parts, welcome); end
    end

    local pageHeader = Locale.Lookup(
        "LOC_CIVVIACCESS_EXPANSION_INTRO_PAGE_FORMAT",
        pageIdx, n);
    table.insert(parts, pageHeader);

    local desc = descriptionForPage(pageIdx);
    if desc ~= "" then table.insert(parts, desc); end

    local detail = detailsForPage(pageIdx);
    if detail ~= "" then table.insert(parts, detail); end

    -- Last page swaps "Next" → "Continue" in the engine button.
    if pageIdx == n then
        table.insert(parts,
            safeLookup("LOC_CIVVIACCESS_EXPANSION_INTRO_LAST_PAGE_HINT"));
    end

    if includeNavHint then
        table.insert(parts,
            safeLookup("LOC_CIVVIACCESS_EXPANSION_INTRO_NAV_HINT"));
    end

    speak(table.concat(parts, " "));
end

local function announceDontShowAgain()
    local on = dontShowAgainEnabled();
    local key = on and "LOC_CIVVIACCESS_DONT_SHOW_AGAIN_ON"
                   or "LOC_CIVVIACCESS_DONT_SHOW_AGAIN_OFF";
    speak(safeLookup(key));
end

-- ===========================================================================
--  Actions
-- ===========================================================================
-- These call back into the shadow's globals so the engine's Realize()
-- runs and updates the visual page. The shadow exports OnNext, OnPrevious,
-- OnClose, and m_PageIndex; we read m_PageIndex back after the engine
-- updates it (the shadow's Realize doesn't change page state itself).
local function pressNext()
    if OnNext ~= nil then
        pcall(OnNext);
    end
end

local function pressPrevious()
    if OnPrevious ~= nil then
        pcall(OnPrevious);
    end
end

local function pressClose()
    if OnClose ~= nil then
        pcall(OnClose);
    end
end

local function toggleDontShowAgain()
    setDontShowAgain(not dontShowAgainEnabled());
    announceDontShowAgain();
end

local function speakIllustrationDescription()
    -- Per-diagram description LOC keys land later via the describer
    -- batch over XP1Intro_Diagram_* / XP2Intro_Diagram_*. Until
    -- then, speak a clean placeholder so the binding works and
    -- users know the feature is wired.
    speak(safeLookup("LOC_CIVVIACCESS_EXPANSION_INTRO_ILLUSTRATION_PLACEHOLDER"));
end

local function rereadCurrentPage()
    announcePage(m_pageIndex, false, false);
end

-- ===========================================================================
--  Input dispatch (called from the shadow's OnInput)
-- ===========================================================================
function ExpansionIntroAccess.HandleKey(pInputStruct)
    if pInputStruct == nil or pInputStruct.GetMessageType == nil then
        return false;
    end
    local uiMsg = pInputStruct:GetMessageType();
    local wParam = pInputStruct:GetKey();

    -- Track Ctrl state.
    if wParam == VK_CONTROL then
        if uiMsg == KEY_DOWN_MSG then m_ctrlDown = true;
        elseif uiMsg == KEY_UP_MSG then m_ctrlDown = false; end
        return false;
    end

    if uiMsg ~= KEY_UP_MSG then return false; end
    if not m_visible then return false; end

    if m_ctrlDown and wParam == VK_I then
        speakIllustrationDescription();
        return true;
    end
    if m_ctrlDown and wParam == VK_T then
        rereadCurrentPage();
        return true;
    end

    -- Page navigation.
    if wParam == VK_RIGHT or wParam == VK_DOWN or wParam == VK_N then
        pressNext();
        return true;
    end
    if wParam == VK_LEFT or wParam == VK_UP or wParam == VK_P then
        pressPrevious();
        return true;
    end

    -- Enter / Space — advance via Next (which closes on last page).
    if wParam == VK_RETURN or wParam == VK_SPACE then
        pressNext();
        return true;
    end

    -- T — toggle "Don't show again". Bare key, no Ctrl. Safe because
    -- the slideshow has no text entry.
    if wParam == VK_T and not m_ctrlDown then
        toggleDontShowAgain();
        return true;
    end

    -- Escape — let the engine handle it; engine already wires Esc
    -- to close in OnInput. Return false to fall through.
    if wParam == VK_ESCAPE then
        return false;
    end

    return false;
end

-- ===========================================================================
--  Notifications from the shadowed ExpansionIntro.lua
-- ===========================================================================

-- Called by the shadow at OnLoadGameViewStateDone / OnShowFromMenu, BEFORE
-- the popup is queued. Selects the per-ruleset config to apply.
function ExpansionIntroAccess.Install(cfg)
    m_cfg = cfg;
    m_pageIndex = 1;
end

-- Called by the shadow at the END of OnShow / OnShowFromMenu, after the
-- engine's Realize() has rendered page 1.
function ExpansionIntroAccess.NotifyShow()
    m_visible   = true;
    m_ctrlDown  = false;
    m_pageIndex = 1;
    announcePage(1, true, true);
end

-- Called by the shadow at the END of OnNext / OnPrevious, after Realize.
function ExpansionIntroAccess.NotifyPageChange(pageIdx)
    m_pageIndex = pageIdx;
    announcePage(pageIdx, false, false);
end

-- Called by the shadow at OnClose.
function ExpansionIntroAccess.NotifyClose()
    m_visible  = false;
    m_ctrlDown = false;
    -- TODO: play "ready chime" earcon when audio playback path lands
    -- (per docs/flow-trace/05-expansion-intro-popup.md). Speech-only
    -- for now.
end

Log.info("ExpansionIntroAccess.lua: loaded");
