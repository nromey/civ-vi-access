-- Accessibility companion for the engine's Leader picker modal
-- (Base\Assets\UI\FrontEnd\LeaderPicker.lua). Opened from AdvancedSetup
-- via `LuaEvents.LeaderPicker_Initialize(parameter, g_GameParameters)`
-- when the user activates the Leader Pool 1 or Leader Pool 2 Array
-- button at L1.
--
-- This is the richest of the three Array pickers because leader entries
-- carry leader name + civ name + leader ability + civ ability + uniques
-- — exactly the info a blind player needs to pick informedly. The
-- engine's GetPlayerInfo (PlayerSetupLogic.lua:546) handles all the
-- per-leader lookup and override application; we just call it and
-- format the result for speech.
--
-- v1 scope: list of leaders + Select All / Select None / OK / Back.
-- DEFERRED: the "leaders with no Hall-of-Fame wins" preset (engine
-- offers it as a third Preset pulldown entry; useful but niche, add
-- when someone asks).

include("ScreenReader")
include("Verbosity")
include("BaseMenu")
include("BaseMenuItems")

local _parameter = nil
local _pGameParameters = nil
local _selected = {}
local _invertSelection = false
local _menuHandler = nil
local _infoCache = {}

-- Wrap engine GetPlayerInfo (PlayerSetupLogic.lua) with a per-leader
-- cache keyed on Domain + Value. The engine doesn't cache; we do, so
-- repeated nav arrows don't re-hit the DB query.
local function getInfo(domain, value)
    local key = tostring(domain) .. "|" .. tostring(value)
    if _infoCache[key] == nil then
        _infoCache[key] = false
        if GetPlayerInfo ~= nil then
            local ok, info = pcall(GetPlayerInfo, domain, value)
            if ok and info ~= nil then
                _infoCache[key] = info
            end
        end
    end
    return _infoCache[key] or nil
end

-- Terse label for a leader entry: leader name + civ name. The engine
-- stores item.Name as the resolved leader name; we append civ name
-- from GetPlayerInfo so the user hears "Trajan, Rome" not just
-- "Trajan" (some leaders share a face across DLCs and the civ
-- disambiguates).
local function labelFor(entry)
    local info = getInfo(entry.Domain, entry.Value)
    local leader = (entry.Name and Locale.Lookup(entry.Name)) or "(unknown leader)"
    if info ~= nil and info.CivilizationName ~= nil then
        local civ = Locale.Lookup(info.CivilizationName)
        if civ ~= nil and civ ~= "" and civ ~= info.CivilizationName then
            return leader .. ", " .. civ
        end
    end
    return leader
end

