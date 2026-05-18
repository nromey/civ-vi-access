-- Item factories for BaseMenu. Each factory returns an item table with a
-- common method interface: isNavigable / isActivatable / announce /
-- activate / (optional adjust / children). The BaseMenu container calls
-- these methods without knowing the item kind, so new kinds slot in
-- without touching BaseMenu.
--
-- Common spec fields across all kinds:
--   control / controlName    Either a direct widget reference (for
--                            InstanceManager-built widgets with no stable
--                            Controls.X entry) or an XML id on Controls.
--   textKey / labelText      Label source: TXT/LOC key vs already-localized
--                            literal.
--   labelFn(control)         Dynamic label function; wins over text/labelText
--                            when present. Used when the label changes at
--                            runtime (current pulldown value, slot leader).
--   tooltipKey / tooltipText Static tooltip sources.
--   tooltipFn(control)       Dynamic tooltip function.
--   visibilityControlName    Optional widget whose IsHidden() also gates
--                            this item's navigability. Used for items
--                            whose visibility is driven by a sibling
--                            (e.g. RemoveButton tied to CivName visibility).

include("ScreenReader")

BaseMenuItems = {}

-- LOC fallbacks: if the strings file isn't loaded yet (initial development
-- before LOC keys land in CivVIAccessStrings.xml) the announcements still
-- speak sensibly. Locale.Lookup returns the key itself when unresolved, so
-- we detect that and substitute a literal.
local function loc(key, fallback, ...)
    if Locale == nil or Locale.Lookup == nil then
        return fallback
    end
    local t = Locale.Lookup(key, ...)
    if t == nil or t == "" or t == key then
        return fallback
    end
    return t
end

-- Label / tooltip resolution ------------------------------------------------

local function resolveLabel(item)
    if item.labelFn ~= nil then
        local ok, result = pcall(item.labelFn, item._control)
        if not ok then
            print("[BaseMenuItems labelFn '" .. tostring(item.controlName) .. "'] failed: " .. tostring(result))
            return ""
        end
        return result or ""
    end
    if item.labelText ~= nil then
        return item.labelText
    end
    if item.textKey ~= nil then
        return Locale.Lookup(item.textKey)
    end
    return ""
end

local function resolveTooltip(item)
    if item.tooltipFn ~= nil then
        local ok, result = pcall(item.tooltipFn, item._control)
        if not ok then
            print("[BaseMenuItems tooltipFn '" .. tostring(item.controlName) .. "'] failed: " .. tostring(result))
            return nil
        end
        if result == nil or result == "" then
            return nil
        end
        return tostring(result)
    end
    if item.tooltipText ~= nil and item.tooltipText ~= "" then
        return item.tooltipText
    end
    if item.tooltipKey == nil then
        return nil
    end
    local t = Locale.Lookup(item.tooltipKey)
    if t == nil or t == "" or t == item.tooltipKey then
        return nil
    end
    return t
end

