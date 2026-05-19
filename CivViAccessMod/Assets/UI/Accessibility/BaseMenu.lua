-- BaseMenu: declarative menu container for screen-reader navigation.
--
-- A screen builds a list of items (Button, Checkbox, Pulldown, Group; see
-- BaseMenuItems) and BaseMenu wires Up/Down/Home/End/Enter/Space/Left/Right/
-- Escape/F1 to a single cursor that walks the list, drills into groups, and
-- speaks each landing via OutputMessageToScreenReader.
--
-- Spec fields:
--   name          (string, required) identity for log lines / error traces.
--   displayName   (string, required) spoken once on screen activation.
--   items         (table | function) item list at level 1; a function is
--                 re-invoked on each show so a rebuilt list is picked up
--                 without re-installing.
--   preamble      (string | function returning string) optional. Spoken
--                 after displayName. A function preamble is re-readable via
--                 F1 so dynamic status text (e.g. "random world size, slot
--                 listing hidden") can refresh live.
--   onShow        fn(handler). Runs after priorShow / priorShowHide and
--                 before the cursor lands on the first item, so setItems
--                 calls land before the opening announce reads them.
--   priorShow     fn(bIsInit). Civ VI screens typically use
--                 SetShowHandler / SetHideHandler separately rather than
--                 the combined SetShowHideHandler; pass each named handler
--                 explicitly.
--   priorHide     fn(bIsInit).
--   priorShowHide fn(bIsHide, bIsInit). Alternative for screens that use
--                 the combined SetShowHideHandler. Ignored when priorShow
--                 / priorHide are provided.
--   priorInput    fn(pInputStruct) | fn(msg, wp, lp). Civ VI screens
--                 typically take an InputStruct table (pInputStruct:
--                 GetMessageType() / GetKey()); legacy screens may take
--                 the raw three-arg form. We pass through whatever the
--                 engine handed us, so the prior handler sees its native
--                 shape.
--
-- Navigation model:
--   Up/Down            previous / next item at the current level. Wraps at
--                      level 1; at deeper levels crosses out to the next
--                      sibling at the parent.
--   Home/End           first / last navigable item at the current level.
--   Enter/Space        drill into a Group; activate any other kind.
--   Right              same as Enter on a Group; no-op otherwise. (Sliders
--                      will adjust here when added.)
--   Left               at level > 1, back up a level. No-op at level 1.
--   Escape             clears a sub-menu (Pulldown) if open; otherwise at
--                      level > 1 backs up one level (same as Left); at
--                      level 1 falls through to priorInput so the engine's
--                      cancel wiring closes the screen.
--   F1                 re-speak displayName + preamble (re-evaluates a
--                      function preamble for live state).
--   Ctrl+T             re-speak the current item WITH its tooltip /
--                      parameter description appended. The default
--                      announce is terse (label + state); Ctrl+T pulls
--                      the long help on demand. Mirrors the layered-info
--                      idiom in NVDA / JAWS for verbose descriptions.
--
-- Sub-menus (Pulldown entry pickers) are modeled as a transient inline
-- handler at handler._activeSubMenu. While set, input routes to the sub
-- instead of the parent; the sub's own Enter / Esc clears it. This avoids a
-- separate HandlerStack module — Civ VI's per-screen ContextPtr already
-- owns input for the parent screen's lifetime.

include("ScreenReader")
include("Verbosity")

BaseMenu = {}

local KEY_UP_MSG = (KeyEvents ~= nil and KeyEvents.KeyUp) or 257

local NAV_SOUND_KEY = "Main_Menu_Mouse_Over"

local function playNavSound()
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound(NAV_SOUND_KEY)
    end
end

local function speak(text, nointerrupt)
    if text == nil or text == "" then
        return
    end
    OutputMessageToScreenReader(text, nointerrupt)
end

-- Resolve a preamble (string | function) at call time so F1 always reads
-- the latest value. Function preambles run under pcall so a broken hook
-- can't kill the menu.
local function resolvePreamble(handler)
    local p = handler.preamble
    if p == nil then
        return nil
    end
    if type(p) == "function" then
        local ok, result = pcall(p)
        if not ok then
            print("[BaseMenu '" .. handler.name .. "'] preamble fn failed: " .. tostring(result))
            return nil
        end
        return result
    end
    return p
end

-- Resolve items (table | function) at call time. A function spec lets a
-- screen rebuild its top-level list per-show without reinstalling, which
-- matters when controls are constructed dynamically by the engine
-- (AdvancedSetup's parameter framework rebuilds drivers on ruleset / mode
-- changes).
--
-- Cached for the duration of a single show. Invalidated on hide so the
-- next show re-runs the function. Without this cache, every cursor query
-- (which happens many times per arrow press — onUp/onDown each call
-- currentItems multiple times) re-executes the items function, which
-- in AdvancedSetup's case rebuilds 50+ ParameterCheckbox / Pulldown items
-- by iterating g_GameParameters.Parameters. The resulting print spam
-- floods Lua.log with non-speech lines between actual #SCREENREADER lines.
local function resolveItems(handler)
    if handler._cachedItems ~= nil then
        return handler._cachedItems
    end
    local spec = handler._itemsSpec
    local result
    if type(spec) == "function" then
        local ok, fnResult = pcall(spec)
        if not ok then
            print("[BaseMenu '" .. handler.name .. "'] items fn failed: " .. tostring(fnResult))
            result = {}
        else
            result = fnResult or {}
        end
    else
        result = spec or {}
    end
    handler._cachedItems = result
    return result
end

-- Walk the drill path to the items table at handler._level. Each parent
-- along the path must be a Group (has children()). A broken path (parent
-- removed, kind changed) returns an empty list so navigation degrades to
-- "nothing here" rather than NPE-ing.
local function itemsAtLevel(handler, level)
    local items = resolveItems(handler)
    for l = 1, level - 1 do
        local parent = items[handler._indices[l]]
        if parent == nil or type(parent.children) ~= "function" then
            return {}
        end
        items = parent:children()
    end
    return items
end

local function currentItems(handler)
    return itemsAtLevel(handler, handler._level)
end

local function currentIndex(handler)
    return handler._indices[handler._level] or 1
end

local function isNavigable(item)
    if item == nil then
        return false
    end
    if type(item.isNavigable) == "function" then
        return item:isNavigable()
    end
    return true
end

-- Find the next navigable index in `step` direction starting from `start`
-- (exclusive). Wraps when `wrap` is true (level 1 nav). At deeper levels
-- we don't wrap — falling past the end means "step out to the next sibling
-- group" and the caller handles that.
local function nextValidIndex(items, start, step, wrap)
    local n = #items
    if n == 0 then
        return nil
    end
    local i = start
    for _ = 1, n do
        i = i + step
        if i < 1 then
            if not wrap then
                return nil
            end
            i = n
        elseif i > n then
            if not wrap then
                return nil
            end
            i = 1
        end
        if isNavigable(items[i]) then
            return i
        end
    end
    return nil
end

-- Map a key value to its decimal digit 0-9, or nil if the key isn't a
-- digit. Handles both top-row (VK_0..VK_9 = 0x30..0x39) and numpad
-- (VK_NUMPAD0..VK_NUMPAD9 = 0x60..0x69) variants. Civ VI's Keys table
-- naming differs across screens for digit keys; comparing raw VK codes
-- sidesteps that.
local function digitFromKey(key)
    if key >= 48 and key <= 57 then return key - 48 end
    if key >= 96 and key <= 105 then return key - 96 end
    return nil
end

local function announceItem(handler, item, nointerrupt)
    if item == nil then
        return
    end
    -- Verbosity gate: chatty mode speaks describe() (label + value +
    -- tooltip / parameter description); terse speaks the lighter
    -- announce() and leaves description to Ctrl+T. Chatty only kicks in
    -- at L2+ — L1 parameter tooltips are mostly generic ("Choose the
    -- ruleset...") and add noise; the real win is inside drilled-in
    -- pulldowns where each entry's description is the only useful
    -- differentiator (leader, map type, world age, etc.).
    --
    -- "L2+" means either: drilled into a Group on this handler
    -- (_level > 1), OR we ARE a Pulldown sub-handler whose entries the
    -- user is arrowing through (_parent ~= nil — pushSubMenu creates a
    -- fresh handler with its own _level=1, so the parent-pointer is the
    -- only signal that we're in a sub), OR the screen opted in to
    -- always-chatty via spec.alwaysVerbose (pickers and other modals
    -- that the user reached BY drilling in from another screen — the
    -- handler itself starts at L1 but conceptually the whole screen is
    -- already a sub).
    --
    -- Fall back to announce() if describe is missing on this item kind.
    local verboseOn = Verbosity ~= nil and Verbosity.isOn()
    local deepEnough = (handler._level or 1) > 1
        or handler._parent ~= nil
        or handler.alwaysVerbose == true
    local useDescribe = verboseOn and deepEnough
        and type(item.describe) == "function"
    local ok, text = pcall(function()
        if useDescribe then
            return item:describe(handler)
        end
        return item:announce(handler)
    end)
    if not ok then
        print("[BaseMenu '" .. handler.name .. "'] announce failed: " .. tostring(text))
        return
    end
    speak(text, nointerrupt)
end

-- Edit-mode dispatch. When handler._editMode is set, this routes the
-- key event: digits append to the buffer, Backspace pops, Enter commits
-- via item:commitEdit(value), Esc cancels. Any other key is swallowed
-- so the user can type freely without accidentally triggering nav.
--
-- _editMode shape: { item, buffer (string), originalValue }. Buffer
-- starts empty so the user types a fresh value rather than editing the
-- existing string; arrow-step on Sliders covers the "small adjustment"
-- case. Empty buffer + Enter = cancel (no value to commit).
local function handleEditMode(handler, key)
    local em = handler._editMode
    if em == nil then return false end

    if key == Keys.VK_ESCAPE then
        handler._editMode = nil
        speak("cancelled", false)
        announceItem(handler, currentItems(handler)[currentIndex(handler)])
        return true
    end

    if key == Keys.VK_RETURN then
        if em.buffer == "" then
            handler._editMode = nil
            speak("cancelled", false)
        else
            local parsed = tonumber(em.buffer)
            handler._editMode = nil
            if parsed ~= nil and type(em.item.commitEdit) == "function" then
                em.item:commitEdit(parsed, handler)
            else
                speak("invalid value", false)
            end
        end
        announceItem(handler, currentItems(handler)[currentIndex(handler)])
        return true
    end

    if key == Keys.VK_BACK then
        if #em.buffer > 0 then
            em.buffer = em.buffer:sub(1, -2)
            speak(em.buffer == "" and "empty" or em.buffer, false)
        end
        return true
    end

    local digit = digitFromKey(key)
    if digit ~= nil then
        em.buffer = em.buffer .. tostring(digit)
        speak(tostring(digit), false)
        return true
    end

    -- Any other key while in edit mode is swallowed (no nav while editing).
    return true
end

local function moveToIndex(handler, newIndex)
    if newIndex == nil or newIndex == currentIndex(handler) then
        return
    end
    handler._indices[handler._level] = newIndex
    playNavSound()
    announceItem(handler, currentItems(handler)[newIndex])
end

local function drillInto(handler)
    local items = currentItems(handler)
    local group = items[currentIndex(handler)]
    if group == nil or group.kind ~= "group" then
        return
    end
    local children = group:children()
    local first = nextValidIndex(children, 0, 1, true)
    if first == nil then
        -- Empty group: re-speak the group label so the user gets feedback
        -- that nothing happened instead of silent failure.
        announceItem(handler, group)
        return
    end
    handler._level = handler._level + 1
    handler._indices[handler._level] = first
    playNavSound()
    announceItem(handler, children[first])
end

local function goBackLevel(handler)
    if handler._level <= 1 then
        return
    end
    handler._indices[handler._level] = nil
    handler._level = handler._level - 1
    playNavSound()
    announceItem(handler, currentItems(handler)[currentIndex(handler)])
end

-- Up/Down wrap within the current level at all depths. Earlier behavior
-- had L2+ cross-jump to sibling groups on past-end (Civ V Access
-- convention), but Noel found it confusing — drilling into Slot 1 and
-- arrowing down past its last param would silently land in Slot 2's
-- params. Strict scope is clearer: drill into a group, arrow up/down
-- wraps within it, Left to exit, then arrow to the next sibling and
-- drill explicitly.
local function onUp(handler)
    local items = currentItems(handler)
    moveToIndex(handler, nextValidIndex(items, currentIndex(handler), -1, true))
end

local function onDown(handler)
    local items = currentItems(handler)
    moveToIndex(handler, nextValidIndex(items, currentIndex(handler), 1, true))
end

local function onHome(handler)
    moveToIndex(handler, nextValidIndex(currentItems(handler), 0, 1, false))
end

local function onEnd(handler)
    local items = currentItems(handler)
    moveToIndex(handler, nextValidIndex(items, #items + 1, -1, false))
end

local function onEnter(handler)
    local items = currentItems(handler)
    local item = items[currentIndex(handler)]
    if item == nil or not isNavigable(item) then
        return
    end
    if item.kind == "group" then
        drillInto(handler)
        return
    end
    if type(item.isActivatable) == "function" and not item:isActivatable() then
        announceItem(handler, item)
        return
    end
    if type(item.activate) == "function" then
        local ok, err = pcall(function()
            item:activate(handler)
        end)
        if not ok then
            print("[BaseMenu '" .. handler.name .. "'] activate failed: " .. tostring(err))
        end
    end
end

local function onLeft(handler)
    local item = currentItems(handler)[currentIndex(handler)]
    if item ~= nil and type(item.adjust) == "function" then
        item:adjust(handler, -1)
        return
    end
    if handler._level > 1 then
        goBackLevel(handler)
    end
end

local function onRight(handler)
    local item = currentItems(handler)[currentIndex(handler)]
    if item == nil then
        return
    end
    if type(item.adjust) == "function" then
        item:adjust(handler, 1)
        return
    end
    if item.kind == "group" then
        drillInto(handler)
    end
end

-- Resolve displayName at speak time so screens whose name comes from a
-- runtime parameter (e.g. the multi-select picker, whose title depends
-- on which Array param launched it) can pass a function instead of a
-- frozen-at-install string.
local function resolveDisplayName(handler)
    local d = handler.displayName
    if type(d) == "function" then
        local ok, result = pcall(d)
        if ok and type(result) == "string" then
            return result
        end
        return ""
    end
    return d or ""
end

local function readHeader(handler)
    speak(resolveDisplayName(handler))
    local preamble = resolvePreamble(handler)
    if preamble ~= nil and preamble ~= "" then
        speak(preamble, true)
    end
end

-- Speak the current item with its tooltip / description appended. Used by
-- Ctrl+T to pull the long help on demand. Falls back to plain announce
-- when the item has no describe method (e.g. an item kind defined before
-- the describe API was added).
local function describeCurrent(handler)
    if handler._activeSubMenu ~= nil then
        describeCurrent(handler._activeSubMenu)
        return
    end
    local item = currentItems(handler)[currentIndex(handler)]
    if item == nil then return end
    local ok, text
    if type(item.describe) == "function" then
        ok, text = pcall(function() return item:describe(handler) end)
    else
        ok, text = pcall(function() return item:announce(handler) end)
    end
    if not ok then
        print("[BaseMenu '" .. handler.name .. "'] describe failed: " .. tostring(text))
        return
    end
    speak(text)
end

local function onActivate(handler)
    if not handler._initialized then
        handler._level = 1
        handler._indices = { 1 }
        local items = currentItems(handler)
        local first = nextValidIndex(items, 0, 1, false) or 1
        handler._indices[1] = first
        handler._initialized = true
        -- Debounce the first-open announce. Civ VI's screen-init sequence
        -- can fire ShowHide twice in rapid succession (engine refreshes
        -- the screen mid-setup), and the second fire clears _initialized
        -- via the hide handler then re-enters first-init here. Without
        -- the debounce we re-speak displayName with INTERRUPT mode and
        -- cut the first announcement mid-word (user heard "create create"
        -- on AdvancedSetup first-open).
        local now = (os and os.clock and os.clock()) or 0
        local sinceLastOpen = handler._lastOpenAnnounceAt
            and (now - handler._lastOpenAnnounceAt)
            or 1e9
        if sinceLastOpen < 0.5 then
            -- Recent open announce just fired; this is a spurious
            -- re-init. Skip the speech, keep the cursor reset.
            return
        end
        handler._lastOpenAnnounceAt = now
        readHeader(handler)
        announceItem(handler, items[first], true)
        return
    end
    -- Re-activation (sub-menu pop, return-from-modal). Validate the cursor
    -- — a Pulldown selection or post-activate hide can flip visibility.
    local items = currentItems(handler)
    local idx = currentIndex(handler)
    local item = items[idx]
    if item == nil or not isNavigable(item) then
        local next = nextValidIndex(items, (idx or 1) - 1, 1, false)
        if next == nil then
            return
        end
        handler._indices[handler._level] = next
        item = items[next]
    end
    announceItem(handler, item)
end

-- Dispatch a key event. Returns true if consumed. Routes to active sub-
-- menu first; otherwise to the parent bindings.
local function dispatchKey(handler, vk)
    if handler._activeSubMenu ~= nil then
        return dispatchKey(handler._activeSubMenu, vk)
    end
    if vk == Keys.VK_UP then
        onUp(handler); return true
    end
    if vk == Keys.VK_DOWN then
        onDown(handler); return true
    end
    if vk == Keys.VK_HOME then
        onHome(handler); return true
    end
    if vk == Keys.VK_END then
        onEnd(handler); return true
    end
    if vk == Keys.VK_RETURN or vk == Keys.VK_SPACE then
        onEnter(handler); return true
    end
    if vk == Keys.VK_LEFT then
        onLeft(handler); return true
    end
    if vk == Keys.VK_RIGHT then
        onRight(handler); return true
    end
    if vk == Keys.VK_F1 then
        readHeader(handler); return true
    end
    return false
end

-- Sub-menu management. A Pulldown that wants to capture input while its
-- entry list is open calls BaseMenu.pushSubMenu(parent, subSpec) and the
-- sub takes over key dispatch. Esc on the sub clears it back to the
-- parent. The sub is itself a BaseMenu handler with its own items, so the
-- same dispatch / announce / drill machinery applies.
function BaseMenu.pushSubMenu(parent, spec)
    local sub = BaseMenu.create(spec)
    sub._parent = parent
    parent._activeSubMenu = sub
    sub._initialized = false
    onActivate(sub)
    return sub
end

function BaseMenu.popSubMenu(sub)
    local parent = sub._parent
    if parent == nil then
        return
    end
    parent._activeSubMenu = nil
    -- Re-announce parent cursor so the user knows focus returned.
    announceItem(parent, currentItems(parent)[currentIndex(parent)])
end

-- Programmatic level-back. Used by item activate hooks (slot Remove
-- button) that destroy the current item and want the cursor to land on
-- the parent group after the activation.
function BaseMenu.goBackLevel(handler)
    goBackLevel(handler)
end

function BaseMenu.announceCurrent(handler)
    announceItem(handler, currentItems(handler)[currentIndex(handler)])
end

-- Drop the cached items list so the next nav re-runs the items spec
-- function. Use this when the underlying parameter set changes mid-show
-- (e.g. Civ VI's GameSetup_RefreshParameters fires after a ruleset
-- change). Companion code should call this from their chained
-- UI_PostRefreshParameters hook or equivalent.
function BaseMenu.invalidateItemsCache(handler)
    if handler == nil then return end
    handler._cachedItems = nil
end

function BaseMenu.create(spec)
    assert(type(spec) == "table", "BaseMenu.create needs spec table")
    assert(type(spec.name) == "string" and spec.name ~= "", "spec.name required")
    assert(
        (type(spec.displayName) == "string" and spec.displayName ~= "")
        or type(spec.displayName) == "function",
        "spec.displayName required (string or function returning string)")
    assert(spec.items ~= nil, "spec.items required (table or function)")

    local handler = {
        name = spec.name,
        displayName = spec.displayName,
        preamble = spec.preamble,
        alwaysVerbose = spec.alwaysVerbose == true,
        _itemsSpec = spec.items,
        _level = 1,
        _indices = { 1 },
        _initialized = false,
        _activeSubMenu = nil,
    }
    return handler
end

function BaseMenu.install(ContextPtr, spec)
    local handler = BaseMenu.create(spec)
    local priorShow = spec.priorShow
    local priorHide = spec.priorHide
    local priorShowHide = spec.priorShowHide
    local priorInput = spec.priorInput
    local onShow = spec.onShow

    ContextPtr:SetShowHideHandler(function(bIsHide, bIsInit)
        -- Chain the screen's prior wiring. Civ VI's convention is separate
        -- SetShowHandler / SetHideHandler with (bIsInit) signature; prefer
        -- those when supplied, else fall through to a combined ShowHide.
        --
        -- Risk: if the engine fires SetShowHandler / SetHideHandler
        -- independently from SetShowHideHandler (each slot dispatched
        -- separately), the prior handler will run TWICE — once on its
        -- own and once via our call below. Civ V Access used the same
        -- pattern in production so we adopt it here, but if AdvancedSetup
        -- observes double-OnShow effects, switch to a Notify pattern
        -- (companion exposes NotifyShow / NotifyHide that the fork calls
        -- explicitly) instead of capturing the prior handlers.
        if bIsHide then
            if priorHide ~= nil then
                pcall(priorHide, bIsInit)
            elseif priorShowHide ~= nil then
                pcall(priorShowHide, true, bIsInit)
            end
        else
            if priorShow ~= nil then
                pcall(priorShow, bIsInit)
            elseif priorShowHide ~= nil then
                pcall(priorShowHide, false, bIsInit)
            end
        end
        if bIsInit and bIsHide then
            -- Engine boot prime: screen isn't really visible, don't speak.
            return
        end
        if bIsHide then
            -- Reset so the next show re-announces header + first item from
            -- the top. Cursor state is recomputed on show. Drop the cached
            -- items list so the next show rebuilds (parameter values may
            -- have changed during the hide, e.g. user came back from a
            -- modal that toggled a game mode).
            handler._initialized = false
            handler._activeSubMenu = nil
            handler._editMode = nil
            handler._cachedItems = nil
            return
        end
        if onShow ~= nil then
            pcall(onShow, handler)
        end
        onActivate(handler)
    end)

    -- Civ VI passes a pInputStruct (userdata with GetMessageType / GetKey
    -- methods); legacy screens pass three numeric args (msg, wp, lp).
    -- Detect via the first arg's type: anything non-numeric is treated as
    -- a struct (covers both userdata and table forms). Initialize() may
    -- pass `true` as a second SetInputHandler arg ("consumeAll"); we
    -- honor that by always returning true on consumed messages.
    ContextPtr:SetInputHandler(function(...)
        local args = { ... }
        local msg, key
        local ctrlDown = false
        local altDown = false
        local pInputStruct
        if type(args[1]) == "number" then
            msg = args[1]
            key = args[2]
        else
            pInputStruct = args[1]
            if pInputStruct == nil then
                if priorInput ~= nil then return priorInput(...) end
                return false
            end
            local ok, m = pcall(function() return pInputStruct:GetMessageType() end)
            if not ok then
                if priorInput ~= nil then return priorInput(...) end
                return false
            end
            msg = m
            key = pInputStruct:GetKey()
            if type(pInputStruct.IsControlDown) == "function" then
                local cok, cdown = pcall(function() return pInputStruct:IsControlDown() end)
                if cok then ctrlDown = cdown == true end
            end
            if type(pInputStruct.IsAltDown) == "function" then
                local aok, adown = pcall(function() return pInputStruct:IsAltDown() end)
                if aok then altDown = adown == true end
            end
        end

        if msg ~= KEY_UP_MSG then
            if priorInput ~= nil then
                return priorInput(...)
            end
            return false
        end

        -- Edit-mode interception. While a NumberInput / Slider is in
        -- edit mode, digits / Backspace / Enter / Esc go to the edit
        -- handler; everything else is swallowed so the user can type
        -- without nav side effects.
        if handler._editMode ~= nil then
            return handleEditMode(handler, key)
        end

        if key == Keys.VK_ESCAPE then
            -- Sub-menu open: Esc cancels the sub without falling through.
            if handler._activeSubMenu ~= nil then
                BaseMenu.popSubMenu(handler._activeSubMenu)
                return true
            end
            -- Inside a drilled-down group: Esc pops one level (mirrors
            -- Left). Without this, Esc at any depth fell through to the
            -- engine's cancel and closed the whole screen, surprising
            -- users who expected one-level-up semantics.
            if handler._level and handler._level > 1 then
                goBackLevel(handler)
                return true
            end
            -- At L1: fall through to the screen's existing back / cancel
            -- wiring (Esc closes the screen, same as the engine default).
            if priorInput ~= nil then
                return priorInput(...)
            end
            return false
        end

        -- Ctrl+T: describe current item (label + state + tooltip / desc).
        -- Handled before dispatchKey because dispatchKey ignores modifiers.
        if ctrlDown and key == Keys.T then
            describeCurrent(handler)
            return true
        end

        -- Alt+V: toggle chatty / terse verbosity. Speak only the new mode
        -- and let the user's next arrow speak the item in that mode. An
        -- earlier version re-announced the current item immediately so
        -- the user "heard the difference," but that doubled the work per
        -- press and made rapid toggling feel laggy. The mode utterance
        -- alone is fast enough to toggle in quick succession.
        if altDown and key == Keys.V and Verbosity ~= nil then
            local on = Verbosity.toggle()
            speak(on and "Verbose on" or "Verbose off", false)
            return true
        end

        if dispatchKey(handler, key) then
            return true
        end

        if priorInput ~= nil then
            return priorInput(...)
        end
        return false
    end, true)

    return handler
end

return BaseMenu
