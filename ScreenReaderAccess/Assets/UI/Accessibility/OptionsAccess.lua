-- Options accessibility companion.
--
-- Owns keyboard navigation + spoken focus tracking for the Options screen
-- (Base/Assets/UI/Options.lua). The Firaxis fork is touched as minimally as
-- possible: an include, a few Register* hand-offs so we can capture the
-- screen's anonymous slider / checkbox callbacks, and an Install() call at
-- the end of Initialize(). Everything else lives here.
--
-- Architecture mirrors MainMenuAccess: declarative item list per tab, with
-- a small handler table keyed by item kind ("slider", "checkbox", "button").
-- Tabs that aren't fully populated yet still expose Reset / Confirm / Close
-- so the user can always commit or back out.
--
-- Slider callback capture (Civ V Access's PullDownProbe equivalent):
-- Civ VI Options.lua registers a fresh anonymous closure per slider via
-- :RegisterSliderCallback(fn). The engine only invokes that closure on
-- mouse drag — calling :SetValue() from Lua does not fire it. To make our
-- keyboard adjustments actually update the game state (audio volumes,
-- prompt flags, ConfirmButton enable state, feedback sounds), the fork
-- hands each callback to OptionsAccess.RegisterSliderCallback at the same
-- site where it registers with the engine. We stash by controlName and
-- invoke after SetValue() ourselves.
--
-- Key bindings (only fire while Options is active and unhidden):
--   Up / Down          previous / next item within the current tab
--   Home / End         first / last item within the current tab
--   Left / Right       slider: step value down / up (or pulldown prev/next)
--   Shift+Left/Right   slider: big step
--   Enter / Space      activate / toggle focused item
--   Tab / Shift+Tab    next / previous tab; re-announce first item in new tab
--   Escape             fall through to engine (which calls OnCancel)
--
-- MVP scope (2026-05-13): Audio tab fully populated; other six tabs are
-- stubs that expose only the Reset / Confirm / Close buttons. The screen
-- is fully reachable, navigable, and dismissable; tab content fills in
-- per session as we read each Firaxis section.

include("ScreenReader");
include("ContextHelp");

OptionsAccess = {};

-- ===========================================================================
--  Constants
-- ===========================================================================
local NAV_SOUND    :string = "Main_Menu_Mouse_Over";
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
local VK_END     :number = vk("VK_END",    0x23);
local VK_HOME    :number = vk("VK_HOME",   0x24);
local VK_LEFT    :number = vk("VK_LEFT",   0x25);
local VK_UP      :number = vk("VK_UP",     0x26);
local VK_RIGHT   :number = vk("VK_RIGHT",  0x27);
local VK_DOWN    :number = vk("VK_DOWN",   0x28);
local VK_TAB     :number = vk("VK_TAB",    0x09);
-- Civ VI delivers Tab two ways: msg=1 KeyUp with key=Keys.VK_TAB (which is
-- 101 in Civ VI's mapping, NOT the standard Win32 9), AND msg=2 navigation
-- event with the raw Win32 key=9. Forward Tab usually delivers both; Shift+Tab
-- only delivers the msg=2 variant (engine consumes the KeyUp form for its
-- own backward-focus handling). Match both to capture all Tab presses.
local VK_TAB_NAV :number = 0x09;
local VK_SHIFT   :number = vk("VK_SHIFT",  0x10);
local VK_CONTROL :number = vk("VK_CONTROL",0x11);
local VK_PRIOR   :number = vk("VK_PRIOR",  0x21); -- PageUp
local VK_NEXT    :number = vk("VK_NEXT",   0x22); -- PageDown
local VK_F1      :number = vk("VK_F1",     0x70);

local STEP_SMALL :number = 0.05;   -- Left / Right = 5%
local STEP_BIG   :number = 0.20;   -- Shift+Left/Right = 20%

-- ===========================================================================
--  State
-- ===========================================================================
local m_tabs              :table   = {};    -- mirror of Options.lua m_tabs
local m_tabItems          :table   = {};    -- items[tabIdx] = { item, ... }
local m_tabIndex          :number  = 1;
local m_itemIndex         :table   = {};    -- per-tab cursor; itemIndex[tabIdx]
local m_sliderCallbacks   :table   = {};    -- by controlName -> fn(value)
local m_checkboxCallbacks :table   = {};    -- by controlName -> fn(boolean)
local m_pulldownData      :table   = {};    -- by control-userdata-key -> { values, callback, control }
local m_screenOpen        :boolean = false;
local m_confirmEnabled    :boolean = false; -- track changes to announce save-ready
local m_shiftDown         :boolean = false;
local m_ctrlDown          :boolean = false;
-- Time-window suppression for spurious Shift KeyDown events that fire just
-- after a Shift+Tab dispatch (engine quirk where shift state appears to
-- "bounce" without a corresponding KeyUp). When a Shift+Tab dispatches we
-- set m_shiftSuppressUntil = now + 100ms. Any Shift KD within that window
-- without an intervening Shift KU is ignored. A legitimate KU clears the
-- window so a real re-press of shift after release works normally.
local m_shiftSuppressUntil :number = 0;
local SHIFT_SUPPRESS_MS    :number = 0.1; -- 100ms window

local function nowSec()
    if os ~= nil and os.clock ~= nil then
        local ok, v = pcall(os.clock);
        if ok and type(v) == "number" then return v; end
    end
    return 0; -- timer unavailable: suppression becomes a no-op
end

-- ===========================================================================
--  Pulldown capture (called by the Options.lua fork)
-- ===========================================================================
-- Civ VI's PopulateComboBox is defined IN Options.lua itself (line 317),
-- not in Civ6Common.lua as initially assumed. Wrapping the global at
-- OptionsAccess module-load time captured nil and got clobbered when line
-- 317 ran its own definition. Instead, the fork wraps PopulateComboBox
-- immediately after the engine defines it (one edit, all callers captured)
-- and calls this function with (control, values, callback) for each
-- registration. That gives our keyboard adjust logic the entries + engine
-- selection callback it needs to cycle and fire.
function OptionsAccess.CapturePulldown(control, values, selection_handler)
    if control == nil then return; end
    m_pulldownData[tostring(control)] = {
        values   = values,
        callback = selection_handler,
        control  = control,
    };
end

-- ===========================================================================
--  Helpers
-- ===========================================================================
local function playNavSound()
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound(NAV_SOUND);
    end
end

-- stripIconTags lives in ScreenReader.lua as a global; we use it on the
-- read path (loc helper, pulldown text capture, editbox text) because the
-- cleaned form is what comparisons + concatenations expect. The speech
-- side (OutputMessageToScreenReader) re-strips automatically, which is
-- redundant but cheap.

local function loc(key)
    if key == nil or key == "" then return ""; end
    if Locale ~= nil and Locale.Lookup ~= nil then
        return stripIconTags(Locale.Lookup(key) or "");
    end
    return key;
end

-- Many LOC strings end with ":" because they're designed for visual layouts
-- like "Master Volume: 50" where the colon separates label from value field.
-- Spoken aloud with our ", value" suffix it becomes "Master Volume:, 50" —
-- jarring. Strip the trailing colon so speech reads "Master Volume, 50".
local function speakableLabel(item)
    local s = loc(item.labelKey);
    s = string.gsub(s, ":%s*$", "");
    return s;
end

local function getControl(name)
    if name == nil then return nil; end
    if Controls == nil then return nil; end
    return Controls[name];
end

local function isControlHidden(ctrl)
    if ctrl == nil then return true; end
    if ctrl.IsHidden ~= nil and ctrl:IsHidden() then return true; end
    return false;
end

local function isControlDisabled(ctrl)
    if ctrl == nil then return true; end
    if ctrl.IsDisabled ~= nil and ctrl:IsDisabled() then return true; end
    return false;
end

local function isItemUsable(item)
    if item == nil then return false; end
    local c = getControl(item.controlName);
    if c == nil then return false; end
    if isControlHidden(c) then return false; end
    if isControlDisabled(c) and item.kind ~= "button" then return false; end
    return true;
end

local function clampUnit(v)
    if v < 0 then return 0; end
    if v > 1 then return 1; end
    return v;
end

local function speak(text, continue)
    if text == nil or text == "" then return; end
    if OutputMessageToScreenReader ~= nil then
        OutputMessageToScreenReader(text, continue);
    end
end

-- ===========================================================================
--  Callback capture (engine slider / checkbox closures)
-- ===========================================================================
function OptionsAccess.RegisterSliderCallback(controlName, fn)
    if controlName == nil or fn == nil then return; end
    m_sliderCallbacks[controlName] = fn;
end

function OptionsAccess.RegisterCheckboxCallback(controlName, fn)
    if controlName == nil or fn == nil then return; end
    m_checkboxCallbacks[controlName] = fn;
end

local function fireSliderCallback(controlName, value)
    local cb = m_sliderCallbacks[controlName];
    if cb == nil then return; end
    local ok, err = pcall(cb, value);
    if not ok then
        print("[OptionsAccess] slider callback '" .. tostring(controlName) ..
              "' failed: " .. tostring(err));
    end
end

local function fireCheckboxCallback(controlName, value)
    local cb = m_checkboxCallbacks[controlName];
    if cb == nil then return; end
    local ok, err = pcall(cb, value);
    if not ok then
        print("[OptionsAccess] checkbox callback '" .. tostring(controlName) ..
              "' failed: " .. tostring(err));
    end
end

-- ===========================================================================
--  Item handlers (per kind)
-- ===========================================================================
-- Read the slider's current 0-1 value, preferring the widget over the
-- engine option. Civ VI Options is stage-and-confirm: callbacks fired with
-- SetAudioOption(..., value, 0) stage the change without committing.
-- Options.GetAudioOption returns the *committed* value, which won't move
-- during the edit session. The widget itself reflects the staged edit and
-- is synced to the committed value at screen show.
local function readSliderUnit(item)
    local c = getControl(item.controlName);
    if c ~= nil and c.GetValue ~= nil then
        local ok, v = pcall(function() return c:GetValue(); end);
        if ok and v ~= nil then return v; end
    end
    if item.audioKey ~= nil and Options ~= nil and Options.GetAudioOption ~= nil then
        local ok, v = pcall(Options.GetAudioOption, "Sound", item.audioKey);
        if ok and v ~= nil then return v / 100.0; end
    end
    return 0;
end

local function sliderValueText(item)
    -- If the slider has a companion value-display label (TODText next to
    -- TODSlider, ChatTextValue next to ChatTextSizeSlider, etc.), prefer
    -- the engine's formatted text — it's richer than a raw percentage
    -- ("9 PM" vs. "37 percent"). Falls back to percent when not present.
    if item.valueLabelControlName ~= nil then
        local lbl = getControl(item.valueLabelControlName);
        if lbl ~= nil and lbl.GetText ~= nil then
            local ok, txt = pcall(function() return lbl:GetText(); end);
            if ok and txt ~= nil and txt ~= "" then
                return stripIconTags(tostring(txt));
            end
        end
    end
    local v = readSliderUnit(item);
    local pct = math.floor((v or 0) * 100 + 0.5);
    return Locale.Lookup("LOC_CIVVIACCESS_VALUE_PERCENT", pct);
end

local function announceSlider(item)
    return Locale.Lookup("LOC_CIVVIACCESS_ITEM_VALUE", speakableLabel(item), sliderValueText(item));
end

local function adjustSlider(item, dir, big)
    local c = getControl(item.controlName);
    if c == nil or c.GetValue == nil or c.SetValue == nil then return; end
    local curUnit = readSliderUnit(item);
    local step = (big and (item.bigStep or STEP_BIG)) or (item.step or STEP_SMALL);
    local nextUnit = clampUnit(curUnit + step * dir);
    if nextUnit == curUnit then
        speak(announceSlider(item), false);
        return;
    end
    c:SetValue(nextUnit);
    fireSliderCallback(item.controlName, nextUnit);
    -- Re-announce. When valueLabelControlName is set, the slider's engine
    -- callback should have updated the label; sliderValueText picks that up.
    -- For audio sliders (no value label) we compute percent from nextUnit.
    if item.valueLabelControlName ~= nil then
        speak(announceSlider(item), false);
    else
        local pct = math.floor(nextUnit * 100 + 0.5);
        speak(Locale.Lookup("LOC_CIVVIACCESS_ITEM_VALUE",
            speakableLabel(item),
            Locale.Lookup("LOC_CIVVIACCESS_VALUE_PERCENT", pct)), false);
    end
end

local function activateSlider(item)
    speak(announceSlider(item), false);
end

local function announceCheckbox(item)
    local label = speakableLabel(item);
    -- Widget state first (reflects staged toggle), engine as fallback.
    local c = getControl(item.controlName);
    if c ~= nil and c.IsSelected ~= nil then
        local ok, sel = pcall(function() return c:IsSelected(); end);
        if ok and sel ~= nil then
            local stateKey = sel and "LOC_CIVVIACCESS_ITEM_CHECKED" or "LOC_CIVVIACCESS_ITEM_UNCHECKED";
            return Locale.Lookup(stateKey, label);
        end
    end
    if item.audioKey ~= nil and Options ~= nil and Options.GetAudioOption ~= nil then
        local ok, v = pcall(Options.GetAudioOption, "Sound", item.audioKey);
        if ok and v ~= nil then
            local stateKey = (v > 0) and "LOC_CIVVIACCESS_ITEM_CHECKED" or "LOC_CIVVIACCESS_ITEM_UNCHECKED";
            return Locale.Lookup(stateKey, label);
        end
    end
    return label;
end

local function activateCheckbox(item)
    local c = getControl(item.controlName);
    if c == nil or c.IsSelected == nil or c.SetSelected == nil then return; end
    local newState = not c:IsSelected();
    c:SetSelected(newState);
    fireCheckboxCallback(item.controlName, newState);
    speak(announceCheckbox(item), false);
end

local function announceButton(item)
    local c = getControl(item.controlName);
    local label = speakableLabel(item);
    if c ~= nil and isControlDisabled(c) then
        return Locale.Lookup("LOC_CIVVIACCESS_ITEM_UNAVAILABLE", label);
    end
    return label;
end

local function activateButton(item)
    local c = getControl(item.controlName);
    if c == nil then return; end
    local label = speakableLabel(item);
    if isControlDisabled(c) then
        speak(Locale.Lookup("LOC_CIVVIACCESS_ITEM_UNAVAILABLE", label), false);
        return;
    end
    speak(Locale.Lookup("LOC_CIVVIACCESS_ITEM_ACTIVATED", label), false);
    if item.activate ~= nil then
        item.activate();
    end
end

-- ===========================================================================
--  Pulldown handler
-- ===========================================================================
local function pulldownButtonText(item)
    local c = getControl(item.controlName);
    if c == nil then return ""; end
    local ok, btn = pcall(function() return c:GetButton(); end);
    if not ok or btn == nil then return ""; end
    local ok2, txt = pcall(function() return btn:GetText(); end);
    if not ok2 or txt == nil then return ""; end
    return stripIconTags(tostring(txt or ""));
end

local function announcePulldown(item)
    local label = speakableLabel(item);
    local val = pulldownButtonText(item);
    if val == "" then return label; end
    return Locale.Lookup("LOC_CIVVIACCESS_ITEM_VALUE", label, val);
end

local function findPulldownData(item)
    local c = getControl(item.controlName);
    if c == nil then return nil; end
    return m_pulldownData[tostring(c)];
end

local function entryLocalizedText(entry)
    if type(entry) ~= "table" then return ""; end
    local key = entry[1];
    if key == nil or Locale == nil or Locale.Lookup == nil then return ""; end
    return stripIconTags(Locale.Lookup(key) or "");
end

local function adjustPulldown(item, dir, big)
    local data = findPulldownData(item);
    if data == nil or data.values == nil or #data.values == 0 then
        -- Pulldown wasn't built through PopulateComboBox (some pulldowns
        -- like the language list are filled via a different code path).
        -- Re-announce so user knows the press registered.
        speak(announcePulldown(item), false);
        return;
    end
    local curText = pulldownButtonText(item);
    local curIdx = 1;
    for i, entry in ipairs(data.values) do
        if entryLocalizedText(entry) == curText then curIdx = i; break; end
    end
    local nextIdx = curIdx + dir;
    if nextIdx < 1 then nextIdx = #data.values; end
    if nextIdx > #data.values then nextIdx = 1; end
    if nextIdx == curIdx then
        speak(announcePulldown(item), false);
        return;
    end
    local nextEntry = data.values[nextIdx];
    local nextValue = (type(nextEntry) == "table") and nextEntry[2] or nextEntry;
    -- Update visible button label and fire the engine selection callback.
    pcall(function()
        local btn = data.control:GetButton();
        if btn ~= nil and btn.LocalizeAndSetText ~= nil and nextEntry[1] ~= nil then
            btn:LocalizeAndSetText(nextEntry[1]);
        end
    end);
    if data.callback ~= nil then
        pcall(data.callback, nextValue);
    end
    speak(Locale.Lookup("LOC_CIVVIACCESS_ITEM_VALUE", speakableLabel(item), entryLocalizedText(nextEntry)), false);
end

local function activatePulldown(item)
    -- Re-announce; the visual dropdown can be opened by mouse if user
    -- wants to scan many entries at once.
    speak(announcePulldown(item), false);
end

-- ===========================================================================
--  Editbox (announce-only)
-- ===========================================================================
local function announceEditbox(item)
    local label = speakableLabel(item);
    local c = getControl(item.controlName);
    if c == nil then return label; end
    local ok, txt = pcall(function() return c:GetText(); end);
    if not ok or txt == nil or txt == "" then
        return Locale.Lookup("LOC_CIVVIACCESS_ITEM_EMPTY", label);
    end
    return Locale.Lookup("LOC_CIVVIACCESS_ITEM_VALUE", label, stripIconTags(tostring(txt)));
end

local function activateEditbox(item)
    -- Text entry via screen-reader cursor isn't wired yet; user must
    -- mouse-click to enter the field and type. Flag this verbally.
    speak(announceEditbox(item) .. ". " .. Locale.Lookup("LOC_CIVVIACCESS_EDITBOX_MOUSE_HINT"), false);
end

local ITEM_HANDLERS = {
    slider   = { announce = announceSlider,   activate = activateSlider,   adjust = adjustSlider   },
    checkbox = { announce = announceCheckbox, activate = activateCheckbox                          },
    button   = { announce = announceButton,   activate = activateButton                            },
    pulldown = { announce = announcePulldown, activate = activatePulldown, adjust = adjustPulldown },
    editbox  = { announce = announceEditbox,  activate = activateEditbox                           },
};

-- ===========================================================================
--  Item lists (declarative)
-- ===========================================================================
-- Civ V Access's commonButtons() pattern: the bottom row (Reset / Confirm /
-- Close) is appended to every tab so it stays reachable from any tab. Reset
-- is hidden on the KeyBindings tab; isItemUsable filters it out there.

