-- MainMenu accessibility companion.
--
-- Owns keyboard navigation + spoken focus tracking + the nav click cue for
-- the main menu screen. MainMenu.lua keeps doing what it already does
-- (mouse-driven UX, animation, network wiring, submenu construction); this
-- file installs a parallel kb-driven cursor on top of the controls
-- MainMenu builds in m_currentOptions / m_subMenuOptions.
--
-- Stays a separate file rather than living inline in MainMenu.lua so the
-- MainMenu fork is as small as feasible (just include + a few notify hook
-- calls). That keeps the diff against Firaxis tractable when the game
-- updates and lets the same companion pattern be lifted to other screens.
--
-- Key bindings (only fire while MainMenu is active and unhidden):
--   Up / Down          previous / next option (wraps at top/bottom level)
--   Home / End         first / last option
--   Enter / Space      activate focused option (calls its registered click
--                      callback, which is the same code path Mouse.eLClick
--                      runs)
--   Escape             when inside a submenu, walks back to main level;
--                      at the top level falls through to the engine
--
-- The mouse-enter announcement and the existing Main_Menu_Mouse_Over sound
-- effect remain wired in MainMenu.lua. This file uses the same sound for
-- kb nav so the cue is identical regardless of input device.

include("ScreenReader");

print("[CivViAccess][INFO ] MainMenuAccess.lua: file loading");

MainMenuAccess = {};