-- Append a tooltip after the base announcement, dropping any sentence that
-- duplicates a comma-separated segment the user just heard. Multi-line
-- engine tooltips ([NEWLINE] tokens) become period-joined so each line
-- gets a readable pause.
local function appendTooltip(base, tooltip)
    if tooltip == nil or tooltip == "" then
        return base
    end
    if base == nil or base == "" then
        return tooltip
    end
    tooltip = tooltip:gsub("%[NEWLINE%]", ". ")
    local seen = {}
    for segment in string.gmatch(base, "([^,]+)") do
        local trimmed = segment:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            seen[trimmed] = true
        end
    end
    -- Split on period-followed-by-whitespace so abbreviations / decimals
    -- ("1.06") inside a segment survive.
    local marked = tooltip:gsub("%.%s+", "\0")
    local novel = {}
    for sentence in string.gmatch(marked, "([^%z]+)") do
        local trimmed = sentence:match("^%s*(.-)%s*$")
        trimmed = trimmed:gsub("%.$", "")
        if trimmed ~= "" and not seen[trimmed] then
            novel[#novel + 1] = trimmed
        end
    end
    if #novel == 0 then
        return base
    end
    -- Avoid double terminal punctuation when base already ends with one.
    local sep = base:match("[%.%!%?%:%;%,]%s*$") and " " or ". "
    return base .. sep .. table.concat(novel, ". ")
end

BaseMenuItems.appendTooltip = appendTooltip
BaseMenuItems.resolveLabel = resolveLabel
BaseMenuItems.resolveTooltip = resolveTooltip

-- Shared isNavigable / isActivatable for control-backed items.
local function isNavigable(self)
    if self._control == nil then
        return false
    end
    if self._control.IsHidden ~= nil and self._control:IsHidden() then
        return false
    end
    if self._visibilityControl ~= nil and self._visibilityControl.IsHidden ~= nil and self._visibilityControl:IsHidden() then
        return false
    end
    return true
end

local function isActivatable(self)
    if not isNavigable(self) then
        return false
    end
    if self._control.IsDisabled ~= nil and self._control:IsDisabled() then
        return false
    end
    return true
end

-- composeSpeech assembles label + state + disabled tag. Tooltip / parameter
-- description is intentionally NOT appended here — Civ VI parameter
-- descriptions are multi-paragraph (game modes, victory conditions) and
-- including them by default means fast arrow nav interrupts speech
-- mid-tooltip. The user gets the terse "label, state" announce; describe-
-- on-demand (Ctrl+T on the BaseMenu) pulls the full description when
-- wanted. See project_info_hotkeys in memory.
local function composeSpeech(item, parts)
    if type(item.isActivatable) == "function" and not item:isActivatable() then
        parts[#parts + 1] = loc("LOC_CIVVIACCESS_DISABLED", "disabled")
    end
    return table.concat(parts, ", ")
end

-- describeSpeech is the on-demand version: composeSpeech + the tooltip /
-- description appended. Used by Ctrl+T.
local function describeSpeech(item, parts)
    local base = composeSpeech(item, parts)
    return appendTooltip(base, resolveTooltip(item))
end

BaseMenuItems.composeSpeech = composeSpeech
BaseMenuItems.describeSpeech = describeSpeech

-- Resolution helpers --------------------------------------------------------

local function resolveControl(spec, kind)
    if spec.control ~= nil then
        return spec.control
    end
    if type(spec.controlName) ~= "string" then
        -- Quiet when this item is parameter-backed (parameter-mode
        -- Pulldown / ParameterCheckbox don't need a Controls.X widget —
        -- the parameter object IS the backing). Civ VI parameter-driven
        -- screens build their controls dynamically and there's no stable
        -- name to bind to. The warning is still useful for legacy items
        -- that should have one.
        if spec.parameter == nil then
            print("[BaseMenuItems " .. kind .. "] needs control or controlName")
        end
        return nil
    end
    local c = Controls[spec.controlName]
    if c == nil then
        print("[BaseMenuItems " .. kind .. "] missing control '" .. spec.controlName .. "'")
    end
    return c
end

local function resolveVisibilityControl(spec)
    if spec.visibilityControl ~= nil then
        return spec.visibilityControl
    end
    if type(spec.visibilityControlName) == "string" then
        return Controls[spec.visibilityControlName]
    end
    return nil
end

local function copyCommonFields(spec, item)
    item.controlName = spec.controlName
    item.textKey = spec.textKey
    item.labelText = spec.labelText
    item.labelFn = spec.labelFn
    item.tooltipKey = spec.tooltipKey
    item.tooltipText = spec.tooltipText
    item.tooltipFn = spec.tooltipFn
end

-- Generic describe: append the item's tooltip to its terse announce.
-- Items that have no special describe behavior get this attached after
-- their announce method is set. Used by BaseMenu's Ctrl+T binding.
local function genericDescribe(self, menu)
    local terse = self:announce(menu)
    local tooltip = resolveTooltip(self)
    if tooltip == nil or tooltip == "" then
        return terse
    end
    return appendTooltip(terse, tooltip)
end

BaseMenuItems.genericDescribe = genericDescribe

-- Button --------------------------------------------------------------------

function BaseMenuItems.Button(spec)
    assert(type(spec.activate) == "function", "Button needs activate fn")
    local item = {
        kind = "button",
        _control = resolveControl(spec, "Button"),
        _visibilityControl = resolveVisibilityControl(spec),
        _activate = spec.activate,
    }
    copyCommonFields(spec, item)
    item.isNavigable = isNavigable
    item.isActivatable = isActivatable
    function item:announce(menu)
        return composeSpeech(self, { resolveLabel(self) })
    end
    item.describe = genericDescribe
    function item:activate(menu)
        local ok, err = pcall(self._activate)
        if not ok then
            print("[BaseMenu '" .. menu.name .. "' button '" .. tostring(self.controlName) .. "'] activate failed: " .. tostring(err))
        end
    end
    return item
end

-- Checkbox ------------------------------------------------------------------

local function checkboxValue(item)
    local on = item._control:IsChecked()
    return loc(on and "LOC_CIVVIACCESS_CHECK_ON" or "LOC_CIVVIACCESS_CHECK_OFF",
        on and "checked" or "unchecked")
end

function BaseMenuItems.Checkbox(spec)
    local item = {
        kind = "checkbox",
        _control = resolveControl(spec, "Checkbox"),
        _visibilityControl = resolveVisibilityControl(spec),
        _activateCallback = spec.activateCallback,
    }
    copyCommonFields(spec, item)
    item.isNavigable = isNavigable
    item.isActivatable = isActivatable
    function item:announce(menu)
        return composeSpeech(self, { resolveLabel(self), checkboxValue(self) })
    end
    item.describe = genericDescribe
    function item:activate(menu)
        local c = self._control
        local newValue = not c:IsChecked()
        c:SetCheck(newValue)
        -- Most engine-level checkboxes are wired via RegisterCheckHandler
        -- which fires on SetCheck. For checkboxes wired via
        -- RegisterCallback(Mouse.eLClick, ...) we need an explicit
        -- activateCallback because SetCheck doesn't fan out to those.
        if type(self._activateCallback) == "function" then
            local ok, err = pcall(self._activateCallback, newValue)
            if not ok then
                print("[BaseMenu '" .. menu.name .. "' checkbox '" .. tostring(self.controlName) .. "'] callback failed: " .. tostring(err))
            end
        end
        -- Re-announce the new state.
        OutputMessageToScreenReader(self:announce(menu))
    end
    return item
end

-- Pulldown ------------------------------------------------------------------
--
-- Civ VI's AdvancedSetup uses parameter-driven pulldowns: the control is
-- built by CreatePulldownDriver from a Parameter that has a Values array
-- ({Value, Name, Description, RawDescription, Invalid, InvalidReason}).
-- Selecting an entry calls g_GameParameters:SetParameterValue(parameter,
-- entry) and broadcasts the change.
--
-- This item supports two modes:
--   parameter mode:  spec.parameter + spec.gameParameters. The sub-menu is
--                    built from parameter.Values; selection commits via
--                    gameParameters:SetParameterValue + Network broadcast.
--                    The pulldown's current value (parameter.Value.Name) is
--                    what we announce.
--   entries mode:    spec.entriesFn() returns a list of {Name, Description,
--                    activate}. The caller owns commit. Used for non-
--                    parameter pulldowns (rare in Civ VI; included for
--                    completeness).
--
-- entryAnnounceFn(entry, index): optional override for the speech text of
-- each sub-menu entry. Used for civ pulldowns where the default "leader
-- name" announcement is too thin and the user wants leader + civ + uniques.

function BaseMenuItems.Pulldown(spec)
    local item = {
        kind = "pulldown",
        _control = resolveControl(spec, "Pulldown"),
        _visibilityControl = resolveVisibilityControl(spec),
        _parameter = spec.parameter,
        _gameParameters = spec.gameParameters,
        _entriesFn = spec.entriesFn,
        _entryAnnounceFn = spec.entryAnnounceFn,
        _selectEntry = spec.selectEntry,
    }
    copyCommonFields(spec, item)
    -- Parameter description as default tooltip source for describe path.
    if (item.tooltipText == nil or item.tooltipText == "") and item.tooltipFn == nil
        and item.tooltipKey == nil and spec.parameter ~= nil
        and spec.parameter.Description ~= nil then
        item.tooltipText = spec.parameter.Description
    end
    item.isNavigable = isNavigable
    item.isActivatable = isActivatable

    -- Current value text for the parent's announcement. Parameter mode
    -- reads parameter.Value.Name; entries mode delegates to labelFn (caller
    -- supplies it because we can't infer the "current entry" without help).
    local function currentValueText()
        if item._parameter ~= nil and item._parameter.Value ~= nil then
            return item._parameter.Value.Name
        end
        return nil
    end

    function item:announce(menu)
        local parts = { resolveLabel(self) }
        local v = currentValueText()
        if v ~= nil and v ~= "" then
            parts[#parts + 1] = v
        end
        return composeSpeech(self, parts)
    end
    item.describe = genericDescribe

    -- Build the sub-menu entries list from the parameter / entriesFn.
    local function buildSubItems(menu)
        local entries = {}
        if item._parameter ~= nil and type(item._parameter.Values) == "table" then
            for i, v in ipairs(item._parameter.Values) do
                entries[#entries + 1] = {
                    Name = v.Name,
                    Description = v.RawDescription or v.Description,
                    Invalid = v.Invalid,
                    InvalidReason = v.InvalidReason,
                    _value = v,
                    _index = i,
                }
            end
        elseif type(item._entriesFn) == "function" then
            local ok, result = pcall(item._entriesFn)
            if ok and type(result) == "table" then
                entries = result
            else
                print("[BaseMenu pulldown '" .. tostring(item.controlName) .. "'] entriesFn failed: " .. tostring(result))
            end
        end

        local subItems = {}
        for i, entry in ipairs(entries) do
            local subItem = {
                kind = "pulldown_entry",
                _entry = entry,
                _index = i,
            }
            subItem.isNavigable = function(self)
                return true
            end
            subItem.isActivatable = function(self)
                return not self._entry.Invalid
            end
            subItem.announce = function(self, m)
                if type(item._entryAnnounceFn) == "function" then
                    local ok, result = pcall(item._entryAnnounceFn, self._entry, self._index)
                    if ok and result ~= nil and result ~= "" then
                        return result
                    end
                end
                local parts = { self._entry.Name or "" }
                if self._entry.Invalid then
                    parts[#parts + 1] = loc("LOC_CIVVIACCESS_DISABLED", "disabled")
                    if self._entry.InvalidReason ~= nil and self._entry.InvalidReason ~= "" then
                        parts[#parts + 1] = self._entry.InvalidReason
                    end
                end
                return table.concat(parts, ", ")
            end
            subItem.describe = function(self, m)
                return appendTooltip(self:announce(m), self._entry.Description)
            end
            subItem.activate = function(self, m)
                if not self:isActivatable() then
                    OutputMessageToScreenReader(self:announce(m))
                    return
                end
                -- Parameter mode: commit via the GameParameters singleton.
                if item._parameter ~= nil and item._gameParameters ~= nil then
                    local ok, err = pcall(function()
                        item._gameParameters:SetParameterValue(item._parameter, self._entry._value)
                        if Network ~= nil and Network.BroadcastGameConfig ~= nil then
                            Network.BroadcastGameConfig()
                        end
                    end)
                    if not ok then
                        print("[BaseMenu pulldown '" .. tostring(item.controlName) .. "'] commit failed: " .. tostring(err))
                    end
                elseif type(item._selectEntry) == "function" then
                    local ok, err = pcall(item._selectEntry, self._entry)
                    if not ok then
                        print("[BaseMenu pulldown '" .. tostring(item.controlName) .. "'] selectEntry failed: " .. tostring(err))
                    end
                elseif type(self._entry.activate) == "function" then
                    local ok, err = pcall(self._entry.activate)
                    if not ok then
                        print("[BaseMenu pulldown entry '" .. tostring(self._entry.Name) .. "'] activate failed: " .. tostring(err))
                    end
                end
                -- Close the sub-menu and announce new parent state.
                BaseMenu.popSubMenu(m)
            end
            subItems[#subItems + 1] = subItem
        end
        return subItems
    end

    function item:activate(menu)
        local subItems = buildSubItems(menu)
        if #subItems == 0 then
            -- Nothing to pick: re-speak the label so the user knows the
            -- press was received but had no effect.
            OutputMessageToScreenReader(self:announce(menu))
            return
        end
        BaseMenu.pushSubMenu(menu, {
            name = menu.name .. ":" .. (self.controlName or "pulldown"),
            displayName = resolveLabel(self),
            items = subItems,
        })
    end

    return item
end

-- ParameterCheckbox ---------------------------------------------------------
--
-- Civ VI parameter-framework checkbox. Unlike Checkbox above (which wraps a
-- Controls.X checkbox widget), this one is bound to a Parameter whose
-- Domain == "bool" or GroupId == "GameModes". The bool state is read from
-- parameter.Value and toggled via gameParameters:SetParameterValue. The
-- backing control is the simple-parameter checkbox the engine builds for
-- this parameter — we keep a reference so isHidden / isDisabled reflect
-- the engine's visibility / enable state.
--
-- spec.parameter        the Parameter object from g_GameParameters.Parameters.
-- spec.gameParameters   the g_GameParameters singleton (so commit works).
-- spec.control          optional engine widget for visibility / enable
--                       gating; falls through to "always navigable" when
--                       absent (parameter-only checkboxes whose render
--                       widget isn't directly reachable).

local function paramBoolValue(item)
    local on = false
    if item._parameter ~= nil then
        on = item._parameter.Value == true
    end
    return on, loc(on and "LOC_CIVVIACCESS_CHECK_ON" or "LOC_CIVVIACCESS_CHECK_OFF",
        on and "checked" or "unchecked")
end

function BaseMenuItems.ParameterCheckbox(spec)
    assert(spec.parameter ~= nil, "ParameterCheckbox needs parameter")
    assert(spec.gameParameters ~= nil, "ParameterCheckbox needs gameParameters")
    local item = {
        kind = "checkbox",
        _control = spec.control,
        _visibilityControl = resolveVisibilityControl(spec),
        _parameter = spec.parameter,
        _gameParameters = spec.gameParameters,
    }
    copyCommonFields(spec, item)
    -- Use parameter.Description as the default tooltip source so the
    -- describe path (Ctrl+T) gets the long help text without callers
    -- having to plumb tooltipText themselves.
    if (item.tooltipText == nil or item.tooltipText == "") and item.tooltipFn == nil
        and item.tooltipKey == nil and spec.parameter.Description ~= nil then
        item.tooltipText = spec.parameter.Description
    end
    function item:isNavigable()
        if self._control ~= nil and self._control.IsHidden ~= nil and self._control:IsHidden() then
            return false
        end
        if self._visibilityControl ~= nil and self._visibilityControl.IsHidden ~= nil and self._visibilityControl:IsHidden() then
            return false
        end
        return true
    end
    function item:isActivatable()
        if not self:isNavigable() then return false end
        if self._control ~= nil and self._control.IsDisabled ~= nil and self._control:IsDisabled() then
            return false
        end
        return true
    end
    function item:announce(menu)
        local _, stateText = paramBoolValue(self)
        local label = resolveLabel(self)
        if (label == nil or label == "") and self._parameter ~= nil then
            label = self._parameter.Name or ""
        end
        local parts = { label, stateText }
        if not self:isActivatable() then
            parts[#parts + 1] = loc("LOC_CIVVIACCESS_DISABLED", "disabled")
        end
        return table.concat(parts, ", ")
    end
    item.describe = genericDescribe
    function item:activate(menu)
        local on = self._parameter.Value == true
        local newValue = not on
        local ok, err = pcall(function()
            self._gameParameters:SetParameterValue(self._parameter, newValue)
            if Network ~= nil and Network.BroadcastGameConfig ~= nil then
                Network.BroadcastGameConfig()
            end
        end)
        if not ok then
            print("[BaseMenu '" .. menu.name .. "' parameter-checkbox '" .. tostring(self._parameter.ParameterId) .. "'] toggle failed: " .. tostring(err))
            return
        end
        OutputMessageToScreenReader(self:announce(menu))
    end
    return item
end

-- Group ---------------------------------------------------------------------
--
-- A group has a label and children. Drilling into a group descends one
-- level. Children can be:
--   items     static table, computed once at item construction.
--   itemsFn   function returning a fresh list. Combined with cached=false,
--             the children rebuild on every drill — used for dynamic groups
--             whose membership flips with state (Players group when slots
--             are added/removed, Game Modes when mods toggle).
-- cached defaults to true: itemsFn is called once and the result cached.
--
-- visibilityControl / visibilityControlName: optional gate. When the
-- control is hidden, the group disappears from navigation.

function BaseMenuItems.Group(spec)
    assert(spec.items ~= nil or type(spec.itemsFn) == "function",
        "Group needs items table or itemsFn")
    local item = {
        kind = "group",
        _visibilityControl = resolveVisibilityControl(spec),
        _itemsFn = spec.itemsFn,
        _staticItems = spec.items,
        _cached = spec.cached ~= false,
        _cachedChildren = nil,
    }
    copyCommonFields(spec, item)

    function item:isNavigable()
        if self._visibilityControl ~= nil and self._visibilityControl.IsHidden ~= nil and self._visibilityControl:IsHidden() then
            return false
        end
        return true
    end
    function item:isActivatable()
        return self:isNavigable()
    end
    function item:announce(menu)
        local children = self:children()
        local count = 0
        for _, c in ipairs(children) do
            if c:isNavigable() then
                count = count + 1
            end
        end
        local parts = { resolveLabel(self) }
        local groupTag = loc("LOC_CIVVIACCESS_KIND_GROUP", "submenu")
        parts[#parts + 1] = groupTag
        if count > 0 then
            local itemsLabel = loc("LOC_CIVVIACCESS_GROUP_ITEMS", count == 1 and "1 item" or (count .. " items"), count)
            parts[#parts + 1] = itemsLabel
        end
        return table.concat(parts, ", ")
    end
    item.describe = genericDescribe
    function item:children()
        if self._staticItems ~= nil then
            return self._staticItems
        end
        if self._cached and self._cachedChildren ~= nil then
            return self._cachedChildren
        end
        local ok, result = pcall(self._itemsFn)
        if not ok then
            print("[BaseMenuItems Group '" .. tostring(self.controlName or self.textKey) .. "'] itemsFn failed: " .. tostring(result))
            return {}
        end
        if self._cached then
            self._cachedChildren = result or {}
        end
        return result or {}
    end
    function item:invalidate()
        self._cachedChildren = nil
    end
    return item
end

-- Choice --------------------------------------------------------------------
--
-- Non-control list entry: a label + optional activate. Used for rows that
-- aren't backed by a widget (e.g. when CivName is showing instead of the
-- pulldown, the "row" is just the displayed name and activating it opens
-- the name editor). Visibility is gated entirely by visibilityControl.

function BaseMenuItems.Choice(spec)
    local item = {
        kind = "choice",
        _visibilityControl = resolveVisibilityControl(spec),
        _activate = spec.activate,
    }
    copyCommonFields(spec, item)
    function item:isNavigable()
        if self._visibilityControl ~= nil and self._visibilityControl.IsHidden ~= nil and self._visibilityControl:IsHidden() then
            return false
        end
        return true
    end
    function item:isActivatable()
        return self:isNavigable() and type(self._activate) == "function"
    end
    function item:announce(menu)
        return resolveLabel(self)
    end
    item.describe = genericDescribe
    function item:activate(menu)
        if type(self._activate) ~= "function" then
            return
        end
        local ok, err = pcall(self._activate)
        if not ok then
            print("[BaseMenu '" .. menu.name .. "' choice] activate failed: " .. tostring(err))
        end
    end
    return item
end

return BaseMenuItems
