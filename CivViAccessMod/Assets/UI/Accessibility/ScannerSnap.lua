-- ScannerSnap.lua — snapshot builder. Turns the flat ScannerEntry list from
-- Scanner.gatherEntries into the nested category → subcategory → item → instance
-- structure ScannerNav walks. Ported from Civ V Access's CivVAccess_ScannerSnap.
--
-- Sort order (nearest-first throughout):
--   instances within an item   distance ascending (from the build cursor),
--                              then entry.sortKey, then plotIndex (stable)
--   items within a subcategory  by their nearest instance's distance
--   subcategories               taxonomy order ("all" is index 1)
--   categories                  taxonomy order
--
-- The "all" subcategory is each category's FIRST declared sub (ScannerCore
-- taxonomy). It AGGREGATES the category: when an entry lands in a named sub
-- (e.g. units/enemy), its item object is ALSO referenced from "all" — same
-- object, so pruning from a named sub drops it from "all" by identity. A
-- category with no meaningful split (recommendations, waypoints) declares only
-- "all", and its backend emits subcategory="all" so the item lands there directly.
--
-- Returned snapshot shape:
--   { cursorX, cursorY, categories = { {
--       key, label, subcategories = { {
--         key, label, items = { {
--           name,                       -- spoken label items collapse by
--           instances = { {
--             entry,                    -- the original ScannerEntry (ref)
--             key,                      -- entry.key, so Nav can re-find this
--                                       --   instance across a rebuild+resort
--             plotX, plotY, distance,   -- cached at build time for sorting
--           } } } } } } } } }
--
-- Custom categories / keyword favorites (Civ V's customDefs path) are the
-- favorites polish layer (see Scanner polish task) and deliberately omitted
-- here; build() accepts the arg for forward-compat but ignores it for now.

include("Log");

ScannerSnap = {};

-- _itemsByName dedupes entries into items during build; dropped before return.
local function newSub(subDef)
    return { key = subDef.key, label = subDef.label, items = {}, _itemsByName = {} };
end

local function newCategory(catDef)
    local subs = {};
    for _, subDef in ipairs(catDef.subcategories) do
        subs[#subs + 1] = newSub(subDef);
    end
    local subsByKey = {};
    for _, s in ipairs(subs) do
        subsByKey[s.key] = s;
    end
    return {
        key = catDef.key,
        label = catDef.label,
        subcategories = subs,
        _subsByKey = subsByKey,
    };
end

-- Place one entry into (cat, sub): get-or-create the item by identity, append a
-- fresh instance, and share a newly-created item into the category's "all" sub
-- (subcategories[1]). itemKey separates same-named entities that must stay apart
-- (waypoints: one item per unit even when two share a type name); otherwise items
-- group by spoken name.
local function placeEntry(cat, sub, entry, px, py, dist)
    local instance = {
        entry = entry,
        key = entry.key,
        plotX = px,
        plotY = py,
        distance = dist,
    };
    local itemId = entry.itemKey or entry.itemName;
    local item = sub._itemsByName[itemId];
    if item == nil then
        item = { name = entry.itemName, instances = {} };
        sub._itemsByName[itemId] = item;
        sub.items[#sub.items + 1] = item;
        if sub.key ~= "all" then
            local all = cat.subcategories[1];
            if all ~= nil and all.key == "all" then
                all.items[#all.items + 1] = item;   -- shared ref, not a copy
            end
        end
    end
    item.instances[#item.instances + 1] = instance;
end

local function sortSnapshot(snapshot)
    for _, cat in ipairs(snapshot.categories) do
        for _, sub in ipairs(cat.subcategories) do
            for _, item in ipairs(sub.items) do
                table.sort(item.instances, function(a, b)
                    if a.distance ~= b.distance then
                        return a.distance < b.distance;
                    end
                    local ka = a.entry.sortKey or 0;
                    local kb = b.entry.sortKey or 0;
                    if ka ~= kb then
                        return ka < kb;
                    end
                    return a.entry.plotIndex < b.entry.plotIndex;
                end);
            end
            table.sort(sub.items, function(a, b)
                -- Every item has >=1 instance (items are created only on a landing).
                return a.instances[1].distance < b.instances[1].distance;
            end);
        end
    end
end

-- Hex distance from the build cursor to a plot, guarded (Civ VI: Map.GetPlotDistance).
local function plotDistance(cursorX, cursorY, px, py)
    if Map == nil or Map.GetPlotDistance == nil then return 0; end
    local ok, d = pcall(Map.GetPlotDistance, cursorX, cursorY, px, py);
    return (ok and d ~= nil) and d or 0;
end

-- Build a fresh snapshot from entries, sorted against (cursorX, cursorY).
function ScannerSnap.build(entries, cursorX, cursorY, _customDefs)
    local cats = {};
    local catsByKey = {};
    for _, catDef in ipairs(Scanner.CATEGORIES) do
        local cat = newCategory(catDef);
        cats[#cats + 1] = cat;
        catsByKey[cat.key] = cat;
    end

    for _, entry in ipairs(entries) do
        local cat = catsByKey[entry.category];
        if cat == nil then
            Log.warn("ScannerSnap: entry with unknown category '" .. tostring(entry.category)
                .. "' from backend " .. tostring(entry.backend and entry.backend.name));
        else
            local sub = cat._subsByKey[entry.subcategory];
            if sub == nil then
                Log.warn("ScannerSnap: entry with unknown subcategory '" .. tostring(entry.subcategory)
                    .. "' under '" .. tostring(entry.category) .. "'");
            else
                local plot = nil;
                pcall(function() plot = Map.GetPlotByIndex(entry.plotIndex); end);
                if plot == nil then
                    Log.warn("ScannerSnap: entry with unresolved plotIndex " .. tostring(entry.plotIndex));
                else
                    local px, py = plot:GetX(), plot:GetY();
                    placeEntry(cat, sub, entry, px, py, plotDistance(cursorX, cursorY, px, py));
                end
            end
        end
    end

    local snapshot = { cursorX = cursorX, cursorY = cursorY, categories = cats };
    sortSnapshot(snapshot);

    -- Drop build-only helpers; pruning walks cat.subcategories directly.
    for _, cat in ipairs(cats) do
        cat._subsByKey = nil;
        for _, sub in ipairs(cat.subcategories) do
            sub._itemsByName = nil;
        end
    end
    return snapshot;
end

-- Find the instance carrying `key` and return (catIdx, subIdx, itemIdx, instIdx),
-- or nil. Nav uses this to re-seat the user on the same entity after a rebuild
-- resorts everything. The (hintCatIdx, hintSubIdx) is checked first so a user in
-- a named sub stays there rather than being pulled to the shared "all" copy.
function ScannerSnap.locate(snapshot, key, hintCatIdx, hintSubIdx)
    local function scanSub(sub, ci, si)
        for ii, item in ipairs(sub.items) do
            for ini, inst in ipairs(item.instances) do
                if inst.key == key then
                    return ci, si, ii, ini;
                end
            end
        end
        return nil;
    end
    if hintCatIdx ~= nil and hintSubIdx ~= nil then
        local cat = snapshot.categories[hintCatIdx];
        if cat ~= nil then
            local sub = cat.subcategories[hintSubIdx];
            if sub ~= nil then
                local ci, si, ii, ini = scanSub(sub, hintCatIdx, hintSubIdx);
                if ci ~= nil then
                    return ci, si, ii, ini;
                end
            end
        end
    end
    for ci, cat in ipairs(snapshot.categories) do
        for si, sub in ipairs(cat.subcategories) do
            if not (ci == hintCatIdx and si == hintSubIdx) then
                local fci, fsi, fii, fini = scanSub(sub, ci, si);
                if fci ~= nil then
                    return fci, fsi, fii, fini;
                end
            end
        end
    end
    return nil;
end

-- Drop (catIdx, subIdx, itemIdx, instIdx). If the item empties, remove it from
-- this sub AND every sibling sub (i.e. "all") that references the same item
-- object. Nav calls this when ValidateEntry fails on the current instance.
function ScannerSnap.pruneInstance(snapshot, catIdx, subIdx, itemIdx, instIdx)
    local cat = snapshot.categories[catIdx];
    if cat == nil then return; end
    local sub = cat.subcategories[subIdx];
    if sub == nil then return; end
    local item = sub.items[itemIdx];
    if item == nil then return; end

    table.remove(item.instances, instIdx);
    if #item.instances > 0 then return; end

    for _, other in ipairs(cat.subcategories) do
        for i = #other.items, 1, -1 do
            if other.items[i] == item then
                table.remove(other.items, i);
                break;
            end
        end
    end
end

Log.info("ScannerSnap.lua: loaded");