-- Chatty payload: leader ability + civ ability + uniques. Reads on
-- arrow in chatty mode and on Ctrl+T regardless. Long but this is
-- the leader-pick screen — the descriptions are exactly the
-- differentiator the user needs.
local function tooltipFor(entry)
    local info = getInfo(entry.Domain, entry.Value)
    if info == nil then return "" end
    local parts = {}
    if info.LeaderAbility ~= nil then
        local name = info.LeaderAbility.Name and Locale.Lookup(info.LeaderAbility.Name) or ""
        local desc = info.LeaderAbility.Description and Locale.Lookup(info.LeaderAbility.Description) or ""
        if name ~= "" or desc ~= "" then
            parts[#parts + 1] = "Leader ability: " .. name .. ". " .. desc
        end
    end
    if info.CivilizationAbility ~= nil then
        local name = info.CivilizationAbility.Name and Locale.Lookup(info.CivilizationAbility.Name) or ""
        local desc = info.CivilizationAbility.Description and Locale.Lookup(info.CivilizationAbility.Description) or ""
        if name ~= "" or desc ~= "" then
            parts[#parts + 1] = "Civilization ability: " .. name .. ". " .. desc
        end
    end
    if info.Uniques ~= nil and #info.Uniques > 0 then
        local uniqueNames = {}
        for _, u in ipairs(info.Uniques) do
            if u.Name then
                uniqueNames[#uniqueNames + 1] = Locale.Lookup(u.Name)
            end
        end
        if #uniqueNames > 0 then
            parts[#parts + 1] = "Uniques: " .. table.concat(uniqueNames, ", ")
        end
    end
    return table.concat(parts, ". ")
end

-- Strip RANDOM / RANDOM_POOL1 / RANDOM_POOL2 from the parameter values.
-- Mirrors the engine's RemoveRandomLeadersFromParameter at
-- LeaderPicker.lua:164 — the engine drops these so the picker shows
-- only real leaders. The engine's ParameterInitialize calls this
-- before our captureSelection fires, but both AllValues and Values
-- get stripped; we re-strip defensively in case the order ever changes.
local function stripRandomLeaders(values)
    if values == nil then return end
    for i = #values, 1, -1 do
        local v = values[i].Value
        if v == "RANDOM" or v == "RANDOM_POOL1" or v == "RANDOM_POOL2" then
            table.remove(values, i)
        end
    end
end

local function captureSelection(parameter, pGameParameters)
    _parameter = parameter
    _pGameParameters = pGameParameters
    _invertSelection = parameter.UxHint == "InvertSelection"
    _selected = {}
    _infoCache = {}
    if parameter.Value ~= nil then
        for _, v in ipairs(parameter.Value) do
            _selected[v.Value] = true
        end
    end
    -- Defensive: engine strips already, but the order of LuaEvent
    -- subscribers isn't a guaranteed contract.
    if parameter.Values ~= nil then stripRandomLeaders(parameter.Values) end
    if _menuHandler ~= nil then
        BaseMenu.invalidateItemsCache(_menuHandler)
    end
end

local function isItemChecked(itemValue)
    local stored = _selected[itemValue] == true
    if _invertSelection then return not stored end
    return stored
end

local function setItemChecked(itemValue, newOn)
    local stored = newOn
    if _invertSelection then stored = not newOn end
    _selected[itemValue] = stored
end

local function setAll(displayState)
    if _parameter == nil then return end
    local stored = displayState
    if _invertSelection then stored = not displayState end
    for _, v in ipairs(_parameter.Values) do
        _selected[v.Value] = stored
    end
    if _menuHandler ~= nil then
        BaseMenu.invalidateItemsCache(_menuHandler)
    end
end

local function commitAndClose()
    if _parameter ~= nil then
        local values = {}
        for k, v in pairs(_selected) do
            if v then table.insert(values, k) end
        end
        LuaEvents.LeaderPicker_SetParameterValues(_parameter.ParameterId, values)
    end
    ContextPtr:SetHide(true)
end

local function cancelAndClose()
    ContextPtr:SetHide(true)
end

local function buildItems()
    local items = {}
    if _parameter == nil then return items end
    for _, v in ipairs(_parameter.Values) do
        local entry = v
        items[#items + 1] = BaseMenuItems.VirtualCheckbox({
            labelFn = function() return labelFor(entry) end,
            tooltipFn = function() return tooltipFor(entry) end,
            getValue = function() return isItemChecked(entry.Value) end,
            setValue = function(newOn) setItemChecked(entry.Value, newOn) end,
        })
    end
    -- Use LOC_SELECT_ALL / LOC_SELECT_NONE for cross-picker consistency
    -- with the City-States and Natural Wonders pickers (those resolve to
    -- "Select All" / "Select None"). The engine's leader-specific
    -- LOC_LEADER_PICK_PRESET_ALL / _NONE resolve to bare "All" / "None"
    -- since the engine wraps them in a "Preset" pulldown context where
    -- the noun is implicit; here they're standalone Buttons so we want
    -- the verb-and-noun form.
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_SELECT_ALL"),
        activate = function() setAll(true) end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_SELECT_NONE"),
        activate = function() setAll(false) end,
    })
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_OK_BUTTON"),
        activate = commitAndClose,
    })
    items[#items + 1] = BaseMenuItems.Button({
        labelText = Locale.Lookup("LOC_MULTIPLAYER_BACK"),
        activate = cancelAndClose,
    })
    return items
end

LuaEvents.LeaderPicker_Initialize.Add(captureSelection)

_menuHandler = BaseMenu.install(ContextPtr, {
    name = "LeaderPicker",
    displayName = function()
        if _parameter == nil then return "Leader Pool" end
        return Locale.Lookup(_parameter.Name or "") or "Leader Pool"
    end,
    preamble = function()
        if _parameter == nil then return "" end
        return Locale.Lookup(_parameter.Description or "")
    end,
    items = buildItems,
    alwaysVerbose = true,
})
