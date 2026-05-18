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
--   Escape             clears a sub-menu (Pulldown) if open; otherwise
--                      falls through to priorInput at any drill depth — Esc
--                      never walks back one level at a time. Use Left.
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

local function announceItem(handler, item, nointerrupt)
    if item == nil then
        return
    end
    local ok, text = pcall(function()
        return item:announce(handler)
    end)
    if not ok then
        print("[BaseMenu '" .. handler.name .. "'] announce failed: " .. tostring(text))
        return
    end
    speak(text, nointerrupt)
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

local function onUp(handler)
    local items = currentItems(handler)
    local cur = currentIndex(handler)
    if handler._level == 1 then
        moveToIndex(handler, nextValidIndex(items, cur, -1, true))
        return
    end
    local prev = nextValidIndex(items, cur, -1, false)
    if prev ~= nil then
        moveToIndex(handler, prev)
    else
        -- Past start: step out to previous sibling at parent level, last
        -- valid child.
        local parentLevel = handler._level - 1
        local parents = itemsAtLevel(handler, parentLevel)
        local newParentIdx = nextValidIndex(parents, handler._indices[parentLevel], -1, true)
        if newParentIdx == nil or parents[newParentIdx].kind ~= "group" then
            return
        end
        handler._indices[parentLevel] = newParentIdx
        local newItems = currentItems(handler)
        local target = nextValidIndex(newItems, #newItems + 1, -1, false)
        if target == nil then
            return
        end
        handler._indices[handler._level] = target
        playNavSound()
        speak(parents[newParentIdx]:announce(handler))
        announceItem(handler, newItems[target], true)
    end
end

local function onDown(handler)
    local items = currentItems(handler)
    local cur = currentIndex(handler)
    if handler._level == 1 then
        moveToIndex(handler, nextValidIndex(items, cur, 1, true))
        return
    end
    local nxt = nextValidIndex(items, cur, 1, false)
    if nxt ~= nil then
        moveToIndex(handler, nxt)
    else
        local parentLevel = handler._level - 1
        local parents = itemsAtLevel(handler, parentLevel)
        local newParentIdx = nextValidIndex(parents, handler._indices[parentLevel], 1, true)
        if newParentIdx == nil or parents[newParentIdx].kind ~= "group" then
            return
        end
        handler._indices[parentLevel] = newParentIdx
        local newItems = currentItems(handler)
        local target = nextValidIndex(newItems, 0, 1, false)
        if target == nil then
            return
        end
        handler._indices[handler._level] = target
        playNavSound()
        speak(parents[newParentIdx]:announce(handler))
        announceItem(handler, newItems[target], true)
    end
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

local function readHeader(handler)
    speak(handler.displayName)
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

function BaseMenu.create(spec)
    assert(type(spec) == "table", "BaseMenu.create needs spec table")
    assert(type(spec.name) == "string" and spec.name ~= "", "spec.name required")
    assert(type(spec.displayName) == "string" and spec.displayName ~= "", "spec.displayName required")
    assert(spec.items ~= nil, "spec.items required (table or function)")

    local handler = {
        name = spec.name,
        displayName = spec.displayName,
        preamble = spec.preamble,
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
        end

        if msg ~= KEY_UP_MSG then
            if priorInput ~= nil then
                return priorInput(...)
            end
            return false
        end

        if key == Keys.VK_ESCAPE then
            -- Sub-menu open: Esc cancels the sub without falling through.
            if handler._activeSubMenu ~= nil then
                BaseMenu.popSubMenu(handler._activeSubMenu)
                return true
            end
            -- Otherwise fall through to the screen's existing back / cancel
            -- wiring (Esc never walks back one level at a time — use Left).
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
