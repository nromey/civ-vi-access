-- FrontEnd popup override.
--
-- The base game's FrontEndPopup.lua owns the modal that appears when the
-- player presses Alt+F4 on the main menu (it catches MainMenu_UserRequestClose
-- and asks "Exit to desktop? [OK] [Cancel]"). It also owns generic FE error
-- popups (LaunchError, FrontEndPopup, MultiplayerPopup). For sighted users
-- it's a mouse-driven dialog; for blind users it was unannounced and unkeyed.
--
-- This override preserves all of the base behavior verbatim, and layers on:
--   * speak the title + body + first-button label every time the dialog opens
--   * arrow-key navigation across buttons with the Main_Menu_Mouse_Over cue
--     and announce on each focus move (project standard for every dialog —
--     see project_popup_nav_standard memory).
--   * Enter / Space activates the currently focused button (NOT just the
--     first one). Esc fires the CANCEL command when present, otherwise the
--     focused button so the dialog still dismisses.
--
-- This file is a fork of Base/Assets/UI/FrontEnd/FrontEndPopup.lua. When a
-- Civ VI patch ships a new FrontEndPopup, diff against the base and re-apply
-- the include + announce + nav wiring.

include("PopupDialog");
include("ScreenReader");

m_kPopupDialog = PopupDialog:new("FrontEndPopup");

