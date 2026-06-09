-- DiplomacyActionViewWrap.lua — IN-CONTEXT screen-reader wrap for the vanilla
-- DiplomacyActionView (the leader / first-contact / diplomacy screen).
--
-- WHY THIS EXISTS (the rebuild, 2026-06-04). The previous DiplomacyAccess was a
-- SEPARATE AddUserInterfaces context that QueuePopup'd a modal OVER the vanilla
-- DiplomacyActionView and competed with it for input. The vanilla screen's
-- OnInputHandler consumes EVERY key while visible (returns true for all KeyUp/
-- KeyDown, acts only on Escape), so our modal never received arrows until the
-- user pressed Escape once to close the vanilla screen. A layered context can
-- never be "first" — that competition WAS the "press Escape first" bug.
--
-- THE FIX (copied from Civ V Access's LeaderHeadRoot wrap): get our code INSIDE
-- the DiplomacyActionView context itself. The ruleset entry files
-- (DiplomacyActionViewAccess[_XP1/_XP2].lua) are registered via <ReplaceUIScript>
-- for the DiplomacyActionView LuaContext; each include()s the matching base /
-- Expansion1 / Expansion2 screen implementation (so its globals — OnInputHandler,
-- Controls, PopulateStatementList, ApplyStatement, OnSelect* — run in OUR VM and
-- the screen behaves exactly as Firaxis built it) and then include()s THIS file.
-- Here we:
--   • capture the screen's own OnInputHandler, redefine the global to a wrapper
--     that handles our nav keys and falls everything else through, then
--     re-register it with ContextPtr:SetInputHandler. OUR handler IS the screen's
--     input handler — first in line for every key. No modal, no popup stack, no
--     Escape. (Escape still falls through to the vanilla close.)
--   • wrap PopulateStatementList (the OVERVIEW action menu, used when you open
--     diplomacy with an already-met leader) and ApplyStatement (the CONVERSATION
--     replies, used on a real FIRST CONTACT and any AI-initiated talk) to build a
--     navigable model of the live option list and speak it. Selection routes back
--     through the engine's OWN dispatch (OnSelectInitialDiplomacyStatement /
--     handler.OnSelectionButtonClicked), so behaviour is correct across patches
--     and expansions for free.
--
-- See memory: reference_civ_v_diplomacy_input_pattern,
-- reference_civ_vi_diplomacy_input_wall, project_session_handoff_2026_06_04.

include("Log");
include("ScreenReader");
include("InputRouter");

-- ---------------------------------------------------------------------------
-- Sanity guard. If the screen implementation did not load into this VM (wrong
-- include in the entry file, capability disabled, etc.) the globals we wrap
-- won't exist — bail loudly rather than blow up the diplomacy screen.
-- ---------------------------------------------------------------------------
if type(OnInputHandler) ~= "function" or type(PopulateStatementList) ~= "function" then
    if Log ~= nil then
        Log.warn("DiploWrap: screen impl globals missing (OnInputHandler="
            .. type(OnInputHandler) .. ", PopulateStatementList="
            .. type(PopulateStatementList) .. ") — wrap NOT installed.");
    end
    return;
end

local MOD_NONE = InputRouter.MOD_NONE;
local MOD_CTRL = InputRouter.MOD_CTRL;

local VK_RETURN = (Keys ~= nil and Keys.VK_RETURN) or 0x0D;
local VK_SPACE  = (Keys ~= nil and Keys.VK_SPACE)  or 0x20;
local VK_ESCAPE = (Keys ~= nil and Keys.VK_ESCAPE) or 0x1B;
local VK_END    = (Keys ~= nil and Keys.VK_END)    or 0x23;
local VK_HOME   = (Keys ~= nil and Keys.VK_HOME)   or 0x24;
local VK_UP     = (Keys ~= nil and Keys.VK_UP)     or 0x26;
local VK_DOWN   = (Keys ~= nil and Keys.VK_DOWN)   or 0x28;
local VK_T      = (Keys ~= nil and Keys.VK_T)      or 0x54;

local KEY_UP = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257;