local function bottomButtons()
    return {
        { kind = "button", controlName = "ResetButton",
          labelKey = "LOC_SETUP_RESTORE_DEFAULT",
          activate = function() if OnReset    ~= nil then OnReset()    end end },
        { kind = "button", controlName = "ConfirmButton",
          labelKey = "LOC_GENERIC_CONFIRM_BUTTON",
          activate = function() if OnConfirm  ~= nil then OnConfirm()  end end },
        { kind = "button", controlName = "WindowCloseButton",
          labelKey = "LOC_MULTIPLAYER_BACK",
          activate = function() if OnCancel   ~= nil then OnCancel()   end end },
    };
end

-- audioKey: engine-side key under Options.GetAudioOption("Sound", ...) —
-- only the audio tab uses it. valueLabelControlName: companion label
-- control whose text we read for richer announce (TODText, ChatTextValue,
-- PlotToolTipDelayValue, ScrollSpeedValue, ScrollTextSpeedValue,
-- PerformanceValue, MemoryValue).

local AUDIO_ITEMS = {
    { kind = "slider",   controlName = "MasterVolSlider",   labelKey = "LOC_OPTIONS_MASTER_VOLUME",  audioKey = "Master Volume"   },
    { kind = "slider",   controlName = "MusicVolSlider",    labelKey = "LOC_OPTIONS_MUSIC_VOLUME",   audioKey = "Music Volume"    },
    { kind = "slider",   controlName = "SFXVolSlider",      labelKey = "LOC_OPTIONS_EFFECTS_VOLUME", audioKey = "SFX Volume"      },
    { kind = "slider",   controlName = "AmbVolSlider",      labelKey = "LOC_OPTIONS_AMBIENT_VOLUME", audioKey = "Ambience Volume" },
    { kind = "slider",   controlName = "SpeechVolSlider",   labelKey = "LOC_OPTIONS_SPEECH_VOLUME",  audioKey = "Speech Volume"   },
    { kind = "checkbox", controlName = "MuteFocusCheckbox", labelKey = "LOC_OPTIONS_MUTE_FOCUS",     audioKey = "Mute Focus"      },
};

