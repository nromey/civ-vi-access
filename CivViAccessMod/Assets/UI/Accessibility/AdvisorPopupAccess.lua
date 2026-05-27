-- Advisor popup accessibility companion.
--
-- Owns the screen-reader announce + keyboard input dispatch for every
-- tutorial / advisor modal raised through Civ VI's AdvisorPopup system
-- (Base/Assets/UI/Popups/AdvisorPopup.lua). The Firaxis fork in
-- Assets/UI/Popups/AdvisorPopup.lua is touched minimally: it includes
-- this file, hands off advisorData on every ShowAdvisorPopup, and
-- routes input through HandleKey before falling through to the engine.
--
-- Why this exists:
-- Civ VI's AdvisorPopup ships a TutorialContinue hotkey that ONLY fires
-- button 1. The 2-button FIRST_GREETING ("New to Civilization series"
-- vs "New to Civilization 6") is mouse-only for the second option,
-- which silently locks a blind player into option 1 forever (the
-- tutorial-level choice is persistent for the rest of the game). This
-- companion adds real arrow-key nav between buttons, owns the input
-- dispatch, and announces both options so the user picks deliberately.
-- See docs/flow-trace/06-first-turn-advisor-popup.md for the full
-- trace + design.
--
-- Key bindings (active while an advisor popup is visible):
--   Up / Down / Left / Right  cycle focus between buttons (when 2+)
--   Enter / Space             activate the focused button
--   Escape                    1-button: activate; 0-button: dismiss;
--                             2-button: speak "choice required"
--                             (do NOT open the pause menu, which is
--                             the engine's default Esc behavior)
--   Ctrl+T                    re-speak the message body
--   Ctrl+I                    speak advisor portrait description
--                             (placeholder until describer batch
--                             lands; binding wired for the future)
--
-- Replaces SuppressFirstTurnAdvisor.lua's "set the flag and skip the
-- popup" hack with a real accessible choice. SuppressFirstTurnAdvisor
-- stays in place as a safety net until this wrapper is proven in
-- play; remove it once the wrapper is verified end-to-end.

include("ScreenReader");
include("Log");

AdvisorPopupAccess = {};

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
local VK_SHIFT   :number = vk("VK_SHIFT",  0x10);
local VK_CONTROL :number = vk("VK_CONTROL",0x11);
local VK_I       :number = vk("VK_I",      0x49);
local VK_T       :number = vk("VK_T",      0x54);

-- ===========================================================================
--  State
-- ===========================================================================
-- m_currentData is intentionally UNTYPED. Civ VI passes an
-- `AdvisorItem` hstructure here, not a plain table. Annotating
-- :table caused a Havok Script type-check failure at assignment
-- time (round-4 log: "expected 'table', but got instance of
-- 'AdvisorItem'"), which threw the function before m_visible could
-- be set — so HandleKey always saw visible=false and arrow nav
-- never worked. Leaving untyped is the correct fix.
local m_currentData              = nil;    -- last advisorData passed to OnShow
local m_focusedButton    :number  = 1;      -- 1 or 2 (only meaningful if 2 buttons)
local m_buttonCount      :number  = 0;
local m_visible          :boolean = false;
local m_ctrlDown         :boolean = false;

-- ===========================================================================
--  Speech helpers
-- ===========================================================================
local function safeLookup(key)
    if key == nil or key == "" then return ""; end
    local ok, value = pcall(Locale.Lookup, key);
    if not ok or value == nil then return ""; end
    return stripIconTags(value);
end

-- Advisor popup speech: nointerrupt=true → status (continuation
-- lines after the popup body), false/nil → selection (popup landing /
-- button focus changes).
local function speak(text, nointerrupt)
    if text == nil or text == "" then return; end
    Speech.emit(text, nointerrupt and "status" or "selection");
end

local function buttonLabel(idx)
    if m_currentData == nil then return ""; end
    if idx == 1 then return safeLookup(m_currentData.Button1Text); end
    if idx == 2 then return safeLookup(m_currentData.Button2Text); end
    return "";
end

local function buttonFunc(idx)
    if m_currentData == nil then return nil; end
    if idx == 1 then return m_currentData.Button1Func; end
    if idx == 2 then return m_currentData.Button2Func; end
    return nil;
end

local function countButtons(advisorData)
    if advisorData == nil then return 0; end
    local n = 0;
    if advisorData.Button1Text ~= nil and advisorData.Button1Text ~= "" then n = n + 1; end
    if advisorData.Button2Text ~= nil and advisorData.Button2Text ~= "" then n = n + 1; end
    return n;
end

-- Resolve the message body. AdvisorItem uses .Message most of the
-- time; some tutorial items use .CalloutHeader + .CalloutBody instead
-- (smaller worldspace tutorial callouts). Combine into a single line
-- when both are present.
local function resolveMessage(advisorData)
    if advisorData == nil then return ""; end
    local message = safeLookup(advisorData.Message);
    if message ~= "" then return message; end
    local header = safeLookup(advisorData.CalloutHeader);
    local body   = safeLookup(advisorData.CalloutBody);
    if header ~= "" and body ~= "" then
        return header .. ". " .. body;
    elseif header ~= "" then
        return header;
    elseif body ~= "" then
        return body;
    end
    return "";
end

local function titleForPopup(advisorData)
    if advisorData ~= nil and advisorData.ShowPortrait then
        return safeLookup("LOC_CIVVIACCESS_ADVISOR_TITLE");
    end
    return safeLookup("LOC_CIVVIACCESS_NOTIFICATION_TITLE");
end

-- ===========================================================================
--  Announce assembly
-- ===========================================================================
local function announceOpen()
    if m_currentData == nil then return; end

    local title   = titleForPopup(m_currentData);
    local message = resolveMessage(m_currentData);

    -- Build the choice prompt based on button count.
    local choicePhrase;
    if m_buttonCount >= 2 then
        choicePhrase = Locale.Lookup(
            "LOC_CIVVIACCESS_ADVISOR_CHOICE_FORMAT",
            m_focusedButton,
            m_buttonCount,
            buttonLabel(m_focusedButton));
    elseif m_buttonCount == 1 then
        choicePhrase = Locale.Lookup(
            "LOC_CIVVIACCESS_ADVISOR_SINGLE_BUTTON_FORMAT",
            buttonLabel(1));
    else
        choicePhrase = Locale.Lookup(
            "LOC_CIVVIACCESS_ADVISOR_DISMISS_HINT");
    end

    local parts = { title };
    if message ~= "" then table.insert(parts, message .. "."); end
    table.insert(parts, choicePhrase);

    -- Append the portrait hint (Ctrl+I) only when a portrait is shown.
    -- Hint for Ctrl+T (re-read message) goes on every popup.
    local hint;
    if m_currentData.ShowPortrait then
        hint = Locale.Lookup("LOC_CIVVIACCESS_ADVISOR_PORTRAIT_AND_REREAD_HINT");
    else
        hint = Locale.Lookup("LOC_CIVVIACCESS_ADVISOR_REREAD_HINT");
    end
    if hint ~= nil and hint ~= "" then
        table.insert(parts, hint);
    end

    speak(table.concat(parts, " "));
end

local function announceFocusedButton()
    if m_currentData == nil or m_buttonCount < 2 then return; end
    local text = Locale.Lookup(
        "LOC_CIVVIACCESS_ADVISOR_FOCUS_FORMAT",
        m_focusedButton,
        m_buttonCount,
        buttonLabel(m_focusedButton));
    speak(text);
end

-- ===========================================================================
--  Actions
-- ===========================================================================
local function cycleFocus(delta)
    if m_buttonCount < 2 then return; end
    local next = m_focusedButton + delta;
    if next < 1 then next = m_buttonCount; end
    if next > m_buttonCount then next = 1; end
    if next == m_focusedButton then return; end
    m_focusedButton = next;
    announceFocusedButton();
end

-- Invoke the focused button's callback. We do NOT touch the engine's
-- m_hotkeyCallback (module-local to AdvisorPopup.lua); instead we own
-- the button-func dispatch ourselves and ask the engine to clean up
-- the popup via OnHideAdvisorDialog (which it exports as a global in
-- the shadowed file).
local function activateFocused()
    local fn = buttonFunc(m_focusedButton);
    if fn == nil then
        speak(Locale.Lookup(
            "LOC_CIVVIACCESS_ADVISOR_CHOICE_REQUIRED"));
        return;
    end
    local label = buttonLabel(m_focusedButton);
    Log.info("AdvisorPopupAccess.activateFocused: button " .. m_focusedButton
             .. " (" .. tostring(label) .. ")");
    -- Speak a confirmation BEFORE we close — Tolk's interrupt path
    -- might cut off if the popup state changes mid-speech, but the
    -- string is short. User reported "selected new to civilization
    -- and pressed enter, nothing happened" — adding this announce
    -- so the activation is audibly confirmed.
    speak(Locale.Lookup("LOC_CIVVIACCESS_ADVISOR_ACTIVATED_FORMAT",
        label));
    local data = m_currentData;
    if OnHideAdvisorDialog ~= nil then
        OnHideAdvisorDialog();
    end
    local ok, err = pcall(fn, data);
    if not ok then
        Log.warn("AdvisorPopupAccess: button " .. tostring(m_focusedButton)
              .. " callback failed: " .. tostring(err));
    end
end

local function speakPortraitDescription()
    if m_currentData == nil or not m_currentData.ShowPortrait then
        speak(safeLookup("LOC_CIVVIACCESS_ADVISOR_NO_PORTRAIT"));
        return;
    end
    -- Per-advisor description LOC keys land later via the describer
    -- batch over Advisors128.dds. Until then, speak a clean placeholder
    -- so the binding works and users know the feature is wired.
    speak(safeLookup("LOC_CIVVIACCESS_ADVISOR_PORTRAIT_PLACEHOLDER"));
end

local function reReadMessage()
    if m_currentData == nil then return; end
    local title   = titleForPopup(m_currentData);
    local message = resolveMessage(m_currentData);
    if message == "" then
        speak(title);
    else
        speak(title .. " " .. message .. ".");
    end
end

-- ===========================================================================
--  Input dispatch (called from shadowed AdvisorPopup.lua's OnInputHandler)
-- ===========================================================================
-- Returns true if we consumed the key. The shadowed handler bails out
-- early on true; on false it falls through to the engine's KeyHandler.

function AdvisorPopupAccess.HandleKey(pInputStruct)
    if pInputStruct == nil or pInputStruct.GetMessageType == nil then
        return false;
    end
    local uiMsg = pInputStruct:GetMessageType();
    local wParam = pInputStruct:GetKey();
    -- Diagnostic: log every key the shadow forwards to us so we can
    -- confirm input dispatch is reaching this handler.
    if uiMsg == KEY_UP_MSG then
        Log.info(string.format("AdvisorPopupAccess.HandleKey: keyup=%d visible=%s ctrl=%s",
            wParam, tostring(m_visible), tostring(m_ctrlDown)));
    end

    -- Track Ctrl state. Tutorial layer delivers KeyDown / KeyUp pairs
    -- reliably for modifier keys.
    if wParam == VK_CONTROL then
        if uiMsg == KEY_DOWN_MSG then m_ctrlDown = true;
        elseif uiMsg == KEY_UP_MSG then m_ctrlDown = false; end
        return false;
    end

    -- Only act on KeyUp (mirrors the engine's KeyHandler).
    if uiMsg ~= KEY_UP_MSG then return false; end
    if not m_visible then return false; end

    -- Portrait description: Ctrl+I OR bare I. Bare-key alternates
    -- exist because Civ VI's Ctrl tracking is unreliable (round-5
    -- log: keyup=84 (T) ctrl=false — Ctrl was released before T).
    -- Bare I/T are safe here because the advisor popup blocks
    -- engine input, so no conflict.
    if wParam == VK_I then
        speakPortraitDescription();
        return true;
    end

    -- Re-read message: Ctrl+T OR bare T.
    if wParam == VK_T then
        reReadMessage();
        return true;
    end

    -- Arrow keys — focus cycling when 2 buttons are present.
    if m_buttonCount >= 2 then
        if wParam == VK_RIGHT or wParam == VK_DOWN then
            cycleFocus(1);
            return true;
        end
        if wParam == VK_LEFT or wParam == VK_UP then
            cycleFocus(-1);
            return true;
        end
    end

    -- Enter / Space — activate focused button (or single button, or
    -- speak "choice required" if 0 buttons but popup is up).
    if wParam == VK_RETURN or wParam == VK_SPACE then
        if m_buttonCount == 0 then
            -- 0-button info popups: dismiss via the engine's hide
            -- (caller's Close path handles it).
            if OnHideAdvisorDialog ~= nil then
                OnHideAdvisorDialog();
            end
            return true;
        end
        activateFocused();
        return true;
    end

    -- Escape — choice-required override for 2-button popups; activate
    -- the focused (single) button for 1-button; dismiss for 0-button.
    -- The engine's default Esc opens the pause menu, which is wrong
    -- in every case for a blind user mid-modal.
    if wParam == VK_ESCAPE then
        if m_buttonCount >= 2 then
            speak(Locale.Lookup(
                "LOC_CIVVIACCESS_ADVISOR_CHOICE_REQUIRED"));
            return true;
        end
        if m_buttonCount == 1 then
            activateFocused();
            return true;
        end
        if OnHideAdvisorDialog ~= nil then
            OnHideAdvisorDialog();
        end
        return true;
    end

    return false;
end

-- ===========================================================================
--  Notifications from the shadowed AdvisorPopup.lua
-- ===========================================================================

-- Called from inside the shadowed ShowAdvisorPopup AFTER the engine
-- finishes building the dialog. advisorData is the current item.
-- Dedupe: the engine sometimes raises FIRST_GREETING twice in
-- rapid succession (once via TutorialUIRoot, once via the queued-
-- popup drain). Without dedupe, we announce the same popup body
-- twice. Compare msg+button text; if identical to the last call
-- within a short window, skip the announce (state is still set
-- because focus / count etc. may have shifted; only the speech
-- is suppressed).
local m_lastAnnounceSig  :string = "";
local m_lastAnnounceTime :number = 0;
local function nowSec()
    if os ~= nil and os.clock ~= nil then
        local ok, v = pcall(os.clock);
        if ok and type(v) == "number" then return v; end
    end
    return 0;
end

function AdvisorPopupAccess.NotifyShow(advisorData)
    m_currentData   = advisorData;
    m_buttonCount   = countButtons(advisorData);
    m_focusedButton = 1;
    m_visible       = true;
    m_ctrlDown      = false;
    Log.info(string.format("AdvisorPopupAccess.NotifyShow called: buttons=%d msg=%s",
        m_buttonCount,
        tostring((advisorData and advisorData.Message) or "nil")));
    local sig = tostring(advisorData and advisorData.Message or "")
                .. "|" .. tostring(advisorData and advisorData.Button1Text or "")
                .. "|" .. tostring(advisorData and advisorData.Button2Text or "");
    local t = nowSec();
    if sig == m_lastAnnounceSig and (t - m_lastAnnounceTime) < 2 then
        Log.info("AdvisorPopupAccess.NotifyShow: suppressing duplicate announce within 2s");
        return;
    end
    m_lastAnnounceSig = sig;
    m_lastAnnounceTime = t;
    announceOpen();
end

-- Called from the shadowed Close() / OnHideAdvisorDialog when the
-- popup is going away.
function AdvisorPopupAccess.NotifyClose()
    m_visible       = false;
    m_currentData   = nil;
    m_buttonCount   = 0;
    m_focusedButton = 1;
    m_ctrlDown      = false;
end

Log.info("AdvisorPopupAccess.lua: loaded");
