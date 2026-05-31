-- Generic CHOICE-popup accessibility helper.
--
-- Sibling to RevealPopupAccess. Reveal popups are "read + dismiss" (one body of
-- text, Enter to close). CHOICE popups are "navigate + select": a list of
-- options, the player moves through them and commits one. This helper owns that
-- navigate-and-select interaction so each choice popup only has to (a) hand us
-- its option list and (b) tell us how to commit the chosen one.
--
-- First adopter: PantheonChooser (base-game, shadowable). Same shape covers the
-- other choosers (dedications, governments, great people, etc.) — they all
-- reduce to {list of options, each with name+description} + a commit callback.
--
-- KEY IDIOM (matches ProductionPickerAddin / our other pickers):
--   Up / Down          previous / next option (announces label + position)
--   Home / End         first / last option
--   bare T             re-read the current option's full description (terse
--                      default is label only; detail on demand)
--   Enter / Space      commit the current option (fires opts.onCommit(option))
--   Escape             cancel (fires opts.onCancel)
-- Arrow/letter keys are bare (no modifier) — the popup owns the keyboard while
-- open (the shadow's OnInputHandler routes here first), so there's no conflict
-- with world/engine bindings.
--
-- Integration in a shadowed chooser (~6 lines, mirrors RevealPopupAccess):
--   include("ChoosePopupAccess");
--   -- when the popup opens + its option list is built:
--   ChoosePopupAccess.Open({
--       title    = "Choose a pantheon belief",   -- spoken lead-in
--       options  = { {name=.., description=.., data=..}, ... },
--       onCommit = function(opt) ConfirmWith(opt.data) end,
--       onCancel = function() Close() end,
--       typeNoun = "belief",                      -- for hints ("12 beliefs")
--   });
--   -- in Close/hide:  ChoosePopupAccess.NotifyClose();
--   -- in OnInputHandler:  if ChoosePopupAccess.HandleKey(pInputStruct) then return true; end

include("ScreenReader");
include("Log");

ChoosePopupAccess = {};

-- ===========================================================================
--  Key constants (Civ VI Keys.* enum; fall back to raw VK codes)
-- ===========================================================================
local KE_KEY_UP = (KeyEvents ~= nil and KeyEvents.KeyUp) or 1;

local function vk(name, fallback)
    if Keys ~= nil and Keys[name] ~= nil then return Keys[name]; end
    return fallback;
end

local VK_RETURN = vk("VK_RETURN", 0x0D);
local VK_SPACE  = vk("VK_SPACE",  0x20);
local VK_ESCAPE = vk("VK_ESCAPE", 0x1B);
local VK_UP     = vk("VK_UP",     0x26);
local VK_DOWN   = vk("VK_DOWN",   0x28);
local VK_HOME   = vk("VK_HOME",   0x24);
local VK_END    = vk("VK_END",    0x23);
-- Letters use Keys.<LETTER>, not Keys.VK_<LETTER> (the latter is nil and the
-- fallback collides with arrows — root-caused in RevealPopupAccess 2026-05-29).
local VK_T      = (Keys ~= nil and Keys.T) or 0x54;
local VK_R      = (Keys ~= nil and Keys.R) or 0x52;

-- ===========================================================================
--  Per-Context state (one choice popup open at a time per VM)
-- ===========================================================================
local _state = nil;   -- nil = closed; else {options, index, onCommit, onCancel, title, typeNoun}

-- Strip icon/color tags is handled downstream by Speech.emit's stripIconTags.

-- Build the spoken line for the option at index i: "Name. position N of M."
local function optionAnnounce(i)
    local opt = _state.options[i];
    if opt == nil then return ""; end
    local parts = {};
    if opt.name ~= nil and opt.name ~= "" then parts[#parts + 1] = opt.name; end
    parts[#parts + 1] = tostring(i) .. " of " .. tostring(#_state.options);
    return table.concat(parts, ". ");
end

local function speak(text, kind)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then
        Speech.emit(text, kind or "selection");
    end
end

local function announceCurrent(kind)
    if _state == nil then return; end
    speak(optionAnnounce(_state.index), kind);
end

-- ===========================================================================
--  Public API
-- ===========================================================================

-- Open the choice popup. opts:
--   title    (string)  — spoken lead-in, e.g. "Choose a pantheon belief"
--   options  (array)   — { {name=, description=, data=}, ... }; data is opaque,
--                        handed back to onCommit.
--   onCommit (func)    — onCommit(option) when the player presses Enter/Space.
--   onCancel (func)    — onCancel() when the player presses Escape (optional).
--   typeNoun (string)  — noun for the count hint ("belief" -> "12 beliefs").
--   kind     (string)  — open-announce Speech kind (default "critical").
function ChoosePopupAccess.Open(opts)
    if opts == nil or opts.options == nil then
        Log.warn("ChoosePopupAccess.Open: options required");
        return;
    end
    _state = {
        title    = opts.title,
        options  = opts.options,
        index    = 1,
        onCommit = opts.onCommit,
        onCancel = opts.onCancel,
        typeNoun = opts.typeNoun,
    };

    -- Open announce: title + count + first option + key hint.
    local n = #_state.options;
    local parts = {};
    if _state.title ~= nil and _state.title ~= "" then parts[#parts + 1] = _state.title; end
    if n == 0 then
        parts[#parts + 1] = "No options available";
        speak(table.concat(parts, ". "), opts.kind or "critical");
        return;
    end
    local noun = _state.typeNoun or "option";
    local nounPlural = (n == 1) and noun or (noun .. "s");
    parts[#parts + 1] = tostring(n) .. " " .. nounPlural;
    parts[#parts + 1] = optionAnnounce(1);
    parts[#parts + 1] = "Use up and down arrows to choose, T for details, Enter to confirm, Escape to cancel";
    speak(table.concat(parts, ". "), opts.kind or "critical");
end

function ChoosePopupAccess.NotifyClose()
    if _state == nil then return; end
    _state = nil;
end

function ChoosePopupAccess.IsOpen()
    return _state ~= nil;
end

-- Move the selection by delta (wraps). Announces the new current option.
local function move(delta)
    if _state == nil or #_state.options == 0 then return; end
    local n = #_state.options;
    local i = _state.index + delta;
    if i < 1 then i = n; end
    if i > n then i = 1; end
    _state.index = i;
    announceCurrent("selection");
end

local function moveTo(i)
    if _state == nil or #_state.options == 0 then return; end
    _state.index = math.max(1, math.min(#_state.options, i));
    announceCurrent("selection");
end

-- Returns true if the key was consumed. Shadow's input handler should
-- `return true` when this returns true; else fall through to the engine.
function ChoosePopupAccess.HandleKey(pInputStruct)
    if _state == nil then return false; end
    if pInputStruct == nil or pInputStruct.GetMessageType == nil then return false; end
    if pInputStruct:GetMessageType() ~= KE_KEY_UP then return false; end

    local key = pInputStruct:GetKey();

    if key == VK_UP then
        move(-1); return true;
    elseif key == VK_DOWN then
        move(1); return true;
    elseif key == VK_HOME then
        moveTo(1); return true;
    elseif key == VK_END then
        moveTo(#_state.options); return true;
    end

    -- T (or R): re-read current option's full description.
    if key == VK_T or key == VK_R then
        local opt = _state.options[_state.index];
        if opt ~= nil then
            local parts = {};
            if opt.name ~= nil and opt.name ~= "" then parts[#parts + 1] = opt.name; end
            if opt.description ~= nil and opt.description ~= "" then parts[#parts + 1] = opt.description; end
            speak(table.concat(parts, ". "), "selection");
        end
        return true;
    end

    -- Enter / Space: commit the current option.
    if key == VK_RETURN or key == VK_SPACE then
        local opt = _state.options[_state.index];
        local onCommit = _state.onCommit;
        if opt == nil then return true; end
        speak("Confirming " .. (opt.name or "selection"), "selection");
        -- Clear state BEFORE firing commit so the shadow's Close (which calls
        -- NotifyClose) doesn't double-clear, and a re-open builds fresh.
        _state = nil;
        if onCommit ~= nil then
            local ok, err = pcall(onCommit, opt);
            if not ok then Log.warn("ChoosePopupAccess commit failed: " .. tostring(err)); end
        end
        return true;
    end

    -- Escape: cancel.
    if key == VK_ESCAPE then
        local onCancel = _state.onCancel;
        _state = nil;
        if onCancel ~= nil then
            local ok, err = pcall(onCancel);
            if not ok then Log.warn("ChoosePopupAccess cancel failed: " .. tostring(err)); end
        end
        return true;
    end

    return false;
end

Log.info("ChoosePopupAccess.lua: loaded");