local GAME_ITEMS = {
    { kind = "pulldown", controlName = "QuickCombatPullDown",                  labelKey = "LOC_OPTIONS_QUICK_COMBAT"                     },
    { kind = "pulldown", controlName = "QuickMovementPullDown",                labelKey = "LOC_OPTIONS_QUICK_MOVEMENT"                   },
    { kind = "pulldown", controlName = "AutoEndTurnPullDown",                  labelKey = "LOC_OPTIONS_AUTO_END_TURN"                    },
    { kind = "pulldown", controlName = "CityRangeAttackTurnBlockingPullDown",  labelKey = "LOC_OPTIONS_CITY_RANGE_ATTACK"                },
    { kind = "pulldown", controlName = "TunerPullDown",                        labelKey = "LOC_OPTIONS_TUNER"                            },
    { kind = "pulldown", controlName = "AutoDownloadPullDown",                 labelKey = "LOC_OPTIONS_AUTO_DOWNLOAD_ADDITIONAL_CONTENT" },
    { kind = "pulldown", controlName = "TutorialPullDown",                     labelKey = "LOC_OPTIONS_TUTORIAL"                         },
    { kind = "pulldown", controlName = "SaveFrequencyPullDown",                labelKey = "LOC_OPTIONS_TURNS_BETWEEN_AUTOSAVES"          },
    { kind = "pulldown", controlName = "SaveKeepPullDown",                     labelKey = "LOC_OPTIONS_AUTOSAVES_TO_KEEP"                },
    { kind = "slider",   controlName = "TODSlider",                            labelKey = "LOC_OPTIONS_TIME_OF_DAY",        valueLabelControlName = "TODText" },
    { kind = "checkbox", controlName = "TimeOfDayCheckbox",                    labelKey = "LOC_OPTIONS_TIME_OF_DAY_TEXT"                 },
    { kind = "editbox",  controlName = "LANPlayerNameEdit",                    labelKey = "LOC_OPTIONS_LAN_PLAYER_NAME"                  },
    { kind = "editbox",  controlName = "PBCTurnWebhookEdit",                   labelKey = "LOC_OPTIONS_WEBHOOK_URL"                      },
    { kind = "pulldown", controlName = "TurnWebhookFreqPullDown",              labelKey = "LOC_OPTIONS_WEBHOOK_FREQ"                     },
};

