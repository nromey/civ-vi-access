-- ScannerNav.lua — the scanner's navigation state machine. Owns the four cursor
-- indices (category, subcategory, item, instance), the current snapshot, and the
-- pre-jump cell for Backspace. The handler (task 9) is just a (key,mods) →
-- entry-point table; this file is the behavior. Ported from Civ V Access's
-- CivVAccess_ScannerNav, trimmed to the v1 core.
--
-- REBUILD MODEL (the subtle, valuable part — ported faithfully):
-- every entry point rebuilds the snapshot from live backend output. Explicit
-- "reorient" cycles (category / subcategory) re-anchor the sort origin to the
-- live cursor and land the user at the front of the new scope. Every other cycle
-- (item / instance / Home / End) PRESERVES the previous origin and re-finds the
-- user's current instance by its entry key, so a resort never strands them off
-- the entity they were pointing at.
--
-- DEFERRED to the polish layer (task 12), omitted here: type-ahead search,
-- directional-arc scope, compass/coords readout toggles, auto-move, the
-- directional beep, the sighted map-highlight, and custom-category favorites.
--
-- HOST SEAM: the hex cursor is injected as Scanner.cursor = { position()->x,y,
-- jumpTo(x,y)->glanceString } by the input host (HexCursorAddin) in task 9.
-- Until wired, the seam no-ops gracefully (nav still cycles + announces; jump
-- speaks nothing). Direction text comes from HexGeom.relativeDirection.

include("Log");
include("ScreenReader");
include("HexGeom");

ScannerNav = {};

-- ---------------------------------------------------------------------------
-- Spoken strings (plain English for v1; localize to LOC_* with the rest of the
-- scanner later).
-- ---------------------------------------------------------------------------
-- Standalone spoken strings, from the localized text file (CivVIAccessStrings.xml).
-- STR_HERE has no trailing period: it's used both standalone and inline
-- ("Woods. Here. 1 of 3"); the formatter adds the period.
local STR_EMPTY     = Locale.Lookup("LOC_CIVVIACCESS_SCANNER_EMPTY");
local STR_HERE      = Locale.Lookup("LOC_CIVVIACCESS_SCANNER_HERE");
local STR_NO_RETURN = Locale.Lookup("LOC_CIVVIACCESS_SCANNER_NO_RETURN");

-- ---------------------------------------------------------------------------
-- Cursor seam. The host sets Scanner.cursor; until then these no-op.
-- ---------------------------------------------------------------------------
local function cursorPos()
    if Scanner ~= nil and Scanner.cursor ~= nil and Scanner.cursor.position ~= nil then
        local ok, x, y = pcall(Scanner.cursor.position);
        if ok and x ~= nil then return x, y; end
    end
    return nil, nil;
end

local function cursorJumpTo(x, y)
    if Scanner ~= nil and Scanner.cursor ~= nil and Scanner.cursor.jumpTo ~= nil then
        local ok, glance = pcall(Scanner.cursor.jumpTo, x, y);
        if ok and glance ~= nil then return glance; end
    end
    return "";
end

-- ---------------------------------------------------------------------------
-- State (module upvalues, single scanner instance).
-- ---------------------------------------------------------------------------
local _catIdx   = 1;
local _subIdx   = 1;
local _itemIdx  = 0;
local _instIdx  = 0;
local _snapshot = nil;
local _preJumpX = nil;
local _preJumpY = nil;

-- ---------------------------------------------------------------------------
-- Snapshot accessors.
-- ---------------------------------------------------------------------------
local function currentCategory()
    if _snapshot == nil then return nil; end
    return _snapshot.categories[_catIdx];
end
local function currentSub()
    local cat = currentCategory();
    if cat == nil then return nil; end
    return cat.subcategories[_subIdx];
end
local function currentItem()
    local sub = currentSub();
    if sub == nil or _itemIdx == 0 then return nil; end
    return sub.items[_itemIdx];
end
local function currentInstance()
    local item = currentItem();
    if item == nil or _instIdx == 0 then return nil; end
    return item.instances[_instIdx];
