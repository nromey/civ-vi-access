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
--   Ctrl+T  /  bare T         re-speak the announce
--   bare I                    read the full (long) visual description, if any
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
-- Civ VI's Keys table uses Keys.<LETTER> for letters (e.g. Keys.T), NOT
-- Keys.VK_T (which is nil) — only control keys use the VK_ prefix
-- (Keys.VK_RETURN etc.). ProductionPickerAddin uses Keys.T. The old
-- vk("VK_T") looked up the nil Keys.VK_T and fell back to a hardcoded 0x54
-- that matched an ARROW in Civ VI's key enum, not T — so arrows triggered
-- the re-read and T did nothing. Confirmed via Lua.log 2026-05-29.
local VK_T      = (Keys ~= nil and Keys.T) or 0x54;
local VK_I      = (Keys ~= nil and Keys.I) or 0x49;

-- ===========================================================================
--  Per-Context state (one popup open at a time per VM by construction)
-- ===========================================================================
local _state = nil;   -- nil = closed; table = open with {text, onClose, kind}

-- ===========================================================================
--  Public API
-- ===========================================================================

-- Default outro hint. Enter/Space/Esc all dismiss, but we tell the user
-- the simplest one.
local DEFAULT_DISMISS_HINT = "Press Enter to dismiss";

