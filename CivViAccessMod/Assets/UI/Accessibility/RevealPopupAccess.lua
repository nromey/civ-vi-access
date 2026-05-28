-- Generic reveal-popup accessibility helper.
--
-- Wraps the "Group A" popup family: header + body text + single
-- dismiss button. Pattern lifted from Civ V Access's BaseMenu.install
-- usage in CivVAccess_NaturalWonderPopupAccess.lua and friends, but
-- collapsed to the minimal surface our popups actually need (no item
-- list, no tabs, no choice — those go through ChoosePopupAccess).
--
-- Architecture: each shadowed popup file (Assets/UI/Popups/X.lua)
-- includes this helper, calls NotifyShow / NotifyClose at its show /
-- close hookpoints, and routes input through HandleKey before falling
-- through to the engine. Helper state is per-Context (each shadowed
-- popup's VM gets its own copy via include()), so multiple popups
-- using this helper don't collide.
--
-- Hook integration (shadowed popup adds ~6 lines):
--
--   include("RevealPopupAccess");
--
--   -- In whatever function builds + shows the popup:
--   RevealPopupAccess.NotifyShow({
--       text    = "Headline. Body text. Etc.",   -- what speaks on open
--       onClose = function() Close() end,        -- engine's close path
--       kind    = "critical",                    -- speech kind (default)
--   });
--
--   -- In Close / hide:
--   RevealPopupAccess.NotifyClose();
--
--   -- In OnInputHandler:
--   if RevealPopupAccess.HandleKey(pInputStruct) then return true; end
--
-- Key bindings (while a registered reveal popup is visible):
--   Enter / Space / Escape   activate onClose (dismiss)
--   Ctrl+T  /  bare T         re-speak the body
--
-- Bare-T is a deliberate concession to Civ VI's flaky Ctrl tracking
-- (see AdvisorPopupAccess.lua's Ctrl-state log). Reveal popups block
-- World input via UIManager:QueuePopup so the bare-letter conflict
-- with engine actions doesn't apply.

include("ScreenReader");
include("Log");

RevealPopupAccess = {};

-- ===========================================================================
--  Constants
-- ===========================================================================
local KE_KEY_UP = (KeyEvents ~= nil and KeyEvents.KeyUp) or 1;

local function vk(name, fallback)
    if Keys ~= nil and Keys[name] ~= nil then return Keys[name]; end
    return fallback;
end

local VK_RETURN = vk("VK_RETURN", 0x0D);
local VK_SPACE  = vk("VK_SPACE",  0x20);
local VK_ESCAPE = vk("VK_ESCAPE", 0x1B);
local VK_T      = vk("VK_T",      0x54);

-- ===========================================================================
--  Per-Context state (one popup open at a time per VM by construction)
-- ===========================================================================
local _state = nil;   -- nil = closed; table = open with {text, onClose, kind}

-- ===========================================================================
--  Public API
-- ===========================================================================

-- Call from the shadowed popup's show path. Speaks `text` immediately
-- via Speech.emit (kind defaults to "critical" since these popups
-- block the player's flow and deserve interrupt-tier announce).
--
-- opts:
--   text    (string, required) — what to speak on open
--   onClose (function, required) — invoked when user presses Enter / Esc
--   kind    (string, optional) — Speech.emit kind, default "critical"
function RevealPopupAccess.NotifyShow(opts)
    if opts == nil or opts.text == nil then
        Log.warn("RevealPopupAccess.NotifyShow: opts.text required");
        return;
    end
    _state = {
        text    = opts.text,
        onClose = opts.onClose,
        kind    = opts.kind or "critical",
    };
    Speech.emit(_state.text, _state.kind);
    Log.info("RevealPopupAccess.NotifyShow: open");
end

-- Call from the shadowed popup's Close / hide path.
function RevealPopupAccess.NotifyClose()
    if _state == nil then return; end
    _state = nil;
    Log.info("RevealPopupAccess.NotifyClose");
end

-- Returns true if the key was consumed. The shadowed input handler
-- should `return true` immediately when this returns true; otherwise
-- fall through to the engine's KeyHandler.
function RevealPopupAccess.HandleKey(pInputStruct)
    if _state == nil then return false; end
    if pInputStruct == nil then return false; end
    if pInputStruct.GetMessageType == nil then return false; end

    local uiMsg = pInputStruct:GetMessageType();
    if uiMsg ~= KE_KEY_UP then return false; end

    local key = pInputStruct:GetKey();

    -- Dismiss: Enter / Space / Esc all map to the engine's close path.
    if key == VK_RETURN or key == VK_SPACE or key == VK_ESCAPE then
        local onClose = _state.onClose;
        -- Clear state BEFORE firing close so onClose's hide handler
        -- (which calls NotifyClose) doesn't double-clear.
        _state = nil;
        if onClose ~= nil then
            local ok, err = pcall(onClose);
            if not ok then
                Log.warn("RevealPopupAccess.HandleKey: onClose failed: " .. tostring(err));
            end
        end
        return true;
    end

    -- Re-speak: Ctrl+T or bare T (Ctrl tracking is flaky in Civ VI).
    if key == VK_T then
        if _state.text ~= nil then
            Speech.emit(_state.text, "status");
        end
        return true;
    end

    return false;
end

-- Convenience: tells the shadowed file whether we currently own a
-- visible popup. Useful for show / hide handlers that need to decide
-- whether to call NotifyClose.
function RevealPopupAccess.IsOpen()
    return _state ~= nil;
end

Log.info("RevealPopupAccess.lua: loaded");