-- ===========================================================================
-- Accessibility: announce + button navigation state
-- ===========================================================================
-- m_announceTitle / m_announceText hold the strings to speak after Open()
-- finishes laying out the dialog. m_buttons is the navigable button list:
-- {label, callback, command} tuples captured from the AddButton calls. We
-- can't read this directly from m_kPopupDialog.PopupControls because we
-- want the localized labels (the controls store text-set on a child label
-- node we'd have to walk), so we mirror them as we add.

local NAV_SOUND :string = "Main_Menu_Mouse_Over";

local m_announceTitle :string = "";
local m_announceText  :string = "";
local m_buttons       :table  = {};
local m_focused       :number = 0;

local function playNavSound()
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound(NAV_SOUND);
    end
end

local function resetAnnounce()
    m_announceTitle = "";
    m_announceText  = "";
    m_buttons       = {};
    m_focused       = 0;
end

local function pushButton(label, callback, command)
    if label == nil or label == "" then
        return;
    end
    m_buttons[#m_buttons + 1] = {
        label    = label,
        callback = callback,
        command  = command,
    };
end

local function flushAnnounce()
    local parts = {};
    if m_announceTitle ~= "" then
        parts[#parts + 1] = m_announceTitle;
    end
    if m_announceText ~= "" then
        parts[#parts + 1] = m_announceText;
    end
    if #m_buttons > 0 then
        m_focused = 1;
        local list = {};
        for i, btn in ipairs(m_buttons) do
            list[i] = btn.label;
        end
        parts[#parts + 1] = Locale.Lookup("LOC_CIVVIACCESS_POPUP_BUTTONS_HELP", table.concat(list, ", "));
        parts[#parts + 1] = Locale.Lookup("LOC_CIVVIACCESS_POPUP_FOCUSED", m_buttons[1].label);
    end
    if #parts == 0 then
        return;
    end
    Speech.emit(table.concat(parts, ". "), "selection");
end

local function moveFocus(step)
    local n = #m_buttons;
    if n <= 1 then
        return;
    end
    local target = m_focused + step;
    if target < 1 then target = n; end
    if target > n then target = 1; end
    if target == m_focused then
        return;
    end
    m_focused = target;
    playNavSound();
    Speech.emit(m_buttons[target].label, "picker");
end

local function moveTo(idx)
    if idx < 1 or idx > #m_buttons or idx == m_focused then
        return;
    end
    m_focused = idx;
    playNavSound();
    Speech.emit(m_buttons[idx].label, "picker");
end

-- AddButton internally wraps each callback as `function() self:Close(); cb() end`
-- (PopupDialog.lua line ~216). Mirror that behavior when activating from
-- the keyboard so the dialog hides cleanly before the user's callback runs
-- — otherwise the OK/Cancel button stays visible until the next frame.
local function fireButton(btn)
    if btn == nil then
        return;
    end
    Speech.emit(Locale.Lookup("LOC_CIVVIACCESS_ITEM_ACTIVATED", btn.label), "event");
    m_kPopupDialog:Close();
    if btn.callback ~= nil then
        btn.callback();
    end
end

local function activateFocused()
    fireButton(m_buttons[m_focused]);
end

local function cancelDialog()
    for _, btn in ipairs(m_buttons) do
        if btn.command == PopupDialog.COMMAND_CANCEL then
            fireButton(btn);
            return;
        end
    end
    -- No explicit Cancel: fall through to whichever button currently has
    -- focus so Esc still closes the dialog. For single-button informational
    -- popups (OnFrontEndPopup) this is the same Close button the user
    -- would hit with Enter.
    activateFocused();
end

-------------------------------------------------
-- Event Handler: FrontEndPopup
-------------------------------------------------
function OnFrontEndPopup(popupText :string, popupTitle :string)
    UIManager:QueuePopup( ContextPtr, PopupPriority.Current );

    m_kPopupDialog:Close();
    resetAnnounce();

    local title = Locale.Lookup(popupTitle);
    local body  = Locale.Lookup(popupText);
    local close = Locale.Lookup("LOC_CLOSE");

    m_kPopupDialog:AddTitle(title);
    m_kPopupDialog:AddText(body);
    m_kPopupDialog:AddButton(close, OnPopupClose, PopupDialog.COMMAND_CONFIRM);

    m_announceTitle = title;
    m_announceText  = body;
    pushButton(close, OnPopupClose, PopupDialog.COMMAND_CONFIRM);

    m_kPopupDialog:Open();
    flushAnnounce();
end

-- ===========================================================================
function OnUserRequestClose()
    UIManager:QueuePopup( ContextPtr, PopupPriority.Current );

    m_kPopupDialog:Close();
    resetAnnounce();

    local title = Locale.ToUpper(Locale.Lookup("LOC_MAIN_MENU_EXIT_TO_DESKTOP"));
    local body  = Locale.Lookup("LOC_CONFIRM_EXIT_TXT");
    local ok    = Locale.Lookup("LOC_OK_BUTTON");
    local cancel = Locale.Lookup("LOC_CANCEL_BUTTON");

    m_kPopupDialog:AddText(body);
    m_kPopupDialog:AddTitle(title);
    m_kPopupDialog:AddButton(ok, ExitOK, PopupDialog.COMMAND_CONFIRM, nil, "PopupButtonInstanceRed");
    m_kPopupDialog:AddButton(cancel, OnPopupClose, PopupDialog.COMMAND_CANCEL);

    m_announceTitle = title;
    m_announceText  = body;
    pushButton(ok, ExitOK, PopupDialog.COMMAND_CONFIRM);
    pushButton(cancel, OnPopupClose, PopupDialog.COMMAND_CANCEL);

    m_kPopupDialog:Open();
    flushAnnounce();
end

-- ===========================================================================
function OnLaunchError(error:string)
    UIManager:QueuePopup( ContextPtr, PopupPriority.Current );

    m_kPopupDialog:Close();
    resetAnnounce();

    local title    = Locale.ToUpper(Locale.Lookup("LOC_GAME_START_ERROR_TITLE"));
    local viewMods = Locale.Lookup("LOC_GAME_START_VIEW_MODS");
    local close    = Locale.Lookup("LOC_CLOSE");

    m_kPopupDialog:AddText(error);
    m_kPopupDialog:AddTitle(title);
    m_kPopupDialog:AddButton(viewMods, OnDisableMods, PopupDialog.COMMAND_CONFIRM, nil, "PopupButtonInstanceGreen");
    m_kPopupDialog:AddButton(close, OnPopupClose, PopupDialog.COMMAND_CANCEL);

    m_announceTitle = title;
    m_announceText  = error;
    pushButton(viewMods, OnDisableMods, PopupDialog.COMMAND_CONFIRM);
    pushButton(close, OnPopupClose, PopupDialog.COMMAND_CANCEL);

    m_kPopupDialog:Open();
    flushAnnounce();
end


-- ===========================================================================
function OnDisableMods()
    OnPopupClose();
    LuaEvents.MainMenu_ShowAdditionalContent();
end

-- ===========================================================================
function OnPopupClose()
    UIManager:DequeuePopup( ContextPtr );
    LuaEvents.FrontEndPopup_CloseConfirmationWithoutAction();
end

-- ===========================================================================
function ExitOK()
    OnPopupClose();

    local pFriends = Network.GetFriends();
    if pFriends ~= nil then
        pFriends:ClearRichPresence();
    end

    Speech.emit(Locale.Lookup("LOC_CIVVIACCESS_QUITTING"), "event");
    Events.UserConfirmedClose();
end

-- ===========================================================================
-- Input handler. Project standard ([[popup-nav-standard]]):
--   Up / Down / Left / Right   move focus across buttons (with nav sound +
--                              announce of new focused label)
--   Home / End                 first / last button
--   Enter / Space              activate currently focused button
--   Esc                        fire CANCEL command if the dialog has one,
--                              otherwise activate the focused button so
--                              the dialog still dismisses
-- ===========================================================================
function InputHandler( uiMsg, wParam, lParam )
    if uiMsg ~= KeyEvents.KeyUp then
        return true;
    end
    if not (m_kPopupDialog and m_kPopupDialog:IsOpen()) then
        return true;
    end
    if wParam == Keys.VK_UP or wParam == Keys.VK_LEFT then
        moveFocus(-1);
        return true;
    end
    if wParam == Keys.VK_DOWN or wParam == Keys.VK_RIGHT then
        moveFocus(1);
        return true;
    end
    if wParam == Keys.VK_HOME then
        moveTo(1);
        return true;
    end
    if wParam == Keys.VK_END then
        moveTo(#m_buttons);
        return true;
    end
    if wParam == Keys.VK_RETURN or wParam == Keys.VK_SPACE then
        activateFocused();
        return true;
    end
    if wParam == Keys.VK_ESCAPE then
        cancelDialog();
        return true;
    end
    return true;
end

-- ===========================================================================
function Initialize()
    ContextPtr:SetInputHandler( InputHandler );

    -- Events.FrontEndPopup has 256 character limit for popupText and popupTitle.
    -- LuaEvents.MultiplayerPopup should have unlimited character size.
    Events.FrontEndPopup.Add( OnFrontEndPopup );
    LuaEvents.MultiplayerPopup.Add( OnFrontEndPopup );
    LuaEvents.MainMenu_LaunchError.Add( OnLaunchError );
    LuaEvents.MainMenu_UserRequestClose.Add( OnUserRequestClose );
end
Initialize();
