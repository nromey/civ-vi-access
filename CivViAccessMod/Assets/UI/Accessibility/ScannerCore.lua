-- ScannerCore.lua — the spine of the accessible map scanner (and, on top of it,
-- the unit-movement layer). Ported from Civ V Access's CivVAccess_ScannerCore.
--
-- WHAT THE SCANNER IS. A keyboard-driven, four-level navigable view over every
-- entity on the known map:
--     CATEGORY  →  SUBCATEGORY  →  ITEM  →  INSTANCE
-- e.g. Units → Enemy → "Barbarian Warrior" → (the 3 of them, nearest first).
-- Results sort nearest-first from a reference (the hex cursor); the user cycles
-- the hierarchy, snaps the cursor onto a result, and hears its bearing+distance.
-- In Civ V Access the unit-movement features (waypoints, move-to, path preview,
-- turns-to-destination) are built ON this same framework — a Waypoints category
-- plus a "send selected unit to the located hex" hand-off — so this core is the
-- shared base for BOTH the scanner and moving units.
--
-- ARCHITECTURE (core / snapshot / nav / handler / backends), mirrored from Civ V
-- so future syncs are mechanical:
--   * ScannerCore (this file) — owns the CATEGORY taxonomy and the backend
--     registry, and defines the backend contract + entry shape.
--   * Backends — one per data domain (terrain, resources, units, cities, …).
--     Each walks live game state and emits flat entries tagged with category /
--     subcategory keys that MUST match the taxonomy below. Backends register via
--     Scanner.registerBackend and are added incrementally; a category with no
--     backing entries this scan is simply skipped by the navigator.
--   * ScannerSnap — folds all backends' entries into the nested snapshot
--     (sorted, collapsed by item name), incl. user custom categories.
--   * ScannerNav — the cursor state machine over a snapshot.
--   * ScannerHandler / ScannerInput — keybindings + search modal (host VM).
--
-- This file is host-agnostic pure Lua: no Controls, no ContextPtr, no engine
-- calls. Backends do the engine work; the handler does the input/cursor work.

include("Log");

Scanner = Scanner or {};

-- ===========================================================================
--  CATEGORY TAXONOMY
--  Ordered list; the navigator cycles categories in this order (skipping any
--  that are empty for the current scan). Each category's first subcategory is
--  the implicit "all" bucket (every entry the category's backends emit); named
--  subcategories follow. Subcategory keys are the contract between the taxonomy
--  and the backends — a backend emitting subcategory "enemy" under "units"
--  requires {key="enemy"} to exist here, or ScannerSnap logs a mismatch.
--
--  Labels are spoken directly (run through stripIconTags at announce time);
--  localize to LOC_* later if/when the scanner ships in non-English builds.
-- ===========================================================================
local function cat(key, label, subs)
    return { key = key, label = label, subcategories = subs };
end
local function sub(key, label)
    return { key = key, label = label };
end

Scanner.CATEGORIES = {
    cat("units", "Units", {
        sub("all",      "All units"),
        sub("mine",     "My units"),
        sub("allied",   "Allied units"),
        sub("neutral",  "Other units"),
        sub("enemy",    "Enemy units"),     -- feeds combat/threat awareness
    }),
    cat("cities", "Cities", {
        sub("all",         "All cities"),
        sub("mine",        "My cities"),
        sub("city_states", "City-states"),
        sub("neutral",     "Other cities"),
        sub("enemy",       "Enemy cities"),
        sub("barb_camps",  "Barbarian camps"),
    }),
    cat("improvements", "Improvements", {
        sub("all",     "All improvements"),
        sub("mine",    "My improvements"),
        sub("neutral", "Other improvements"),
        sub("enemy",   "Enemy improvements"),
    }),
    cat("resources", "Resources", {
        sub("all",       "All resources"),
        sub("strategic", "Strategic resources"),
        sub("luxury",    "Luxury resources"),
        sub("bonus",     "Bonus resources"),
    }),
    cat("terrain", "Terrain", {
        sub("all",        "All terrain"),
        sub("base",       "Base terrain"),
        sub("features",   "Features"),
        sub("elevation",  "Hills and mountains"),
        sub("freshwater", "Fresh water"),
    }),
    cat("special", "Special", {
        sub("all",             "All special"),
        sub("natural_wonders", "Natural wonders"),
        sub("goody_huts",      "Tribal villages"),
    }),
    cat("geography", "Geography", {
        sub("all",        "All geography"),
        sub("landmasses", "Landmasses"),
        sub("oceans",     "Oceans"),
    }),
    cat("recommendations", "Recommendations", {
        sub("all", "All recommendations"),
    }),
    -- The hook the movement layer hangs on: a selected unit's queued path (and,
    -- in all-units scope, every owned unit that is currently moving).
    cat("waypoints", "Waypoints", {
        sub("all", "All waypoints"),
    }),
};