local GRAPHICS_ITEMS = {
    { kind = "pulldown", controlName = "AdapterPullDown",          labelKey = "LOC_OPTIONS_VIDEO_ADAPTER_TEXT"      },
    { kind = "checkbox", controlName = "MultiGPUCheckbox",         labelKey = "LOC_OPTIONS_VIDEO_MULTI_GPU_TEXT"    },
    { kind = "pulldown", controlName = "ResolutionPullDown",       labelKey = "LOC_OPTIONS_VIDEO_RESOLUTION_TEXT"   },
    { kind = "pulldown", controlName = "UIScalePulldown",          labelKey = "LOC_OPTIONS_VIDEO_UI_UPSCALE_TEXT"   },
    { kind = "pulldown", controlName = "FullScreenPullDown",       labelKey = "LOC_OPTIONS_VIDEO_WINDOW_MODE_TEXT"  },
    { kind = "pulldown", controlName = "MSAAPullDown",             labelKey = "LOC_OPTIONS_VIDEO_MSAA_TEXT"         },
    { kind = "slider",   controlName = "PerformanceSlider",        labelKey = "LOC_OPTIONS_VIDEO_PERFORMANCE_TEXT", valueLabelControlName = "PerformanceValue" },
    { kind = "slider",   controlName = "MemorySlider",             labelKey = "LOC_OPTIONS_VIDEO_MEMORY_TEXT",      valueLabelControlName = "MemoryValue"      },
    { kind = "button",   controlName = "AdvancedGraphicsOptions",  labelKey = "LOC_OPTIONS_SHOW_ADVANCED_GRAPHICS",
      activate = function() if OnToggleAdvancedOptions ~= nil then OnToggleAdvancedOptions(); end end },
    -- The Advanced subsection (shadows / lighting / terrain / water / etc.)
    -- is deliberately not enumerated yet — it's a per-session-state toggle
    -- and its controls only become visible after AdvancedGraphicsOptions is
    -- clicked. Follow-up to extend.
};