end

local function categoryIndexByKey(key)
    if _snapshot == nil or key == nil then return nil; end
    for i, cat in ipairs(_snapshot.categories) do
        if cat.key == key then return i; end
    end
    return nil;
end

local function reanchorCategory(key)
    local i = categoryIndexByKey(key);
    if i ~= nil then _catIdx = i; return; end
    local n = #_snapshot.categories;
    if _catIdx > n then _catIdx = n; end
    if _catIdx < 1 then _catIdx = 1; end
end

local function landOnCurrentSub()
    local sub = currentSub();
    if sub ~= nil and #sub.items > 0 then
        _itemIdx = 1;
        _instIdx = (#sub.items[1].instances > 0) and 1 or 0;
    else
        _itemIdx, _instIdx = 0, 0;
    end
end

local function snapToCategoryFront()
    _subIdx = 1;
    landOnCurrentSub();
end

-- ---------------------------------------------------------------------------
-- Rebuild.
-- ---------------------------------------------------------------------------
local function activeIds()
    local lp = (Game ~= nil and Game.GetLocalPlayer ~= nil) and Game.GetLocalPlayer() or -1;
    local team = -1;
    if lp ~= nil and lp >= 0 and Players ~= nil and Players[lp] ~= nil and Players[lp].GetTeam ~= nil then
        local ok, t = pcall(function() return Players[lp]:GetTeam(); end);
        if ok and t ~= nil then team = t; end
    end
    return lp, team;
end

local function originOrDefault()
    local cx, cy = cursorPos();
    if cx == nil then return 0, 0; end
    return cx, cy;
end

local function rebuildSnapshot(originX, originY)
    local lp, team = activeIds();
    local entries = Scanner.gatherEntries(lp, team);
    _snapshot = ScannerSnap.build(entries, originX, originY);
end

-- Rebuild preserving the user's current instance by key. Sort origin is held
-- from the previous snapshot (stable distances) unless this is the first build,
-- which anchors at the cursor and skips to the first non-empty category.
local function rebuildAndLocate()
    local isFirstBuild = (_snapshot == nil);
    local key, hintKey, hintSub;
    local inst = currentInstance();
    if inst ~= nil then
        key, hintSub = inst.key, _subIdx;
        local cat = currentCategory();
        hintKey = cat ~= nil and cat.key or nil;
    end
    local originX, originY;
    if isFirstBuild then
        originX, originY = originOrDefault();
    else
        originX, originY = _snapshot.cursorX, _snapshot.cursorY;
    end
    rebuildSnapshot(originX, originY);
    if key ~= nil then
        local hintCat = categoryIndexByKey(hintKey);
        local ci, si, ii, ini = ScannerSnap.locate(_snapshot, key, hintCat, hintSub);
        if ci ~= nil then
            _catIdx, _subIdx, _itemIdx, _instIdx = ci, si, ii, ini;
            return true;
        end
    end
    _itemIdx, _instIdx = 0, 0;
    if isFirstBuild then
        local cats = _snapshot.categories;
        local n = #cats;
        for step = 0, n - 1 do
            local i = ((_catIdx - 1 + step) % n) + 1;
            local allSub = cats[i].subcategories[1];
            if allSub ~= nil and #allSub.items > 0 then
                _catIdx = i;
                _subIdx = 1;
                break;
            end
        end
    end
    return false;
end

-- Full rebuild anchored to the live cursor; resets item/inst sentinels so the
-- caller picks where to land. Used by the explicit-reorient cycles.
local function rebuildFromCursor()
    local cat = currentCategory();
    local prevKey = cat ~= nil and cat.key or nil;
    local cx, cy = originOrDefault();
    rebuildSnapshot(cx, cy);
    reanchorCategory(prevKey);
    _itemIdx, _instIdx = 0, 0;
end

-- Resolve the live cursor to a plotIndex hint for cluster ValidateEntry.
local function cursorPlotIndexHint()
    local cx, cy = cursorPos();
    if cx == nil or Map == nil or Map.GetPlot == nil then return nil; end
    local plot = nil;
    pcall(function() plot = Map.GetPlot(cx, cy); end);
    if plot == nil then return nil; end
    local ok, idx = pcall(function() return plot:GetIndex(); end);
    return (ok and idx ~= nil) and idx or nil;
end

-- Validate the current instance; prune + re-land while it's stale.
local function ensureCurrentInstanceValid()
    while true do
        local inst = currentInstance();
        if inst == nil then return; end
        local entry = inst.entry;
        local oldPlotIndex = entry.plotIndex;
        local ok, valid = pcall(entry.backend.ValidateEntry, entry, cursorPlotIndexHint());
        if not ok then
            Log.error("ScannerNav: backend '" .. tostring(entry.backend.name)
                .. "' ValidateEntry failed: " .. tostring(valid));
            return;
        end
        if valid then
            if entry.plotIndex ~= oldPlotIndex and Map ~= nil and Map.GetPlotByIndex ~= nil then
                local plot = nil;
                pcall(function() plot = Map.GetPlotByIndex(entry.plotIndex); end);
                if plot ~= nil then inst.plotX, inst.plotY = plot:GetX(), plot:GetY(); end
            end
            return;
        end
        ScannerSnap.pruneInstance(_snapshot, _catIdx, _subIdx, _itemIdx, _instIdx);
        local item = currentItem();
        if item == nil or #item.instances == 0 then
            local sub = currentSub();
            if sub == nil or #sub.items == 0 then
                _itemIdx, _instIdx = 0, 0;
                return;
            end
            if _itemIdx > #sub.items then _itemIdx = #sub.items; end
            if _itemIdx == 0 then _itemIdx = 1; end
            _instIdx = (#sub.items[_itemIdx].instances > 0) and 1 or 0;
        elseif _instIdx > #item.instances then
            _instIdx = #item.instances;
        end
    end
end

-- ---------------------------------------------------------------------------
-- Speech assembly. "<name>. <direction from cursor>. <i> of <n>."
-- ---------------------------------------------------------------------------
local function formatInstance(instance, instIdx, instCount)
    local cx, cy = cursorPos();
    local dir;
    if cx == nil then
        dir = "";
    elseif cx == instance.plotX and cy == instance.plotY then
        dir = STR_HERE;
    else
        dir = HexGeom.relativeDirection(cx, cy, instance.plotX, instance.plotY) or STR_HERE;
    end
    local entry = instance.entry;
    local name = entry.backend.FormatName(entry);   -- live-name seam
    local count = instIdx .. " of " .. instCount;
    if dir ~= "" then
        return name .. ". " .. dir .. ". " .. count;
    end
    return name .. ". " .. count;
end

local function announceCurrent()
    local item = currentItem();
    if item == nil then return STR_EMPTY; end
    local inst = currentInstance();
    if inst == nil then return STR_EMPTY; end
    return formatInstance(inst, _instIdx, #item.instances);
end

local function nodeLabel(node)
    return node.label or "";
end

local function announceWithLabel(node)
    if node == nil then return STR_EMPTY; end
    return nodeLabel(node) .. ". " .. announceCurrent();
end

-- ---------------------------------------------------------------------------
-- Wrap / skip helpers.
-- ---------------------------------------------------------------------------
local function wrapIndex(i, n, dir)
    if n <= 0 then return 0; end
    i = i + dir;
    if i < 1 then i = n; end
    if i > n then i = 1; end
    return i;
end

local function stepFromZero(dir, n)
    return (dir < 0) and n or 1;
end

local function categoryHasItems(cat)
    local allSub = cat.subcategories[1];
    return allSub ~= nil and #allSub.items > 0;
end

local function subHasItems(sub)
    return #sub.items > 0;
end

-- Walk `list` from startIdx in `dir`, wrapping, until `pred` accepts. 0 = none.
local function nextIndexMatching(list, startIdx, dir, pred)
    local n = #list;
    if n <= 0 then return 0; end
    local i = startIdx;
    for _ = 1, n do
        i = i + dir;
        if i < 1 then i = n; end
        if i > n then i = 1; end
        if pred(list[i]) then return i; end
    end
    return 0;
end

-- ---------------------------------------------------------------------------
-- Entry points. Each returns the string the handler should speak.
-- ---------------------------------------------------------------------------
function ScannerNav.cycleCategory(dir)
    rebuildFromCursor();
    local newIdx = nextIndexMatching(_snapshot.categories, _catIdx, dir, categoryHasItems);
    if newIdx == 0 then return STR_EMPTY; end
    _catIdx = newIdx;
    snapToCategoryFront();
    ensureCurrentInstanceValid();
    return announceWithLabel(currentCategory());
end

function ScannerNav.cycleSubcategory(dir)
    rebuildFromCursor();
    local cat = currentCategory();
    if cat == nil then return STR_EMPTY; end
    local newIdx = nextIndexMatching(cat.subcategories, _subIdx, dir, subHasItems);
    if newIdx == 0 then return STR_EMPTY; end
    _subIdx = newIdx;
    landOnCurrentSub();
    ensureCurrentInstanceValid();
    return announceWithLabel(currentSub());
end

function ScannerNav.cycleItem(dir)
    rebuildAndLocate();
    local sub = currentSub();
    if sub == nil or #sub.items == 0 then return STR_EMPTY; end
    if _itemIdx == 0 then
        _itemIdx = stepFromZero(dir, #sub.items);
    else
        _itemIdx = wrapIndex(_itemIdx, #sub.items, dir);
    end
    local item = currentItem();
    _instIdx = (item ~= nil and #item.instances > 0) and 1 or 0;
    ensureCurrentInstanceValid();
    return announceCurrent();
end

function ScannerNav.cycleInstance(dir)
    rebuildAndLocate();
    local item = currentItem();
    if item == nil or #item.instances == 0 then return STR_EMPTY; end
    if _instIdx == 0 then
        _instIdx = stepFromZero(dir, #item.instances);
    else
        _instIdx = wrapIndex(_instIdx, #item.instances, dir);
    end
    ensureCurrentInstanceValid();
    return announceCurrent();
end

-- Home: jump the cursor onto the current entry's plot, speak the glance (or HERE).
function ScannerNav.jumpToEntry()
    rebuildAndLocate();
    ensureCurrentInstanceValid();
    local inst = currentInstance();
    if inst == nil then return STR_EMPTY; end
    return ScannerNav.jumpCursorTo(inst.plotX, inst.plotY);
end

-- End: distance + direction from the live cursor to the current entry.
function ScannerNav.distanceFromCursor()
    rebuildAndLocate();
    ensureCurrentInstanceValid();
    local inst = currentInstance();
    if inst == nil then return STR_EMPTY; end
    local cx, cy = cursorPos();
    if cx == nil then return ""; end
    if cx == inst.plotX and cy == inst.plotY then return STR_HERE; end
    return HexGeom.relativeDirection(cx, cy, inst.plotX, inst.plotY) or STR_HERE;
end

function ScannerNav.markPreJump(x, y)
    _preJumpX, _preJumpY = x, y;
end

-- Shared cursor-jump primitive: HERE short-circuit (no re-glance, preserve the
-- Backspace anchor) when already on the target, else mark + jump.
function ScannerNav.jumpCursorTo(x, y)
    local cx, cy = cursorPos();
    if cx == x and cy == y then return STR_HERE; end
    if cx ~= nil then ScannerNav.markPreJump(cx, cy); end
    return cursorJumpTo(x, y);
end

-- Backspace: return the cursor to the cell saved at the last scanner jump.
function ScannerNav.returnToPreJump()
    if _preJumpX == nil then return STR_NO_RETURN; end
    local x, y = _preJumpX, _preJumpY;
    _preJumpX, _preJumpY = nil, nil;
    return cursorJumpTo(x, y);
end

Log.info("ScannerNav.lua: loaded");