-- ---------------------------------------------------------------------------
-- Navigable option model. Shared by both the OVERVIEW (PopulateStatementList)
-- and CONVERSATION (ApplyStatement) capture paths; only one is on screen at a
-- time, and each capture rebuilds the list from scratch.
--   _items[i] = { label = spoken text, activate = fn(), disabled = bool }
-- ---------------------------------------------------------------------------
local _items       = {};
local _index       = 1;
local _rootControl = nil;   -- last OVERVIEW root, for the synthetic "Back" item

local function lookup(s)
    if s == nil then return ""; end
    local ok, v = pcall(function() return Locale.Lookup(s); end);
    return (ok and v ~= nil) and stripIconTags(v) or stripIconTags(tostring(s));
end

-- The leader's spoken line for the CURRENT statement. LeaderResponseText is the
-- conversation/greeting line; VoiceoverText is the first-meet cinematic fallback
-- (mirrors the paths LeaderMeetAnnounce used). Read in-context, so it's correct
-- for EVERY statement — the opening greeting AND every later response (e.g. the
-- leader's reply after you declare friendship), which the once-per-encounter
-- LeaderMeetAnnounce read could not cover.
local LEADER_LINE_CONTROLS = { "LeaderResponseText", "VoiceoverText" };

local function greetingText()
    if Controls == nil then return nil; end
    for _, name in ipairs(LEADER_LINE_CONTROLS) do
        local ctrl = Controls[name];
        if ctrl ~= nil and ctrl.GetText ~= nil then
            local ok, raw = pcall(function() return ctrl:GetText(); end);
            if ok and raw ~= nil then
                local clean = stripIconTags(raw);
                if clean ~= "" then return clean; end
            end
        end
    end
    return nil;
end

local function announceCurrent(kind)
    local item = _items[_index];
    if item == nil then return; end
    Speech.emit(item.label .. ", " .. _index .. " of " .. #_items, kind or "nav");
end

local function navTo(i)
    if #_items == 0 then return; end
    if i < 1 then i = 1; end
    if i > #_items then i = #_items; end
    _index = i;
    announceCurrent("nav");
end

local function activateCurrent()
    local item = _items[_index];
    if item == nil then return; end
    if item.disabled then
        Speech.emit(item.label, "meta");   -- label already carries the reason
        return;
    end
    if type(item.activate) ~= "function" then
        Speech.emit("That option can't be selected.", "meta");
        return;
    end
    Speech.emit("Selecting " .. item.label, "event");
    local ok, err = pcall(item.activate);
    if not ok then
        Speech.emit("Couldn't complete that selection.", "meta");
        Log.error("DiploWrap: activate failed for '" .. tostring(item.label)
            .. "': " .. tostring(err));
    end
end

local function rereadGreeting()
    local g = greetingText();
    if g ~= nil then
        Speech.emit(g, "status");
    else
        announceCurrent("nav");
    end
end

-- Build a spoken label for one engine selection (.Text + disabled reason).
local function labelFor(sel, disabled)
    local label = (sel.Text ~= nil) and lookup(sel.Text) or "option";
    if disabled then
        local reasons = {};
        if sel.FailureReasons ~= nil then
            for _, r in ipairs(sel.FailureReasons) do
                local rt = lookup(r);
                if rt ~= "" then reasons[#reasons + 1] = rt; end
            end
        end
        if #reasons > 0 then
            label = label .. ", unavailable: " .. table.concat(reasons, "; ");
        else
            label = label .. ", unavailable";
        end
    end
    return label;
end

-- Deferred list announce. The leader greeting (spoken by LeaderMeetAnnounce in a
-- DIFFERENT VM at "critical" on ShowLeaderScreen) lands a beat AFTER the options
-- are built here. Announcing immediately let the critical greeting clobber the
-- options before the reader spoke them (Noel heard the greeting, never the
-- options). So: build now, but wait a few frames on the screen's own SetUpdate
-- tick (the base screen doesn't use SetUpdate) and emit at "status" — which
-- always queues, never interrupts — so the greeting plays first, then the list.
local _pendingNoun   = nil;
local _pendingFrames = 0;
local _lastLine      = nil;   -- last leader line spoken this encounter (dedup)

local function speakList(noun)
    -- Prepend the leader's current spoken line so a response (greeting OR a reply
    -- to an action you just took) is heard, not just the option buttons. Deduped
    -- by text so a re-populate of the same screen doesn't repeat the line.
    local prefix = "";
    local line = greetingText();
    if line ~= nil and line ~= _lastLine then
        _lastLine = line;
        prefix = line .. " ";
    end
    if #_items == 0 then
        Speech.emit(prefix .. "No " .. (noun or "options") .. " available.", "status");
        return;
    end
    local first = _items[1];
    Speech.emit(prefix .. #_items .. " " .. (noun or "options") .. ". " .. first.label
        .. ", 1 of " .. #_items .. ". Up and down arrows to choose, Enter to select, Escape to leave.",
        "status");
end

local function onAnnounceUpdate()
    if _pendingNoun == nil then
        if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
        return;
    end
    _pendingFrames = _pendingFrames - 1;
    if _pendingFrames <= 0 then
        local noun = _pendingNoun;
        _pendingNoun = nil;
        if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
        speakList(noun);
    end
end

-- Reset selection to the top now (so any nav before the announce is sane), then
-- queue the spoken summary a few frames out so the greeting goes first.
local function scheduleAnnounce(noun)
    _index = 1;
    _pendingNoun = noun;
    _pendingFrames = 20;   -- ~0.3s at 60fps; lets both greeting lines emit first
    if ContextPtr ~= nil and ContextPtr.SetUpdate ~= nil then
        ContextPtr:SetUpdate(onAnnounceUpdate);
    else
        speakList(noun);   -- no tick available — announce now
    end
end

local function cancelAnnounce()
    _pendingNoun = nil;
    if ContextPtr ~= nil and ContextPtr.ClearUpdate ~= nil then ContextPtr:ClearUpdate(); end
end

-- ===========================================================================
-- OVERVIEW capture — wrap PopulateStatementList.
--
-- OVERVIEW_MODE is the action menu shown when you open diplomacy with a leader
-- you have already met (AddStatmentOptions → GetInitialStatementOptions →
-- PopulateStatementList(topOptions, rootControl, false)). Sub-lists (Discuss /
-- Casus Belli) come back through the same function with isSubList = true, via
-- the .Callback closures in the option list — so submenu navigation falls out
-- for free: opening one re-enters this wrap and rebuilds _items as the sublist.
--
-- .Callback options (submenus / custom) keep the engine's own closure as their
-- activate. .Key options route to OnSelectInitialDiplomacyStatement, except war
-- declarations, which we send through the engine's confirm popup so a stray
-- Enter can't start a war without a second, deliberate confirmation.
-- ===========================================================================
local BASE_PopulateStatementList = PopulateStatementList;

local function buildOverviewItem(sel)
    local disabled = (sel.IsDisabled == true);
    if g_bIsLocalPlayerTurn == false and sel.Key ~= nil then
        disabled = true;   -- engine disables real actions off-turn (PopulateStatementList)
    end
    local activate;
    if sel.Callback ~= nil then
        activate = sel.Callback;                       -- submenu open / custom
    elseif sel.Key ~= nil then
        local key = sel.Key;
        if type(IsWarChoice) == "function" and IsWarChoice(key)
           and type(GetWarType) == "function"
           and LuaEvents ~= nil and LuaEvents.DiplomacyActionView_ConfirmWarDialog ~= nil then
            activate = function()
                LuaEvents.DiplomacyActionView_ConfirmWarDialog(
                    ms_LocalPlayerID, ms_SelectedPlayerID, GetWarType(key));
            end;
        else
            activate = function() OnSelectInitialDiplomacyStatement(key); end;
        end
    end
    return { label = labelFor(sel, disabled), activate = activate, disabled = disabled };
end

function PopulateStatementList(options, rootControl, isSubList)
    -- Let the engine populate the real (mouse/visual) buttons unchanged.
    BASE_PopulateStatementList(options, rootControl, isSubList);

    -- The OVERVIEW action menu is only the live display when NO diplomacy session
    -- is active. On a first contact / conversation the overview panel still
    -- populates in the background (SelectPlayer → PopulatePlayerPanel runs before
    -- the mode switch), but the real list there is the CONVERSATION replies that
    -- ApplyStatement captures. ms_ActiveSessionID is set the moment a session
    -- opens (OnDiplomacyStatement) — gate on it so background overview populates
    -- neither clobber the conversation model nor speak over it.
    if ms_ActiveSessionID ~= nil then return; end

    local ok, err = pcall(function()
        _items = {};
        if not isSubList then _rootControl = rootControl; end
        if options ~= nil then
            for _, sel in ipairs(options) do
                _items[#_items + 1] = buildOverviewItem(sel);
            end
        end
        -- For a sub-list the engine adds a Cancel button inside its own loop;
        -- mirror it as a navigable "Back" that restores the top-level menu.
        if isSubList then
            _items[#_items + 1] = {
                label    = lookup("LOC_CANCEL_BUTTON"),
                disabled = false,
                activate = function()
                    if type(ShowOptionStack) == "function" then ShowOptionStack(false); end
                    if type(AddStatmentOptions) == "function" and _rootControl ~= nil then
                        AddStatmentOptions(_rootControl);   -- repopulates → rebuilds _items
                    end
                end,
            };
        end
    end);
    if not ok then
        Log.warn("DiploWrap: PopulateStatementList capture failed: " .. tostring(err));
        return;
    end

    -- The recursion from AddStatmentOptions (Back) re-announces the top list, and
    -- submenu opens re-announce the sub-list. Deferred so the greeting leads.
    scheduleAnnounce("options");
    Log.info("DiploWrap: OVERVIEW captured " .. #_items .. " options (subList="
        .. tostring(isSubList == true) .. ")");
end

-- ===========================================================================
-- CONVERSATION capture — wrap ApplyStatement.
--
-- This is the path a real FIRST CONTACT uses: the AI sends a greeting statement
-- (OnDiplomacyStatement → handler.ApplyStatement) and the reply options are
-- built into ConversationSelectionStack, each wired to
-- handler.OnSelectionButtonClicked(key) (= OnSelectConversationDiplomacyStatement
-- for the default handler). ApplyStatement is stashed onto every handler at
-- include time (StatementHandlers[x].ApplyStatement = ApplyStatement), so we must
-- redefine the global AND repoint the already-built handlers; handlers created
-- afterwards pick up the wrapped global automatically.
--
-- We re-run the same extract the engine just did to recover the selection KEYS
-- (they aren't stored on the controls), then activate through the handler's own
-- click dispatch. MAKE_DEAL is skipped — the deal screen is its own (deferred)
-- project and isn't a navigable reply list.
-- ===========================================================================
local BASE_ApplyStatement = ApplyStatement;

local function captureConversation(handler, sType, sSubType, toPlayer, kStatement)
    if sType == "MAKE_DEAL" then return; end          -- deal screen handled elsewhere
    if handler == nil or type(handler.ExtractStatement) ~= "function" then return; end

    local sels = nil;
    local ok = pcall(function()
        local mood = (type(GetStatementMood) == "function")
            and GetStatementMood(kStatement.FromPlayer, kStatement.FromPlayerMood) or nil;
        local parsed = handler.ExtractStatement(handler, sType, sSubType,
            kStatement.FromPlayer, mood, kStatement.Initiator);
        if parsed == nil then return; end
        -- "other" player = whoever in this exchange isn't us.
        local otherID = toPlayer;
        if kStatement.FromPlayer ~= nil and kStatement.FromPlayer ~= ms_LocalPlayerID then
            otherID = kStatement.FromPlayer;
        end
        if type(handler.RemoveInvalidSelections) == "function" then
            handler.RemoveInvalidSelections(parsed, ms_LocalPlayerID, otherID);
        end
        sels = parsed.Selections;
    end);
    if not ok or sels == nil then return; end

    -- Match the engine's one display filter: hide CHOICE_STOP_ASKING when the
    -- other player is human (DiplomacyActionView.lua ApplyStatement).
    local otherIsHuman = false;
    pcall(function()
        local oid = (kStatement.FromPlayer ~= ms_LocalPlayerID)
            and kStatement.FromPlayer or toPlayer;
        otherIsHuman = Players ~= nil and Players[oid] ~= nil and Players[oid]:IsHuman();
    end);

    _items = {};
    for _, sel in ipairs(sels) do
        local skip = (sel.Key == "CHOICE_STOP_ASKING" and otherIsHuman);
        if not skip then
            local disabled = (sel.IsDisabled == true);
            local key = sel.Key;
            _items[#_items + 1] = {
                label    = labelFor(sel, disabled),
                disabled = disabled,
                activate = function()
                    if type(handler.OnSelectionButtonClicked) == "function" then
                        handler.OnSelectionButtonClicked(key);
                    end
                end,
            };
        end
    end

    if #_items > 0 then
        scheduleAnnounce("replies");
        Log.info("DiploWrap: CONVERSATION captured " .. #_items
            .. " replies (statement=" .. tostring(sType) .. ")");
    end
end

local function WrappedApplyStatement(handler, sType, sSubType, toPlayer, kStatement)
    BASE_ApplyStatement(handler, sType, sSubType, toPlayer, kStatement);
    local ok, err = pcall(function()
        captureConversation(handler, sType, sSubType, toPlayer, kStatement);
    end);
    if not ok then
        Log.warn("DiploWrap: ApplyStatement capture failed: " .. tostring(err));
    end
end

ApplyStatement = WrappedApplyStatement;   -- direct callers (e.g. MakeDeal_ApplyStatement)
if type(StatementHandlers) == "table" then
    local repointed = 0;
    for _, h in pairs(StatementHandlers) do
        if type(h) == "table" and h.ApplyStatement == BASE_ApplyStatement then
            h.ApplyStatement = WrappedApplyStatement;
            repointed = repointed + 1;
        end
    end
    Log.info("DiploWrap: repointed ApplyStatement on " .. repointed .. " handler(s)");
end

-- ===========================================================================
-- Input — OUR handler IS the screen's. Handle nav keys; fall everything else
-- (including Escape, which the vanilla KeyHandler turns into a clean close)
-- through to the screen's original handler.
-- ===========================================================================
local BASE_OnInputHandler = OnInputHandler;

function OnInputHandler(pInputStruct)
    if pInputStruct ~= nil and pInputStruct:GetMessageType() == KEY_UP and #_items > 0 then
        local key  = pInputStruct:GetKey();
        local mods = InputRouter.modifierMaskFromInputStruct(pInputStruct);
        if mods == MOD_NONE then
            if     key == VK_UP    then navTo(_index - 1);  return true;
            elseif key == VK_DOWN  then navTo(_index + 1);  return true;
            elseif key == VK_HOME  then navTo(1);           return true;
            elseif key == VK_END   then navTo(#_items);     return true;
            elseif key == VK_RETURN or key == VK_SPACE then activateCurrent(); return true;
            end
            -- Escape (and anything else) falls through to the vanilla handler.
        elseif mods == MOD_CTRL and key == VK_T then
            rereadGreeting();
            return true;
        end
    end
    return BASE_OnInputHandler(pInputStruct);
end

ContextPtr:SetInputHandler(OnInputHandler, true);

-- Clear the model when the screen hides so a later re-open in a mode that
-- doesn't repopulate (e.g. a cinema) can't navigate a stale list.
if Events ~= nil and Events.HideLeaderScreen ~= nil then
    Events.HideLeaderScreen.Add(function()
        cancelAnnounce();   -- drop any pending announce so it can't fire on next open
        _items = {};
        _index = 1;
        _lastLine = nil;    -- new encounter re-announces the leader's line
    end);
end

Log.info("DiploWrap: installed (input handler wrapped + re-registered, "
    .. "PopulateStatementList + ApplyStatement captured)");