local LANGUAGE_ITEMS = {
    { kind = "pulldown", controlName = "DisplayLanguagePullDown", labelKey = "LOC_OPTIONS_DISPLAY_LANGUAGE" },
    { kind = "pulldown", controlName = "SpokenLanguagePullDown",  labelKey = "LOC_OPTIONS_SPOKEN_LANGUAGE"  },
    { kind = "checkbox", controlName = "EnableSubtitlesCheckbox", labelKey = "LOC_OPTIONS_SUBTITLES"        },
};

local INTERFACE_ITEMS = {
    { kind = "pulldown", controlName = "ClockFormat",                       labelKey = "LOC_OPTIONS_INTERFACE_CLOCK_FORMAT"          },
    { kind = "pulldown", controlName = "StartInStrategicView",              labelKey = "LOC_OPTIONS_STRATEGIC_VIEW_START"            },
    { kind = "pulldown", controlName = "MouseGrabPullDown",                 labelKey = "LOC_OPTIONS_INTERFACE_GRAB_MOUSE"            },
    { kind = "pulldown", controlName = "EdgeScrollPullDown",                labelKey = "LOC_OPTIONS_INTERFACE_EDGE_SCROLL"           },
    { kind = "pulldown", controlName = "AutoProdQueuePullDown",             labelKey = "LOC_OPTIONS_INTERFACE_OPEN_TO_PROD_QUEUE"    },
    { kind = "pulldown", controlName = "ReplaceDragWithClickPullDown",      labelKey = "LOC_OPTIONS_INTERFACE_FORCE_CLICK_TO_DRAG"   },
    { kind = "pulldown", controlName = "UnitCyclingPullDown",               labelKey = "LOC_OPTIONS_AUTO_UNIT_CYCLING"               },
    { kind = "pulldown", controlName = "RibbonStatsPullDown",               labelKey = "LOC_OPTIONS_RIBBON_STATS_LABEL"              },
    { kind = "slider",   controlName = "ChatTextSizeSlider",                labelKey = "LOC_OPTIONS_CHAT_TEXT_SIZE",       valueLabelControlName = "ChatTextValue"          },
    { kind = "slider",   controlName = "MinimapSizeSlider",                 labelKey = "LOC_OPTIONS_INTERFACE_MINIMAP_SIZE"          },
    { kind = "slider",   controlName = "PlotToolTipDelaySlider",            labelKey = "LOC_OPTIONS_PLOT_TOOLTIP_DELAY",   valueLabelControlName = "PlotToolTipDelayValue"  },
    { kind = "slider",   controlName = "ScrollSpeedSlider",                 labelKey = "LOC_OPTIONS_SCROLL_SPEED",         valueLabelControlName = "ScrollSpeedValue"       },
    { kind = "slider",   controlName = "ScrollTextSpeedSlider",             labelKey = "LOC_OPTIONS_SCROLL_TEXT_SPEED",    valueLabelControlName = "ScrollTextSpeedValue"   },
    { kind = "checkbox", controlName = "TouchInputCheckbox",                labelKey = "LOC_OPTIONS_TOUCH_ENABLED"                   },
    { kind = "checkbox", controlName = "HistoricMomentsAnimCheckbox",       labelKey = "LOC_OPTIONS_HISTORIC_MOMENT_ANIMATION"       },
    { kind = "pulldown", controlName = "PlayByCloudEndTurnBehavior",        labelKey = "LOC_OPTIONS_INTERFACE_PLAYBYCLOUD_END_TURN_BEHAVIOR" },
    { kind = "pulldown", controlName = "PlayByCloudClientReadyBehavior",    labelKey = "LOC_OPTIONS_INTERFACE_PLAYBYCLOUD_READY_BEHAVIOR"    },
    { kind = "pulldown", controlName = "ColorblindAdaptation",              labelKey = "LOC_OPTIONS_INTERFACE_COLOR_BLINDNESS_ADAPTATION"    },
    { kind = "pulldown", controlName = "RGBControl",                        labelKey = "LOC_OPTIONS_INTERFACE_LIGHTING"               },
};

