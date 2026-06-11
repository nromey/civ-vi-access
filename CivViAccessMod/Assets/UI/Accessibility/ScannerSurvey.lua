-- ScannerSurvey.lua — the cursor-centered radius SURVEY (#19) + shared ZOOM (#17).
--
-- The cursor is the universal center (see project_cursor_survey_subsystem). A
-- survey reads what's around the cursor within the current zoom radius, for the
-- currently-selected CATEGORY. Reuses the scanner backends (Scanner.gatherEntries)
-- — the same rich entity data the scanner navigates — so this is a different VIEW
-- over one dataset, not a second map sweep.
--
-- Keys (handled here via SurveyHandler.dispatch, forwarded from the WorldInput
-- capture-all wrap; see HOTKEY_REFERENCE.md):
--   S          survey the selected category at the current zoom
--   Alt+S      sonify the survey (spatial audio) — STUB for now
--   Alt+G/U/R  select category: all / units / resources
--   Alt+1..5   set zoom level; Alt+0 reset to level 1
-- (where-am-I = W, rich locate = Shift+W are routed to HexCursor, not here.)
--
-- The selected category + zoom level are SAVED in session state so "set the lens,
-- then look through it as you move" works (Noel 2026-06-09).

include("Log");
include("ScannerCore");
include("HexGeom");

ScannerSurvey = ScannerSurvey or {};

-- Zoom levels are derived from MAP SIZE (Noel 2026-06-09): a doubling progression
-- (2, 4, 8, 16, 32, ...) that runs up to a final "whole map" level whose radius
-- covers the entire grid. So a bigger map gets MORE levels and the top always
-- means "everything revealed" — no fixed cap that's too small on a huge map and
-- overkill on a tiny one. Built lazily (Map must be ready) + cached.
ScannerSurvey.zoomLevel = ScannerSurvey.zoomLevel or 1;
local _zoomRadii = nil;   -- { radius, ... }; last entry is the whole-map level

-- Safe upper bound on the hex distance between any two plots: Civ VI maps wrap
-- horizontally (cylinder), so half the width covers the horizontal axis; add the
-- full height for the vertical. Generous on purpose — the top level just needs to
-- include every revealed plot.
local function mapWholeRadius()
    if Map ~= nil and Map.GetGridSize ~= nil then
        local ok, w, h = pcall(function() return Map.GetGridSize(); end);
        if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
            return math.floor(w / 2) + h;
        end
    end
    return 64;
end

local function zoomRadii()
    if _zoomRadii == nil then
        local whole = mapWholeRadius();
        local radii = {};
        local r = 2;
        while r < whole do
            radii[#radii + 1] = r;
            r = r * 2;
        end
        radii[#radii + 1] = whole;   -- final level = whole map
        _zoomRadii = radii;
    end
    return _zoomRadii;
end

local function zoomMax() return #zoomRadii(); end

-- Selected category (the "lens"). "all" = the general overview; the rest map to
-- scanner backend categories. Saved across surveys.
ScannerSurvey.category = ScannerSurvey.category or "all";

-- Spoken labels per category.
local CAT_LABEL = {
    all          = "everything",
    units        = "units",
    resources    = "resources",
    cities       = "cities",
    terrain      = "terrain",
    improvements = "improvements",
};

-- For the "all" overview, which categories to tally (entities you'd want to know
-- are near you — not the terrain backdrop, which is its own lens).
local ALL_CATEGORIES = { "units", "cities", "resources", "improvements", "special" };

-- ---------------------------------------------------------------------------
--  helpers
-- ---------------------------------------------------------------------------

local function localPlayerId()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

local function speak(text, kind)
    if text == nil or text == "" then return; end
    if Speech ~= nil and Speech.emit ~= nil then
        Speech.emit(text, kind or "status");
    end
    Log.info("ScannerSurvey: " .. text);
end

local function cursorXY()
    if Scanner ~= nil and Scanner.cursor ~= nil and Scanner.cursor.position ~= nil then
        return Scanner.cursor.position();
    end
    return nil, nil;
end

local function plotXY(plotIndex)
    if Map == nil or Map.GetPlotByIndex == nil then return nil, nil; end
    local p = Map.GetPlotByIndex(plotIndex);
    if p == nil then return nil, nil; end
    return p:GetX(), p:GetY();
end

-- Gather every revealed entry (backends already fog-gate), then keep those within
-- `radius` of (cx, cy), tagging each with distance + direction from the cursor.
local function entriesInRange(cx, cy, radius)
    local out = {};
    if Scanner == nil or Scanner.gatherEntries == nil then return out; end
    local lp = localPlayerId();
    local team = (Game ~= nil and Game.GetActiveTeam ~= nil) and Game.GetActiveTeam() or 0;
    local ok, all = pcall(function() return Scanner.gatherEntries(lp, team); end);
    if not ok or type(all) ~= "table" then return out; end

    for _, e in ipairs(all) do
        local ex, ey = plotXY(e.plotIndex);
        if ex ~= nil then
            local dist = Map.GetPlotDistance(cx, cy, ex, ey);
            if dist ~= nil and dist <= radius then
                e._dist = dist;
                e._ex, e._ey = ex, ey;
                out[#out + 1] = e;
            end
        end
    end
    return out;
end

-- "Warrior 3 o'clock, 2 hexes" — name + direction + distance from the cursor.
-- At distance 0 (on the cursor) the direction is dropped ("here").
local function describeEntry(cx, cy, e)
    local name = e.itemName or "unknown";
    if e.backend ~= nil and e.backend.FormatName ~= nil then
        local ok, n = pcall(function() return e.backend.FormatName(e); end);
        if ok and n ~= nil and n ~= "" then name = n; end
    end
    if e._dist == 0 then
        return name .. ", here";
    end
    local dir = HexGeom.directionString(cx, cy, e._ex, e._ey);
    return name .. ", " .. (dir or "") .. ", " .. e._dist .. " hexes";
end

local MAX_LISTED = 8;   -- firehose guard for instance lists

-- ---------------------------------------------------------------------------
--  the survey itself
-- ---------------------------------------------------------------------------

function ScannerSurvey.radius()
    local radii = zoomRadii();
    return radii[ScannerSurvey.zoomLevel] or radii[1];
end

-- General overview: counts of the entity categories within range.
local function surveyAll(cx, cy, radius, entries)
    local counts = {};
    for _, e in ipairs(entries) do counts[e.category] = (counts[e.category] or 0) + 1; end
    local bits = {};
    for _, cat in ipairs(ALL_CATEGORIES) do
        local n = counts[cat];
        if n ~= nil and n > 0 then
            local label = CAT_LABEL[cat] or cat;
            bits[#bits + 1] = n .. " " .. label;
        end
    end
    if #bits == 0 then
        return "Within " .. radius .. " hexes: nothing of note.";
    end
    return "Within " .. radius .. " hexes: " .. table.concat(bits, ", ") .. ".";
end

-- One category: list each in range, nearest first, with direction + distance.
local function surveyCategory(cx, cy, radius, entries, category)
    local hits = {};
    for _, e in ipairs(entries) do
        if e.category == category then hits[#hits + 1] = e; end
    end
    local label = CAT_LABEL[category] or category;
    if #hits == 0 then
        return "No " .. label .. " within " .. radius .. " hexes.";
    end
    table.sort(hits, function(a, b) return (a._dist or 0) < (b._dist or 0); end);

    local parts = {};
    local shown = math.min(#hits, MAX_LISTED);
    for i = 1, shown do parts[#parts + 1] = describeEntry(cx, cy, hits[i]); end
    local head = (label:sub(1, 1):upper() .. label:sub(2)) .. " within " .. radius .. ": ";
    local tail = "";
    if #hits > shown then tail = ". And " .. (#hits - shown) .. " more"; end
    return head .. table.concat(parts, ". ") .. tail;
end

-- Run the survey for the current category at the current zoom, anchored on the
-- cursor. Spoken immediately.
function ScannerSurvey.run()
    local cx, cy = cursorXY();
    if cx == nil then speak("Survey: no cursor yet.", "meta"); return; end
    local radius = ScannerSurvey.radius();
    local entries = entriesInRange(cx, cy, radius);

    if ScannerSurvey.category == "all" then
        speak(surveyAll(cx, cy, radius, entries));
    else
        speak(surveyCategory(cx, cy, radius, entries, ScannerSurvey.category));
    end
end

-- ---------------------------------------------------------------------------
--  category + zoom controls
-- ---------------------------------------------------------------------------

-- Select a category (the saved lens). Confirms by name; does NOT survey (S does).
function ScannerSurvey.selectCategory(category)
    if CAT_LABEL[category] == nil then return; end
    ScannerSurvey.category = category;
    local label = CAT_LABEL[category];
    speak("Survey category: " .. label .. ".", "selection");
end

function ScannerSurvey.setZoom(level)
    if type(level) ~= "number" then return; end
    local maxL = zoomMax();
    if level < 1 then level = 1; elseif level > maxL then level = maxL; end
    ScannerSurvey.zoomLevel = level;
    local radii = zoomRadii();
    local desc = (level == maxL) and "whole map" or (radii[level] .. " hexes");
    local edge = (level == 1) and " min" or "";
    speak("Zoom " .. level .. " of " .. maxL .. ", " .. desc .. edge .. ".", "selection");
end

function ScannerSurvey.zoomStep(delta)
    ScannerSurvey.setZoom(ScannerSurvey.zoomLevel + delta);
end

-- Sonify: spatial-audio rendering of the survey. STUB — the data path is here
-- (entries in range with direction/distance); the audio layer comes next
-- (project_cursor_survey_subsystem + reference_jjflex_waterfall).
function ScannerSurvey.sonify()
    speak("Sonify: not yet implemented.", "meta");
end

-- ---------------------------------------------------------------------------
--  key dispatch (keys forwarded from the WorldInput capture-all wrap)
--  mods bitmask: bit0 Shift (1), bit1 Ctrl (2), bit2 Alt (4).
-- ---------------------------------------------------------------------------

local K = Keys or {};
local KEY_S, KEY_W = K.S, K.W;
local KEY_G, KEY_U, KEY_R = K.G, K.U, K.R;
local KEY_PLUS  = K.VK_OEM_PLUS  or K.OEM_PLUS;
local KEY_MINUS = K.VK_OEM_MINUS or K.OEM_MINUS;

-- Digit zoom-jump keys. The Civ VI Keys enum form for digits isn't documented,
-- so resolve defensively (only non-nil matches get used); Alt+=/Alt+- stepping is
-- the reliable fallback if none resolve. Keys this map exposes are ALSO the set
-- the wrap must capture — keep both in sync.
ScannerSurvey.DIGIT_KEYS = {};
for d = 0, 9 do
    local k = K[tostring(d)] or K["NUMBER_" .. d] or K["VK_" .. d] or K["D" .. d];
    if k ~= nil then ScannerSurvey.DIGIT_KEYS[k] = d; end
end

function ScannerSurvey.dispatch(key, mods)
    mods = mods or 0;
    local shift = (mods % 2) == 1;
    local alt   = (math.floor(mods / 4) % 2) == 1;

    -- S = survey, Alt+S = sonify.
    if KEY_S ~= nil and key == KEY_S then
        if alt then ScannerSurvey.sonify(); else ScannerSurvey.run(); end
        return true;
    end
    -- W = where am I, Shift+W = rich locate (routed to HexCursor in this VM).
    if KEY_W ~= nil and key == KEY_W then
        if shift then
            if HexCursor ~= nil and HexCursor.speakSurvey ~= nil then HexCursor.speakSurvey(); end
        else
            if HexCursor ~= nil and HexCursor.speakWhereAmI ~= nil then HexCursor.speakWhereAmI(); end
        end
        return true;
    end
    -- Category select (Alt+G/U/R).
    if alt then
        if KEY_G ~= nil and key == KEY_G then ScannerSurvey.selectCategory("all");       return true; end
        if KEY_U ~= nil and key == KEY_U then ScannerSurvey.selectCategory("units");     return true; end
        if KEY_R ~= nil and key == KEY_R then ScannerSurvey.selectCategory("resources"); return true; end
        -- Zoom: Alt+digit jump (Alt+0 resets to L1), Alt+= / Alt+- step.
        local d = ScannerSurvey.DIGIT_KEYS[key];
        if d ~= nil then ScannerSurvey.setZoom(d == 0 and 1 or d); return true; end
        if KEY_PLUS  ~= nil and key == KEY_PLUS  then ScannerSurvey.zoomStep(1);  return true; end
        if KEY_MINUS ~= nil and key == KEY_MINUS then ScannerSurvey.zoomStep(-1); return true; end
    end
    return false;
end

Log.info("ScannerSurvey.lua: loaded");