-- Fast lookups, built once from the taxonomy above.
Scanner.categoryByKey = {};
Scanner.subLabel = {};      -- subLabel[catKey][subKey] = label
for _, c in ipairs(Scanner.CATEGORIES) do
    Scanner.categoryByKey[c.key] = c;
    Scanner.subLabel[c.key] = {};
    for _, s in ipairs(c.subcategories) do
        Scanner.subLabel[c.key][s.key] = s.label;
    end
end

function Scanner.isValidPlacement(catKey, subKey)
    local m = Scanner.subLabel[catKey];
    return m ~= nil and m[subKey] ~= nil;
end

-- ===========================================================================
--  BACKEND CONTRACT
--  A backend is a table registered with Scanner.registerBackend. It implements:
--
--    backend.Scan(activePlayer, activeTeam) -> { entry, ... }
--        Walk live game state and return a flat array of ScannerEntry (below).
--        Called fresh on every scanner (re)build — never cache stale state.
--
--    backend.ValidateEntry(entry, cursorPlotHint) -> boolean
--        Called when the user navigates onto an entry. Return false if it has
--        gone stale (unit died, city razed, plot now revealed differently).
--        Cluster-style backends may mutate entry.plotIndex to re-center on the
--        nearest surviving member before returning true.
--
--    backend.FormatName(entry) -> string
--        Resolve the entry's CURRENT spoken name at announce time (handles
--        renamed cities, a unit's current promotion/formation, etc.). Kept
--        separate from Scan so the label is always live, not snapshot-frozen.
--
--  ScannerEntry shape (what Scan emits):
--    {
--      plotIndex   = <map plot index>,           -- where it is
--      category    = "units",                    -- must match a taxonomy key
--      subcategory = "enemy",                     -- must match a sub key
--      itemName    = "Barbarian Warrior",        -- collapse key for ITEM level
--      key         = "unit:42",                   -- stable identity across rebuilds
--      sortKey     = <optional tiebreak number>,  -- after distance
--      data        = <opaque backend handle>,     -- unit id, city id, coords…
--      backend     = <self>,                      -- set by registerBackend wrap
--    }
--  Two entries with the same (category, subcategory, itemName) collapse into one
--  ITEM with multiple INSTANCES (e.g. 8 Warriors → 1 item, 8 instances). `key`
--  must be unique per real entity so identity-preserving rebuilds can re-find
--  the user's current spot after a resort.
-- ===========================================================================
-- `or {}` (not `= {}`): Civ VI's include() RE-RUNS a file on every include, and
-- each backend defensively include()s ScannerCore — a bare reset would wipe
-- already-registered backends on the re-run (confirmed via the 2026-06-08 log:
-- ScannerCore loaded twice). Preserve the registry across re-includes.
Scanner.backends = Scanner.backends or {};

function Scanner.registerBackend(backend)
    if type(backend) ~= "table" or type(backend.Scan) ~= "function" then
        Log.warn("ScannerCore: ignoring backend with no Scan function");
        return;
    end
    backend.ValidateEntry = backend.ValidateEntry or function() return true; end
    backend.FormatName    = backend.FormatName    or function(e) return e.itemName or "unknown"; end
    Scanner.backends[#Scanner.backends + 1] = backend;
    Log.info("ScannerCore: registered backend (" .. tostring(backend.name or "?")
        .. "), " .. #Scanner.backends .. " total");
end

-- Run every registered backend and return one flat entry list, each entry
-- stamped with its backend (for ValidateEntry / FormatName dispatch) and
-- validated against the taxonomy. ScannerSnap consumes this.
function Scanner.gatherEntries(activePlayer, activeTeam)
    local out = {};
    for _, backend in ipairs(Scanner.backends) do
        local ok, entries = pcall(backend.Scan, activePlayer, activeTeam);
        if not ok then
            Log.warn("ScannerCore: backend '" .. tostring(backend.name or "?")
                .. "' Scan failed: " .. tostring(entries));
        elseif type(entries) == "table" then
            for _, e in ipairs(entries) do
                if Scanner.isValidPlacement(e.category, e.subcategory) then
                    e.backend = backend;
                    out[#out + 1] = e;
                else
                    Log.warn("ScannerCore: backend '" .. tostring(backend.name or "?")
                        .. "' emitted entry with unknown placement "
                        .. tostring(e.category) .. "/" .. tostring(e.subcategory));
                end
            end
        end
    end
    return out;
end

Log.info("ScannerCore.lua: loaded (" .. #Scanner.CATEGORIES .. " categories)");