local APPLICATION_ITEMS = {
    { kind = "pulldown", controlName = "ShowIntroPullDown",     labelKey = "LOC_OPTIONS_APP_SHOW_MOVIE"             },
    { kind = "checkbox", controlName = "WarnAboutModsCheckbox", labelKey = "LOC_OPTIONS_APP_WARN_MOD_COMPATIBILITY" },
};

-- KeyBindings tab is dynamic (rebind buttons + modal popup). Not yet
-- accessible — empty content array means only the bottom row is reachable.
local KEYBINDINGS_ITEMS = {};

local TAB_CONTENT_BY_PANEL = {
    GameOptions        = GAME_ITEMS,
    GraphicsOptions    = GRAPHICS_ITEMS,
    AudioOptions       = AUDIO_ITEMS,
    LanguageOptions    = LANGUAGE_ITEMS,
    InterfaceOptions   = INTERFACE_ITEMS,
    ApplicationOptions = APPLICATION_ITEMS,
    KeyBindings        = KEYBINDINGS_ITEMS,
};

-- ===========================================================================
--  Tab management
-- ===========================================================================
local function panelNameForTab(tabTuple)
    -- tabTuple is { buttonControl, panelControl, titleKey, hideResetFlag }
    -- We can't ask Civ VI for the control's ID directly; instead, identify by
    -- equality against Controls.<Name> references we know.
    local panel = tabTuple[2];
    if panel == nil then return nil; end
    for _, name in ipairs({
        "GameOptions", "GraphicsOptions", "AudioOptions",
        "InterfaceOptions", "ApplicationOptions",
        "LanguageOptions", "KeyBindings",
    }) do
        if Controls[name] == panel then return name; end
    end
    return nil;
end