-- Assemble the spoken announce from structured parts, in the order Noel
-- specified 2026-05-29:
--   lead-in (type framing) → name → gameplay effects → short visual desc →
--   "Press I for the full <type> description" (ONLY if a long desc exists,
--    since there's no point offering I with nothing behind it) →
--   dismiss hint.
-- Any nil/empty segment is skipped. Icon tags are stripped downstream by
-- Speech.emit's stripIconTags, so no need to pre-strip here.
local function assembleAnnounce(opts)
    local parts = {};
    local function add(s)
        if s ~= nil and s ~= "" then parts[#parts + 1] = s; end
    end
    add(opts.leadIn);
    add(opts.name);
    add(opts.gameplay);
    add(opts.short);
    if opts.long ~= nil and opts.long ~= "" then
        local noun = opts.typeNoun;
        if noun ~= nil and noun ~= "" then
            add("Press I for the full " .. noun .. " description");
        else
            add("Press I for the full description");
        end
    end
    add(opts.dismissHint or DEFAULT_DISMISS_HINT);
    return table.concat(parts, ". ");
end

-- Call from the shadowed popup's show path. Speaks the assembled announce
-- immediately via Speech.emit (kind defaults to "critical" since these
-- popups block the player's flow and deserve interrupt-tier announce).
--
-- Structured opts (preferred):
--   leadIn   (string) — type framing, e.g. "Natural wonder discovered"
--   name     (string) — subject name, e.g. "Great Barrier Reef"
--   gameplay (string) — gameplay effects (the game's own Description text)
--   short    (string) — short visual description (describer _SHORT)
--   long     (string) — long visual description (describer _LONG); spoken on I.
--                       Its presence is what makes the "Press I" hint appear.
--   typeNoun (string) — noun for the press-I hint ("natural wonder", etc.)
--   dismissHint (string) — outro; default "Press Enter to dismiss"
--   onClose  (function) — engine close path (Enter / Space / Esc)
--   kind     (string) — open-announce Speech.emit kind, default "critical"
--
-- Legacy opt (still supported for un-migrated popups):
--   text     (string) — used verbatim as the announce; no assembly, no I key.
function RevealPopupAccess.NotifyShow(opts)
    if opts == nil then
        Log.warn("RevealPopupAccess.NotifyShow: opts required");
        return;
    end

    local announce;
    if opts.text ~= nil then
        announce = opts.text;            -- legacy verbatim path
    else
        announce = assembleAnnounce(opts);
    end
    if announce == nil or announce == "" then
        Log.warn("RevealPopupAccess.NotifyShow: nothing to announce");
        return;
    end

    _state = {
        text    = announce,              -- what T re-reads
        long    = opts.long,             -- what I speaks (may be nil)
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
    -- Emit as "selection" (the taxonomy's "popup landing" kind: pri 5,
    -- coalesce) NOT "status". An on-demand re-read must INTERRUPT and play
    -- on the keypress; "status" is NOINTERRUPT/queue, so it lagged behind
    -- the open-announce and drained late — which made a later keypress look
    -- like it triggered the re-read. "selection" interrupts (once past the
    -- open's critical shield) and coalesces (mashing T restarts, no pile-up).
    if key == VK_T then
        if _state.text ~= nil then
            Speech.emit(_state.text, "selection");
        end
        return true;
    end

    -- I: read the full (long) visual description on demand. Only consume the
    -- key if we actually have a long description; otherwise fall through so I
    -- isn't silently swallowed when there's nothing to read.
    if key == VK_I then
        if _state.long ~= nil and _state.long ~= "" then
            Speech.emit(_state.long, "selection");
            return true;
        end
        return false;
    end

    return false;
end

-- Convenience: tells the shadowed file whether we currently own a
-- visible popup. Useful for show / hide handlers that need to decide
-- whether to call NotifyClose.
function RevealPopupAccess.IsOpen()
    return _state ~= nil;
end

-- Look up a LOC key, returning nil when the string isn't defined. Civ VI's
-- Locale.Lookup returns the KEY itself for an undefined tag, so we treat
-- "result == key" (and empty) as missing. Popups use this to fetch their
-- describer-generated _SHORT / _LONG visual descriptions: until the
-- NaturalWonderDescriptions.xml / WorldWonderDescriptions.xml etc. ship,
-- these return nil, the announce omits the short line, and the "Press I"
-- hint stays hidden. Drop the XML in and they light up with zero code change.
function RevealPopupAccess.locOrNil(key)
    if key == nil or key == "" then return nil; end
    if Locale == nil or Locale.Lookup == nil then return nil; end
    local v = Locale.Lookup(key);
    if v == nil or v == "" or v == key then return nil; end
    return v;
end

-- ===========================================================================
--  Debug: raise a popup WITHOUT selecting its Lua state in FireTuner
-- ===========================================================================
-- FireTuner's Lua-state combo box isn't keyboard / screen-reader focusable,
-- so hand-selecting a popup's VM to call its raiser is impractical. Instead
-- each shadowed popup registers a raiser here; firing this cross-VM LuaEvent
-- from ANY focused state dispatches to whichever VM owns a raiser of that
-- name. From the tuner console (any state):
--
--   LuaEvents.CivViAccess_DebugRaisePopup("NaturalWonder")
--
-- Each popup VM that include()s this helper gets its own subscription and
-- its own _debugRaisers table; on fire, every VM's handler runs but only the
-- one holding the named raiser acts. Harmless in normal play (fires only on
-- an explicit external call). Strip or flag-gate before the final commit.
local _debugRaisers = {};

function RevealPopupAccess.RegisterDebugRaiser(name, fn)
    if name == nil or fn == nil then return; end
    _debugRaisers[name] = fn;
end

LuaEvents.CivViAccess_DebugRaisePopup.Add(function(name)
    local fn = _debugRaisers[name];
    if fn == nil then return; end   -- another VM owns this name (or none)
    local ok, err = pcall(fn);
    if not ok then
        Log.warn("RevealPopupAccess debug raise '" .. tostring(name)
                 .. "' failed: " .. tostring(err));
        return;
    end

    -- Force modality for testing. A synthetic raise isn't inside an engine
    -- event, so ExclusivePopupManager:Lock's UI.ReferenceCurrentEvent()
    -- returns 0 and Lock bails BEFORE its QueuePopup — the popup shows but
    -- never becomes the modal input context, so keys leak to World/HexCursor
    -- and HandleKey never fires. Replicate the QueuePopup + input-context push
    -- that Lock skipped, so the popup actually captures keys. (In real play
    -- the engine event makes Lock succeed and this is unnecessary.) The
    -- popup's own Close -> m_kPopupMgr:Unlock() does DequeuePopup + PopContext,
    -- tearing this down cleanly (one cosmetic id:0 DataError aside).
    if Input ~= nil and Input.PushActiveContext ~= nil and InputContext ~= nil then
        Input.PushActiveContext(InputContext.Reveal);
    end
    if UIManager ~= nil and ContextPtr ~= nil then
        local pri = (PopupPriority ~= nil and PopupPriority.High) or 0;
        UIManager:QueuePopup(ContextPtr, pri);
    end
end);

Log.info("RevealPopupAccess.lua: loaded");
