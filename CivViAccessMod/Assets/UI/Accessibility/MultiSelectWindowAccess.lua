-- Accessibility companion for the engine's generic multi-select picker
-- (Base\Assets\UI\FrontEnd\MultiSelectWindow.lua). This is the modal
-- AdvancedSetup launches via LuaEvents.MultiSelectWindow_Initialize for
-- Array-domain parameters whose Domain isn't special-cased to
-- CityStatePicker / LeaderPicker. Natural Wonders is the current
-- production user; future Array params with no custom picker would
-- also land here.
--
-- Lifecycle: user activates an Array-param button in AdvancedSetup,
-- AdvancedSetupAccess fires LuaEvents.MultiSelectWindow_Initialize
-- (matching the engine's open path) and unhides Controls.MultiSelectWindow.
-- We catch the same event to mirror the parameter's current selection
-- into our own _selected table, then BaseMenu builds an items list with
-- one VirtualCheckbox per value entry. Commit fires the engine's
-- existing LuaEvents.MultiSelectWindow_SetParameterValues so AdvancedSetup
-- writes the new selection into the parameter and updates the button
-- caption.

include("ScreenReader")
include("Verbosity")
include("BaseMenu")
include("BaseMenuItems")

local _parameter = nil
local _selected = {}
local _invertSelection = false
local _menuHandler = nil

-- Mirror the engine's m_SelectedValues from the parameter's current
-- Value array. parameter.Value here is the array of currently-selected
-- entries ({Value, Name, ...} each), distinct from parameter.Values
-- which is the full pickable list.
local function captureSelection(parameter)
    _parameter = parameter
    _invertSelection = parameter.UxHint == "InvertSelection"
    _selected = {}
    if parameter.Value ~= nil then
        for _, v in ipairs(parameter.Value) do
            _selected[v.Value] = true
        end
    end
    if _menuHandler ~= nil then
        BaseMenu.invalidateItemsCache(_menuHandler)
    end
end

-- Storage / display mapping: when UxHint=="InvertSelection", checking
-- the box means "exclude this entry" — so display = NOT stored. Keep
-- the storage table in engine semantics (true=included) so commit just
-- packs all-true keys into the values list.
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
        LuaEvents.MultiSelectWindow_SetParameterValues(_parameter.ParameterId, values)
    end
    ContextPtr:SetHide(true)
end

local function cancelAndClose()
    ContextPtr:SetHide(true)
end

local function buildItems()
    local items = {}
    if _parameter == nil then
        return items
    end
    for _, v in ipairs(_parameter.Values) do
        local entry = v
        items[#items + 1] = BaseMenuItems.VirtualCheckbox({
            labelFn = function() return Locale.Lookup(entry.Name or "") end,
            tooltipFn = function()
                return Locale.Lookup(entry.RawDescription or entry.Description or "")
            end,
            getValue = function() return isItemChecked(entry.Value) end,
            setValue = function(newOn) setItemChecked(entry.Value, newOn) end,
        })
    end
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

-- displayName and preamble both come from the parameter the engine
-- handed us via LuaEvents.MultiSelectWindow_Initialize. Both are
-- functions so they re-evaluate on each show (and on F1), picking up
-- whichever Array param the user just activated — Natural Wonders
-- today, future generic Array params later.
LuaEvents.MultiSelectWindow_Initialize.Add(captureSelection)

_menuHandler = BaseMenu.install(ContextPtr, {
    name = "MultiSelectWindow",
    displayName = function()
        if _parameter == nil then return "Picker" end
        return Locale.Lookup(_parameter.Name or "") or "Picker"
    end,
    preamble = function()
        if _parameter == nil then return "" end
        return Locale.Lookup(_parameter.Description or "")
    end,
    items = buildItems,
    -- The picker is itself a drilled-in modal — the user reached it by
    -- activating the Array-param button on the parent screen. Each
    -- entry's description is the only useful differentiator (which
    -- natural wonder is which) so chatty applies throughout, not gated
    -- behind a Group drill.
    alwaysVerbose = true,
})