local function buildTabItems()
    m_tabItems = {};
    for i, tab in ipairs(m_tabs) do
        local name = panelNameForTab(tab);
        local content = (name ~= nil and TAB_CONTENT_BY_PANEL[name]) or {};
        local items = {};
        for _, item in ipairs(content) do
            items[#items + 1] = item;
        end
        for _, btn in ipairs(bottomButtons()) do
            items[#items + 1] = btn;
        end
        m_tabItems[i] = items;
        m_itemIndex[i] = m_itemIndex[i] or 0;
    end
end

local function tabTitle(idx)
    local tab = m_tabs[idx];
    if tab == nil then return ""; end
    return loc(tab[3]);
end

local function firstUsableIndex(items, startAt, step)
    if items == nil or #items == 0 then return 0; end
    local n = #items;
    local i = startAt;
    for _ = 1, n do
        if i < 1 then i = n; end
        if i > n then i = 1; end
        if isItemUsable(items[i]) then return i; end
        i = i + step;
    end
    return 0;
end

local function announceCurrentItem(interrupt)
    local items = m_tabItems[m_tabIndex];
    if items == nil then return; end
    local idx = m_itemIndex[m_tabIndex] or 0;
    if idx < 1 or idx > #items then return; end
    local item = items[idx];
    local h = ITEM_HANDLERS[item.kind];
    if h == nil or h.announce == nil then return; end
    speak(h.announce(item), not interrupt);
end

local function announceTabHeader()
    local title = tabTitle(m_tabIndex);
    local items = m_tabItems[m_tabIndex];
    local populated = false;
    if items ~= nil then
        for _, it in ipairs(items) do
            if it.kind ~= "button" then populated = true; break; end
        end
    end
    if populated then
        speak(Locale.Lookup("LOC_CIVVIACCESS_TAB_HEADER", title), false);
    else
        speak(Locale.Lookup("LOC_CIVVIACCESS_TAB_STUB", title), false);
    end
end

-- ===========================================================================
--  Within-tab navigation
-- ===========================================================================
local function currentItems()
    return m_tabItems[m_tabIndex] or {};
end

local function moveBy(step)
    local items = currentItems();
    if #items == 0 then return; end
    local cur = m_itemIndex[m_tabIndex] or 0;
    if cur < 1 then cur = (step > 0) and 0 or (#items + 1); end
    local next = firstUsableIndex(items, cur + step, step);
    if next == 0 or next == cur then return; end
    m_itemIndex[m_tabIndex] = next;
    playNavSound();
    announceCurrentItem(true);
end

local function moveTo(idx)
    local items = currentItems();
    if idx < 1 or idx > #items then return; end
    local target = firstUsableIndex(items, idx, 1);
    if target == 0 or target == (m_itemIndex[m_tabIndex] or 0) then return; end
    m_itemIndex[m_tabIndex] = target;
    playNavSound();
    announceCurrentItem(true);
end

local function activateCurrent()
    local items = currentItems();
    local idx = m_itemIndex[m_tabIndex] or 0;
    local item = items[idx];
    if item == nil then return; end
    local h = ITEM_HANDLERS[item.kind];
    if h == nil or h.activate == nil then return; end
    h.activate(item);
end

local function adjustCurrent(dir, big)
    local items = currentItems();
    local idx = m_itemIndex[m_tabIndex] or 0;
    local item = items[idx];
    if item == nil then return; end
    local h = ITEM_HANDLERS[item.kind];
    if h == nil or h.adjust == nil then return; end
    h.adjust(item, dir, big);
end

-- ===========================================================================
--  Cross-tab navigation
-- ===========================================================================
local function switchToTab(idx)
    if idx < 1 or idx > #m_tabs then return; end
    if idx == m_tabIndex then return; end
    m_tabIndex = idx;
    -- Use the screen's own tab-switching logic so panel visibility, reset
    -- button hide flag, window title, and selection highlight all update.
    if OnSelectTab ~= nil then
        OnSelectTab(idx);
    end
    -- Reset focus to first usable item in new tab.
    local items = currentItems();
    local first = firstUsableIndex(items, 1, 1);
    m_itemIndex[m_tabIndex] = first;
    playNavSound();
    announceTabHeader();
    if first > 0 then
        local h = ITEM_HANDLERS[items[first].kind];
        if h ~= nil and h.announce ~= nil then
            speak(h.announce(items[first]), true);
        end
    end
end

local function nextTab(step)
    local n = #m_tabs;
    if n == 0 then return; end
    local target = m_tabIndex + step;
    if target < 1 then target = n; end
    if target > n then target = 1; end
    switchToTab(target);
end

-- ===========================================================================
--  Input handler
-- ===========================================================================
-- Civ VI's engine introspects input-handler parameter count and dispatches
-- accordingly: 1-param `(pInputStruct)` (Options.lua, most newer FrontEnd
-- screens) versus 3-param `(uiMsg, wParam, lParam)` (FrontEndPopup.lua,
-- MainMenu.lua era). For Options we use 1-param to match the engine's
-- InputHandler, so when the wrapper forwards args to the engine's
-- original handler, the struct passes through intact.
--
-- Modifier state: try struct methods (IsShiftDown / IsControlDown) first;
-- fall back to KeyDown/KeyUp-tracked state when the struct doesn't expose
-- them. The tracked state is also used to maintain the modifier flags
-- even when we don't have a struct in hand.

-- Civ VI's pInputStruct:IsShiftDown() is reliable on KeyDown/KeyUp pair
-- events but reports false on "navigation key" events (msg=2 for Tab/Esc).
-- The KeyDown/KeyUp tracker captures shift state correctly across both
-- message types, so we OR struct + tracked: if either says shift is down,
-- it's down.
local function shiftDownFrom(pInput)
    if pInput ~= nil and pInput.IsShiftDown ~= nil then
        local ok, v = pcall(function() return pInput:IsShiftDown(); end);
        if ok and v == true then return true; end
    end
    return m_shiftDown;
end

local function ctrlDownFrom(pInput)
    if pInput ~= nil and pInput.IsControlDown ~= nil then
        local ok, v = pcall(function() return pInput:IsControlDown(); end);
        if ok and v == true then return true; end
    end
    return m_ctrlDown;
end

-- Set true to log every key event we receive — diagnostic for input bugs.
-- Off now that Shift+Tab path is replaced with PageUp/PageDown (no modifier
-- dependency, no log noise to chase).
local DEBUG_INPUT :boolean = false;

function OptionsAccess.OnInput(pInputStruct)
    if pInputStruct == nil or pInputStruct.GetMessageType == nil then
        return false;
    end
    local uiMsg  = pInputStruct:GetMessageType();
    local wParam = pInputStruct:GetKey();

    if DEBUG_INPUT then
        local sh = (pInputStruct.IsShiftDown ~= nil) and tostring(pInputStruct:IsShiftDown()) or "no-method";
        local ct = (pInputStruct.IsControlDown ~= nil) and tostring(pInputStruct:IsControlDown()) or "no-method";
        print(string.format("OPTIONS_INPUT msg=%s key=%s struct_shift=%s struct_ctrl=%s tracked_shift=%s",
            tostring(uiMsg), tostring(wParam), sh, ct, tostring(m_shiftDown)));
    end

    -- Track modifier state on every key event regardless of screen so it
    -- stays correct across screen toggles and across action keys the
    -- engine might consume before the matching KeyUp arrives.
    if wParam == VK_SHIFT then
        if uiMsg == KEY_DOWN_MSG then
            -- Suppress Shift KD if we're inside the post-dispatch window
            -- (spurious bounce). The window is cleared on KU below.
            if nowSec() < m_shiftSuppressUntil then
                if DEBUG_INPUT then
                    print("SHIFT_KD_SUPPRESSED (bounce window)");
                end
                return false;
            end
            m_shiftDown = true;
        elseif uiMsg == KEY_UP_MSG then
            m_shiftDown = false;
            -- Real release breaks the suppression window — next KD is legitimate.
            m_shiftSuppressUntil = 0;
        end
        return false;
    end
    if wParam == VK_CONTROL then
        if uiMsg == KEY_DOWN_MSG then m_ctrlDown = true;
        elseif uiMsg == KEY_UP_MSG then m_ctrlDown = false; end
        return false;
    end

    -- Civ VI fires Tab and Esc as msg=2 navigation events (single message,
    -- no KeyDown/KeyUp pair) while letters / arrows / Enter / Space fire
    -- the normal pair. Accept both so Tab/Esc reach our dispatcher.
    if uiMsg ~= KEY_UP_MSG and uiMsg ~= 2 then return false; end
    if not m_screenOpen then return false; end

    local isTab = (wParam == VK_TAB) or (wParam == VK_TAB_NAV);
    if isTab then
        -- Tab is forward-only. Shift+Tab is unreliable in Civ VI's input
        -- pipeline (modifier state ghosts in ways our handler can't
        -- distinguish from real user holds), so PageUp is the backward path.
        if uiMsg ~= 2 then return true; end
        nextTab(1);
        return true;
    end

    -- PageUp / PageDown — the reliable tab nav keys. No modifier dependency.
    if wParam == VK_PRIOR then
        nextTab(-1);
        return true;
    end
    if wParam == VK_NEXT then
        nextTab(1);
        return true;
    end

    -- F1 — announce keyboard help. Text lives in ContextHelp.lua keyed by
    -- screen identifier so future screens can register their own help under
    -- the same API and localization later migrates in one place.
    if wParam == VK_F1 then
        ContextHelp.Speak("OPTIONS");
        return true;
    end
    if wParam == VK_UP then
        moveBy(-1);
        return true;
    end
    if wParam == VK_DOWN then
        moveBy(1);
        return true;
    end
    if wParam == VK_HOME then
        moveTo(1);
        return true;
    end
    if wParam == VK_END then
        moveTo(#currentItems());
        return true;
    end
    if wParam == VK_LEFT then
        -- Bigstep is gated on Ctrl, not Shift. Shift in Civ VI's input
        -- pipeline ghosts in ways we can't disambiguate from real holds
        -- (see PageUp/PageDown vs Shift+Tab discussion). Ctrl is reliable.
        adjustCurrent(-1, ctrlDownFrom(pInputStruct));
        return true;
    end
    if wParam == VK_RIGHT then
        adjustCurrent(1, ctrlDownFrom(pInputStruct));
        return true;
    end
    if wParam == VK_RETURN or wParam == VK_SPACE then
        activateCurrent();
        return true;
    end
    -- Escape: fall through. The fork wraps the engine's InputHandler so Esc
    -- reaches OnCancel via the original handler.
    return false;
end

-- ===========================================================================
--  Notifications from the Options.lua fork
-- ===========================================================================
local m_helpAnnouncedThisSession :boolean = false;

function OptionsAccess.NotifyShow()
    m_screenOpen = true;
    -- Reset modifier tracker to clean state. Prevents stuck-true shift/ctrl
    -- from a prior session (closed screen while modifier held → KeyUp never
    -- delivered to our handler → tracker stays true → modifier state stale).
    -- The next physical Shift/Ctrl press will re-set the tracker normally.
    m_shiftDown = false;
    m_ctrlDown  = false;
    m_shiftSuppressUntil = 0;
    -- m_tabs might not be populated yet on the very first show if the fork
    -- calls NotifyShow before Install; defensive rebuild.
    if #m_tabItems == 0 and #m_tabs > 0 then
        buildTabItems();
    end
    -- Sync our tab index with the screen's actual selection (defaults to 1).
    if m_tabIndex < 1 or m_tabIndex > #m_tabs then m_tabIndex = 1; end
    local items = currentItems();
    local first = m_itemIndex[m_tabIndex] or 0;
    if first < 1 then
        first = firstUsableIndex(items, 1, 1);
        m_itemIndex[m_tabIndex] = first;
    end
    announceTabHeader();
    if first > 0 then
        local h = ITEM_HANDLERS[items[first].kind];
        if h ~= nil and h.announce ~= nil then
            speak(h.announce(items[first]), true);
        end
    end
    -- One-time per session hint about navigation keys. The full key list is
    -- available via F1 from inside Options.
    if not m_helpAnnouncedThisSession then
        m_helpAnnouncedThisSession = true;
        speak(Locale.Lookup("LOC_CIVVIACCESS_OPTIONS_NAV_HINT"), true);
    end
end

function OptionsAccess.NotifyHide()
    m_screenOpen = false;
end

function OptionsAccess.NotifyTabSelected(idx)
    if idx == nil or idx == m_tabIndex then return; end
    m_tabIndex = idx;
end

-- ===========================================================================
--  Install + handler wrappers
-- ===========================================================================
-- Called from Options.lua's Initialize() with the screen's ContextPtr and a
-- reference to its m_tabs table (which we can't reach otherwise since it's
-- file-local in Options.lua).
--
-- This used to chain handlers via ctx:GetInputHandler() / GetShowHandler(),
-- but those getters don't exist on Civ VI's ContextPtr — chaining silently
-- no-op'd and we ended up replacing the engine's handlers. The fork now
-- builds wrapped handlers via WrapInput/WrapShow and re-registers them,
-- capturing the original function references at the call site.
function OptionsAccess.Install(ctx, tabs)
    m_tabs = tabs or {};
    buildTabItems();
end

function OptionsAccess.WrapInput(origInputFn)
    -- Single-parameter signature matches the engine's InputHandler in
    -- Options.lua so Civ VI's parameter-count-based dispatch passes the
    -- pInputStruct through to both our OnInput and the engine's handler.
    return function(pInputStruct)
        if OptionsAccess.OnInput(pInputStruct) then
            return true;
        end
        if origInputFn ~= nil then
            return origInputFn(pInputStruct);
        end
        return false;
    end
end

function OptionsAccess.WrapShow(origShowFn)
    return function()
        if origShowFn ~= nil then origShowFn(); end
        OptionsAccess.NotifyShow();
    end
end

function OptionsAccess.WrapHide(origHideFn)
    return function()
        if origHideFn ~= nil then origHideFn(); end
        OptionsAccess.NotifyHide();
    end
end
