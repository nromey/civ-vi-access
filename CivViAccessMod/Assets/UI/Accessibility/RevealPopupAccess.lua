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
-- Key bindings (while a registered reveal popup is visible) — the shared
-- leader-briefing idiom (see LoadScreenAccess.lua's R/T/I/S), so every
-- popup answers the same four keys and it's one learned gesture:
--   Enter / Space / Escape   activate onClose (dismiss). If the popup holds a
--                             deferred cinematic (opts.playCinematic), the FIRST
--                             Enter/Space plays it instead, and Enter/Escape
--                             after that dismiss (Escape before = skip).
--   bare R                    repeat the whole open-announce
--   bare T                    re-read the abilities / mechanical block,
--                             when the popup supplies one (opts.abilities)
--   bare I                    read the full (long) visual description, if any
--   bare S                    read the transcript / "what was said", if any
--   bare G                    fire the popup's primary action (vanilla "Look At
--                             X" button — e.g. open the claim panel), then dismiss
--
-- Keys T / I / S only consume the press when the popup carries that facet;
-- otherwise they fall through. So the same key always means the same thing,
-- and a popup with no abilities simply has no T. Bare letters (not Ctrl-
-- modified) because Civ VI's Ctrl tracking is flaky (see AdvisorPopupAccess
-- Ctrl-state log). Reveal popups block World input via UIManager:QueuePopup
-- + an input-context push, so the bare-letter conflict with engine actions
-- doesn't apply.

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
local VK_R      = (Keys ~= nil and Keys.R) or 0x52;
local VK_S      = (Keys ~= nil and Keys.S) or 0x53;
local VK_G      = (Keys ~= nil and Keys.G) or 0x47;

-- ===========================================================================
--  Per-Context state (one popup open at a time per VM by construction)
-- ===========================================================================
local _state = nil;   -- nil = closed; table = open with {text, onClose, kind}

-- ===========================================================================
--  Public API
-- ===========================================================================