local NAV_SOUND       :string = "Main_Menu_Mouse_Over";
-- Civ VI FrontEnd convention is KeyUp (see FrontEndPopup.lua, LoadGameMenu.lua,
-- LeaderPicker.lua); KeyDown fires twice on Alt-modified chords and isn't
-- what the engine routes most non-game input through. Fall back to raw 257
-- (the engine's WM_KEYUP equivalent) if KeyEvents isn't in scope yet.
local KEY_UP_MSG      :number = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257;

local m_mainOptions   :table   = {};
local m_subOptions    :table   = {};
local m_mainIndex     :number  = 0;
local m_subIndex      :number  = 0;
local m_inSubMenu     :boolean = false;
local m_initialOpened :boolean = false;
-- One-shot suppression flag for the show-fires-right-after-build race.
-- MainMenu's BuildMenu and OnShow both run on initial load; we hook both
-- (BuildMenu to capture the option list, OnShow to re-announce on return
-- from submenus). On first load they fire back-to-back and would announce
-- twice. The build path sets this flag when it does the initial announce;
-- the very next show consumes it and stays silent.
local m_suppressNextShow :boolean = false;

-- ===========================================================================
--  Helpers
-- ===========================================================================
local function playNavSound()
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound(NAV_SOUND);
    end
end

-- stripIconTags is a global from ScreenReader.lua — it removes Civ VI's
-- inline [ICON_*] markers (button labels embed these for sighted players;
-- read literally they speak as "icon exclamation Multiplayer"). Speech via
-- OutputMessageToScreenReader auto-strips, but we also strip on the read
-- path here because labelForControl is used in conditionals (e.g. "if label
-- == '' then return") that need the cleaned form to compare correctly.

local function labelForControl(uiOption)
    if uiOption == nil or uiOption.ButtonLabel == nil then
        return "";
    end
    return stripIconTags(uiOption.ButtonLabel:GetText() or "");
end

local function isOptionUsable(entry)
    if entry == nil or entry.control == nil then
        return false;
    end
    local top = entry.control.Top;
    if top == nil then
        return true;
    end
    -- Skip controls hidden by buttonState (e.g. Resume / Scenarios when no
    -- saves, CivRoyale / Pirates promo, My2K when FiraxisLive disabled).
    if top.IsHidden ~= nil and top:IsHidden() then
        return false;
    end
    return true;
end

local function firstUsableIndex(options, startAt, step)
    local n = #options;
    if n == 0 then
        return 0;
    end
    local i = startAt;
    for _ = 1, n do
        if i < 1 then i = n; end
        if i > n then i = 1; end
        if isOptionUsable(options[i]) then
            return i;
        end
        i = i + step;
    end
    return 0;
end

local function speakIndex(options, idx, interrupt)
    local entry = options[idx];
    if entry == nil then
        return;
    end
    local label = labelForControl(entry.control);
    if label == "" then
        return;
    end
    OutputMessageToScreenReader(label, not interrupt);
end

local function announceMenuRoot()
    OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_MAIN_MENU_TITLE"));
    if m_mainIndex > 0 then
        speakIndex(m_mainOptions, m_mainIndex, false);
    end
end

-- ===========================================================================
--  Navigation primitives
-- ===========================================================================
local function activeOptions()
    if m_inSubMenu then
        return m_subOptions;
    end
    return m_mainOptions;
end

local function activeIndex()
    if m_inSubMenu then
        return m_subIndex;
    end
    return m_mainIndex;
end

local function setActiveIndex(idx)
    if m_inSubMenu then
        m_subIndex = idx;
    else
        m_mainIndex = idx;
    end
end

local function moveBy(step)
    local options = activeOptions();
    if #options == 0 then
        return;
    end
    local current = activeIndex();
    if current < 1 then
        current = (step > 0) and 0 or (#options + 1);
    end
    local next = firstUsableIndex(options, current + step, step);
    if next == 0 or next == current then
        return;
    end
    setActiveIndex(next);
    playNavSound();
    speakIndex(options, next, true);
end

local function moveTo(idx)
    local options = activeOptions();
    if idx < 1 or idx > #options then
        return;
    end
    local target = firstUsableIndex(options, idx, 1);
    if target == 0 or target == activeIndex() then
        return;
    end
    setActiveIndex(target);
    playNavSound();
    speakIndex(options, target, true);
end

local function activateCurrent()
    local options = activeOptions();
    local idx = activeIndex();
    local entry = options[idx];
    if entry == nil or entry.activate == nil then
        return;
    end
    -- Activation routes through the same callback the mouse click does,
    -- which speaks "<label>, activated" via the engine's own announcement
    -- pipeline downstream. Emit our own line so the user gets immediate
    -- feedback before any submenu/popup transition kicks in.
    local label = labelForControl(entry.control);
    if label ~= "" then
        OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_ITEM_ACTIVATED", label));
    end
    entry.activate();
end

local function escapeBack()
    if m_inSubMenu then
        m_inSubMenu = false;
        m_subOptions = {};
        m_subIndex = 0;
        playNavSound();
        -- Brief location cue. Earlier wording "Back to main menu" was verbose;
        -- Noel's 2026-05-11 testing feedback was that the back transition
        -- would be better signaled by a distinct earcon plus a terse label.
        -- For now we shorten to just "Main menu" and stay on the standard
        -- nav sound. A dedicated earcon is future work (see popup-nav-standard
        -- memory and the earcon discussion thread).
        OutputMessageToScreenReader(Locale.Lookup("LOC_CIVVIACCESS_MAIN_MENU_BACK_CUE"));
        if m_mainIndex > 0 then
            speakIndex(m_mainOptions, m_mainIndex, false);
        end
        return true;
    end
    -- At top level, route Esc to the same exit-confirmation dialog Alt+F4
    -- fires. Common app/game convention: Esc at the root either no-ops or
    -- prompts to exit; the prompt path is more discoverable for blind
    -- users hunting for "how do I quit." The dialog is already arrow-key
    -- nav + Esc-cancelable per project_popup_nav_standard.
    if LuaEvents ~= nil and LuaEvents.MainMenu_UserRequestClose ~= nil then
        LuaEvents.MainMenu_UserRequestClose();
        return true;
    end
    return false;
end

-- ===========================================================================
--  Input handler
-- ===========================================================================
-- Civ VI's Keys.VK_* are exposed in FrontEnd Contexts (FrontEndPopup uses
-- Keys.VK_ESCAPE there), so we rely on those when present and fall back to
-- raw VK codes if the table isn't in scope.
local function vk(name, fallback)
    if Keys ~= nil and Keys[name] ~= nil then
        return Keys[name];
    end
    return fallback;
end

local VK_RETURN :number = vk("VK_RETURN", 0x0D);
local VK_ESCAPE :number = vk("VK_ESCAPE", 0x1B);
local VK_SPACE  :number = vk("VK_SPACE",  0x20);
local VK_END    :number = vk("VK_END",    0x23);
local VK_HOME   :number = vk("VK_HOME",   0x24);
local VK_LEFT   :number = vk("VK_LEFT",   0x25);
local VK_UP     :number = vk("VK_UP",     0x26);
local VK_RIGHT  :number = vk("VK_RIGHT",  0x27);
local VK_DOWN   :number = vk("VK_DOWN",   0x28);

function MainMenuAccess.OnInput(uiMsg, wParam, lParam)
    if uiMsg ~= KEY_UP_MSG then
        return false;
    end
    if wParam == VK_UP or wParam == VK_LEFT then
        moveBy(-1);
        return true;
    end
    if wParam == VK_DOWN or wParam == VK_RIGHT then
        moveBy(1);
        return true;
    end
    if wParam == VK_HOME then
        moveTo(1);
        return true;
    end
    if wParam == VK_END then
        moveTo(#activeOptions());
        return true;
    end
    if wParam == VK_RETURN or wParam == VK_SPACE then
        activateCurrent();
        return true;
    end
    if wParam == VK_ESCAPE then
        if escapeBack() then
            return true;
        end
    end
    return false;
end

-- ===========================================================================
--  Notifications from MainMenu.lua
-- ===========================================================================
-- Capture the live option list right after BuildMenu / BuildSubMenu run so
-- we can walk them in keyboard order. MainMenu.lua already stores the main
-- options in m_currentOptions; for submenus it builds m_subMenuOptions
-- (uiOption controls). The hook accepts whatever shape it gets and
-- normalizes to {control = ..., activate = ...} entries.

-- options: array of { control = uiOption, callback = fn, label = textKey }
function MainMenuAccess.NotifyMainMenuBuilt(options)
    m_mainOptions = {};
    for i, opt in ipairs(options or {}) do
        m_mainOptions[i] = {
            control  = opt.control,
            activate = opt.activate,
        };
    end
    local first = firstUsableIndex(m_mainOptions, 1, 1);
    m_mainIndex = first;
    if not m_initialOpened and first > 0 then
        m_initialOpened = true;
        m_suppressNextShow = true;
        announceMenuRoot();
    end
end

function MainMenuAccess.NotifySubMenuBuilt(options)
    m_subOptions = {};
    for i, opt in ipairs(options or {}) do
        m_subOptions[i] = {
            control  = opt.control,
            activate = opt.activate,
        };
    end
    m_inSubMenu = (#m_subOptions > 0);
    if not m_inSubMenu then
        return;
    end
    m_subIndex = firstUsableIndex(m_subOptions, 1, 1);
    if m_subIndex > 0 then
        playNavSound();
        speakIndex(m_subOptions, m_subIndex, true);
    end
end

function MainMenuAccess.NotifySubMenuClosed()
    if not m_inSubMenu then
        return;
    end
    m_inSubMenu = false;
    m_subOptions = {};
    m_subIndex = 0;
    if m_mainIndex > 0 then
        speakIndex(m_mainOptions, m_mainIndex, false);
    end
end

function MainMenuAccess.NotifyShow()
    if m_suppressNextShow then
        m_suppressNextShow = false;
        return;
    end
    if m_mainIndex > 0 then
        announceMenuRoot();
    end
end

-- ===========================================================================
--  ContextPtr wiring
-- ===========================================================================
-- Called from MainMenu.lua's Initialize() with the MainMenu ContextPtr.
-- Chains underneath any prior input handler the screen may have so we don't
-- silently drop input events the rest of the screen relies on.
function MainMenuAccess.Install(ctx)
    local prior = nil;
    if ctx.GetInputHandler ~= nil then
        prior = ctx:GetInputHandler();
    end
    ctx:SetInputHandler(function(uiMsg, wParam, lParam)
        if MainMenuAccess.OnInput(uiMsg, wParam, lParam) then
            return true;
        end
        if prior ~= nil then
            return prior(uiMsg, wParam, lParam);
        end
        return false;
    end);
end

-- Wrap MainMenu's existing OnShow so we re-announce when the screen
-- re-appears (e.g., on return from Options / LoadGameMenu / AdvancedSetup).
-- Call site captures the engine's OnShow by explicit name; ContextPtr has
-- no GetShowHandler so Get-based chaining silently no-ops.
function MainMenuAccess.WrapShow(origShowFn)
    return function()
        if origShowFn ~= nil then origShowFn(); end
        MainMenuAccess.NotifyShow();
    end
end

print("[CivViAccess][INFO ] MainMenuAccess.lua: file loaded, MainMenuAccess global set");