-- Join sentence fragments WITHOUT doubling terminal punctuation: the game's
-- gameplay text and the describer's short/long strings usually already end in
-- "." (and sometimes "!"/"?"), so a blind ". " join produced "...Campus
-- district.. A vast..." Trim each segment's trailing whitespace and, if it
-- already ends in sentence punctuation, separate with a single space;
-- otherwise add ". ". Shared by the popup assembler and AnnounceOnly.
local function joinSentences(parts)
    local out = {};
    local n = #parts;
    for i = 1, n do
        local p = parts[i]:gsub("%s+$", "");
        if i < n then
            if p:match("[%.%!%?]$") then p = p .. " "; else p = p .. ". "; end
        end
        out[#out + 1] = p;
    end
    return table.concat(out);
end

-- Build the trailing key-menu, advertising only the facets this popup
-- actually carries. R (repeat) and dismiss are always present; T / I / S
-- appear only when opts.abilities / opts.long / opts.transcript exist — so
-- the same key always means the same thing across popups, and one with no
-- abilities simply doesn't mention T. Mirrors LoadScreenAccess's hint line.
-- opts.keyHint overrides the whole thing; *Label opts override one phrase.
local function buildKeyHint(opts)
    local keys = { "R to repeat" };
    if opts.abilities ~= nil and opts.abilities ~= "" then
        keys[#keys + 1] = "T for " .. (opts.abilitiesLabel or "abilities");
    end
    if opts.long ~= nil and opts.long ~= "" then
        local noun = opts.longLabel;
        if noun == nil or noun == "" then
            noun = (opts.typeNoun ~= nil and opts.typeNoun ~= "")
                   and (opts.typeNoun .. " description") or "the full description";
        end
        keys[#keys + 1] = "I for " .. noun;
    end
    if opts.transcript ~= nil and opts.transcript ~= "" then
        keys[#keys + 1] = "S for " .. (opts.transcriptLabel or "what was said");
    end
    if opts.action ~= nil then
        keys[#keys + 1] = "G to " .. (opts.actionHint or "go to it");
    end
    -- When a deferred cinematic is present, Enter PLAYS it (then Enter/Escape
    -- dismiss); otherwise Enter/Escape dismiss. Sean-Bean pattern. We name
    -- ESCAPE alongside Enter because some reveal popups are queued at
    -- PopupPriority.Low (e.g. BoostUnlockedPopup) — bare Enter is the engine's
    -- end-turn gesture and gets grabbed by a higher input layer before the
    -- low-priority popup's handler sees it, so Enter can silently fail to
    -- dismiss while Escape (no engine gesture) reliably reaches us (Noel
    -- 2026-06-14: stuck on a Eureka popup, Enter did nothing, Escape worked).
    if opts.playCinematic ~= nil then
        keys[#keys + 1] = (opts.cinematicHint or "Enter to play");
    else
        keys[#keys + 1] = "Enter or Escape to dismiss";
    end
    return "Press " .. table.concat(keys, ", ") .. ".";
end

-- Assemble the spoken announce from structured parts, in the order Noel
-- specified 2026-05-29:
--   lead-in (type framing) → name → gameplay effects → short visual desc →
--   key-menu (R repeat / T abilities / I description / S transcript, only
--   the facets that exist; see buildKeyHint).
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
    add(opts.keyHint or buildKeyHint(opts));
    return joinSentences(parts);
end

-- Announce-only path for the DLC reveal listeners. Those popups are vanilla
-- DLC contexts we cannot shadow (user mods load before the DLC creates the
-- context — confirmed via Modding.log apply-order 2026-05-29), so instead a
-- listener addin subscribes to the same trigger events and just SPEAKS. No
-- popup state, no onClose, no "Press I" (short visual inline only, per Noel's
-- 2026-05-29 call). The vanilla popup still shows and owns its own dismiss;
-- the default outro names Escape, which those reveal popups reliably handle.
function RevealPopupAccess.AnnounceOnly(opts)
    if opts == nil then return; end
    local parts = {};
    local function add(s) if s ~= nil and s ~= "" then parts[#parts + 1] = s; end end
    add(opts.leadIn);
    add(opts.name);
    add(opts.gameplay);
    add(opts.short);
    add(opts.dismissHint or "Press Escape to dismiss");
    local text = joinSentences(parts);
    if text == nil or text == "" then return; end
    Speech.emit(text, opts.kind or "critical");
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
--   abilities(string) — abilities / mechanical block; spoken on T. For a hero
--                       this is the combat profile + passives + commands.
--   transcript(string)— quote / "what was said"; spoken on S (rare).
--   playCinematic (function) — a native cinematic / voiced quote held behind
--                       Enter (Sean-Bean): the FIRST Enter/Space plays it and
--                       the popup stays open; Enter/Escape after that dismiss.
--                       Escape BEFORE playing skips it. When set, the open hint
--                       says "Enter to play" instead of "Enter to dismiss".
--   stopCinematic (function) — torn down on dismiss IF the cinematic was played
--                       (stop camera/sound/restore mode). Optional.
--   cinematicHint (string) — the Enter phrase in the hint, e.g. "Enter to play
--                       the quote" / "Enter to watch the concert". Default
--                       "Enter to play".
--   action (function) — the popup's primary "look at / go to" action (the
--                       vanilla "Look At X" button); fired on G, then the modal
--                       dismisses (mirrors the vanilla button's Close()).
--   actionHint (string) — the G phrase in the hint, e.g. "claim it" → "G to
--                       claim it". Default "go to it".
--   typeNoun (string) — noun for the default I hint ("natural wonder", etc.)
--   abilitiesLabel / longLabel / transcriptLabel (string) — override the
--                       phrasing of one key in the hint ("appearance", etc.)
--   keyHint  (string) — override the ENTIRE trailing key-menu verbatim.
--   onClose  (function) — engine close path (Enter / Space / Esc)
--   kind     (string) — open-announce Speech.emit kind, default "critical"
-- Each of long / abilities / transcript also lights up its key (I/T/S);
-- absent facets leave their key unbound (the press falls through).
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
        text            = announce,         -- what R re-reads (whole announce)
        abilities       = opts.abilities,   -- what T re-reads (may be nil)
        long            = opts.long,        -- what I speaks (may be nil)
        transcript      = opts.transcript,  -- what S speaks (may be nil)
        playCinematic   = opts.playCinematic, -- first Enter plays this (may be nil)
        stopCinematic   = opts.stopCinematic, -- torn down on dismiss IF played
        cinematicPlayed = false,
        action          = opts.action,      -- G fires this then dismisses (may be nil)
        onClose         = opts.onClose,
        kind            = opts.kind or "critical",
    };
    Speech.emit(_state.text, _state.kind);
    Log.info("RevealPopupAccess.NotifyShow: open");
end

-- Call from the shadowed popup's Close / hide path.
function RevealPopupAccess.NotifyClose()
    if _state == nil then return; end
    _state = nil;
    Log.info("RevealPopupAccess.NotifyClose");
    -- Spoken dismiss confirmation. A reveal popup closing returns to the map,
    -- which does NOT re-announce, so without this the dismiss is silent (Noel
    -- 2026-06-14: "Escape made a sound with no speech feedback" — he couldn't
    -- tell the popup had closed). Terse + meta so a queued next popup's own
    -- critical announce still wins.
    if Speech ~= nil and Speech.emit ~= nil then
        Speech.emit("Dismissed", "meta");
    end
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

    -- Enter / Space / Esc. Deferred-cinematic gate (Sean-Bean pattern): if this
    -- popup has a cinematic that hasn't played yet, Enter/Space PLAYS it and we
    -- stay open; Escape skips straight to dismiss. Once it's played (or if
    -- there's no cinematic) all three dismiss — tearing the cinematic down on
    -- the way out if we started it.
    if key == VK_RETURN or key == VK_SPACE or key == VK_ESCAPE then
        -- Gate: first Enter/Space plays the held cinematic.
        if _state.playCinematic ~= nil and not _state.cinematicPlayed
           and (key == VK_RETURN or key == VK_SPACE) then
            _state.cinematicPlayed = true;
            local ok, err = pcall(_state.playCinematic);
            if not ok then
                Log.warn("RevealPopupAccess.HandleKey: playCinematic failed: " .. tostring(err));
            end
            return true;   -- stay open; next Enter/Esc dismisses
        end

        -- Dismiss. Clear state BEFORE firing close so onClose's hide handler
        -- (which calls NotifyClose) doesn't double-clear. Tear the cinematic
        -- down first if we actually started it.
        local onClose       = _state.onClose;
        local stopCinematic = (_state.cinematicPlayed and _state.stopCinematic) or nil;
        _state = nil;
        if stopCinematic ~= nil then
            local ok, err = pcall(stopCinematic);
            if not ok then
                Log.warn("RevealPopupAccess.HandleKey: stopCinematic failed: " .. tostring(err));
            end
        end
        if onClose ~= nil then
            local ok, err = pcall(onClose);
            if not ok then
                Log.warn("RevealPopupAccess.HandleKey: onClose failed: " .. tostring(err));
            end
        end
        return true;
    end

    -- Re-read keys (R/T/I/S) emit as "selection" (the taxonomy's "popup
    -- landing" kind: pri 5, coalesce) NOT "status". An on-demand re-read must
    -- INTERRUPT and play on the keypress; "status" is NOINTERRUPT/queue, so it
    -- lagged behind the open-announce and drained late — which made a later
    -- keypress look like it triggered the re-read. "selection" interrupts (once
    -- past the open's critical shield) and coalesces (mashing restarts cleanly).

    -- R: repeat the whole open-announce.
    if key == VK_R then
        if _state.text ~= nil and _state.text ~= "" then
            Speech.emit(_state.text, "selection");
        end
        return true;
    end

    -- T: re-read the abilities / mechanical block, if the popup supplied one.
    -- Fall through when absent so T isn't silently swallowed on a popup with
    -- no abilities facet.
    if key == VK_T then
        if _state.abilities ~= nil and _state.abilities ~= "" then
            Speech.emit(_state.abilities, "selection");
            return true;
        end
        return false;
    end

    -- I: read the full (long) visual description on demand.
    if key == VK_I then
        if _state.long ~= nil and _state.long ~= "" then
            Speech.emit(_state.long, "selection");
            return true;
        end
        return false;
    end

    -- S: read the transcript / "what was said", if any.
    if key == VK_S then
        if _state.transcript ~= nil and _state.transcript ~= "" then
            Speech.emit(_state.transcript, "selection");
            return true;
        end
        return false;
    end

    -- G: the popup's primary action (the vanilla "Look At X" button — e.g. open
    -- the claim panel). Fire it, then dismiss, matching the vanilla button which
    -- calls Close() after acting. Tear the cinematic down too if it was played.
    if key == VK_G then
        if _state.action ~= nil then
            local action        = _state.action;
            local onClose       = _state.onClose;
            local stopCinematic = (_state.cinematicPlayed and _state.stopCinematic) or nil;
            _state = nil;
            if stopCinematic ~= nil then pcall(stopCinematic); end
            local ok, err = pcall(action);
            if not ok then
                Log.warn("RevealPopupAccess.HandleKey: action failed: " .. tostring(err));
            end
            if onClose ~= nil then
                local ok2, err2 = pcall(onClose);
                if not ok2 then
                    Log.warn("RevealPopupAccess.HandleKey: onClose after action failed: " .. tostring(err2));
                end
            end
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
