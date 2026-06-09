-- Hex-grid math for spoken positional info.
--
-- Civ VI uses pointy-top hexes with odd-row offset coordinates: even rows
-- (y % 2 == 0) sit half a column LEFT of the rows above and below them.
-- Direct math on raw (x, y) breaks for any diagonal — a NE step from row 0
-- to row 1 keeps the same x but covers a half-column to the east, and the
-- arithmetic difference shows zero when the spatial difference is +0.5.
-- The cube-coordinate detour (q = x - (y - y%2)/2, r = y; cube = q, -q-r, r)
-- linearizes the geometry so deltas decompose cleanly.
--
-- Map-wrap folding: most Civ VI maps wrap east-west (the world is a globe).
-- Civ VI doesn't expose a public Map.IsWrapX() / Map.IsWrapY() — base UI
-- never queries them — so we default to wrapX=true / wrapY=false, matching
-- the standard map shapes. Wrong-side seam reads on non-wrap maps are the
-- only failure mode and are minor (the magnitude is still right; only the
-- direction half flips). Revisit if a wrap API surfaces.
--
-- Ported from Civ V Access's CivVAccess_HexGeom.lua: offsetToCube,
-- decomposeCube, nearestWrappedTo, originalCapitalPlot, absoluteCoords,
-- relativeDirection, plus the direction-vocabulary layer (displacement,
-- bearingAngle, compass/clock/degrees rendering, and the mode dispatcher
-- directionString). The mode is a runtime toggle (Shift+D today; a settings
-- entry later) so the same delta can be spoken as hex decomposition,
-- 8-point compass, clock face, or navigation degrees — the user's choice.

include("Log");

HexGeom = HexGeom or {};

-- Civ VI's Map.IsWrapX() isn't exposed; default. See file header comment.
local ASSUMED_WRAP_X = true;
local ASSUMED_WRAP_Y = false;

-- Odd-row offset -> cube. Lua's % is Civ-VI-Havok-safe (returns float for
-- integer inputs, but the math is exact for integers in this range).
local function offsetToCube(col, row)
    local q = col - (row - (row % 2)) / 2;
    local r = row;
    -- Cube (x, y, z) = (q, -q - r, r).
    return q, -q - r, r;
end

-- Fold (toX, toY) to its nearest virtual position relative to (fromX, fromY)
-- across map wrap. The return is no longer guaranteed to be a real on-grid
-- index, but the cube delta computed from it is the shortest-path delta.
-- Strict inequality at the antipode keeps dx = +/-W/2 on whichever side it
-- landed.
local function nearestWrappedTo(fromX, fromY, toX, toY)
    local dx = toX - fromX;
    local dy = toY - fromY;
    if ASSUMED_WRAP_X then
        local w = Map.GetGridSize();
        local half = w / 2;
        if dx > half then
            dx = dx - w;
        elseif dx < -half then
            dx = dx + w;
        end
    end
    if ASSUMED_WRAP_Y then
        local _, h = Map.GetGridSize();
        local half = h / 2;
        if dy > half then
            dy = dy - h;
        elseif dy < -half then
            dy = dy + h;
        end
    end
    return fromX + dx, fromY + dy;
end

-- Screen-space column/row displacement of the (from)->(to) delta, with map
-- wrap folded in. Odd rows sit half a column east of even rows, so the +0.5
-- offset-per-odd-row term puts each hex on its true horizontal position; the
-- result (dcol, drow) is what bearingAngle scales into a unit-circle angle.
-- Ported verbatim from Civ V Access (the offset convention is identical —
-- this matches the cube math in offsetToCube above).
local function displacement(fromX, fromY, toX, toY)
    toX, toY = nearestWrappedTo(fromX, fromY, toX, toY);
    local dcol = (toX + 0.5 * (toY % 2)) - (fromX + 0.5 * (fromY % 2));
    local drow = toY - fromY;
    return dcol, drow;
end

-- Pixel-space bearing of the (from)->(to) delta, radians CCW from east,
-- normalized to [0, 2pi). nil at zero delta. Pointy-top column step is
-- sqrt(3) wide, row step is 1.5 tall; scaling (dcol, drow) by those puts each
-- hex neighbour on its true angle (NE at 60 degrees, not 45). E=0, N=pi/2,
-- W=pi, S=3pi/2. Shared by the compass / clock / degrees renderers so all
-- three speak the same underlying bearing. Y increases northward in the Civ
-- engine, so drow>0 (target to the north) lands in the upper half-circle.
local function bearingAngle(fromX, fromY, toX, toY)
    if fromX == toX and fromY == toY then return nil; end
    local dcol, drow = displacement(fromX, fromY, toX, toY);
    local angle = math.atan2(drow * 1.5, dcol * math.sqrt(3));   -- (-pi, pi]
    if angle < 0 then angle = angle + 2 * math.pi; end
    return angle;
end

-- Hex (cube) distance between two offset coords — the step count the player
-- spends to move there. Map.GetPlotDistance is the engine's own hex distance
-- (same metric the scanner sorts by), so the spoken "N hexes" matches travel.
local function hexDistance(fromX, fromY, toX, toY)
    if Map ~= nil and Map.GetPlotDistance ~= nil then
        return Map.GetPlotDistance(fromX, fromY, toX, toY);
    end
    return 0;
end

-- Cube delta D decomposes into a*u + b*v where (u, v) is one of the six
-- adjacent CW pairs from E. Each pair has a closed-form solution; pick
-- the first one whose (a, b) are both non-negative.
local function decomposeCube(dx, dy, dz)
    local counts = { E = 0, SE = 0, SW = 0, W = 0, NW = 0, NE = 0 };
    if dy <= 0 and dz <= 0 then
        counts.E, counts.SE = -dy, -dz;
    elseif dx >= 0 and dy >= 0 then
        counts.SE, counts.SW = dx, dy;
    elseif dz <= 0 and dx <= 0 then
        counts.SW, counts.W = -dz, -dx;
    elseif dy >= 0 and dz >= 0 then
        counts.W, counts.NW = dy, dz;
    elseif dx <= 0 and dy <= 0 then
        counts.NW, counts.NE = -dx, -dy;
    else
        counts.NE, counts.E = dz, dx;
    end
    return counts;
end

-- Fixed CW-from-E speaking order so the user always hears "5 east, 3
-- southeast" not "3 southeast, 5 east" regardless of which pair the
-- decompose chose. Matches Civ V Access's mental model.
local OUTPUT_ORDER = {
    { dir = "E",  name = "east" },
    { dir = "SE", name = "southeast" },
    { dir = "SW", name = "southwest" },
    { dir = "W",  name = "west" },
    { dir = "NW", name = "northwest" },
    { dir = "NE", name = "northeast" },
};

-- Locate the active player's original capital and return its (x, y) plot
-- coords. The original-capital flag travels with the city object on
-- capture (the original-capital city can sit under any owner today; the
-- flag persists), so we scan every player's cities looking for one where
-- GetOriginalOwner() == active player AND IsOriginalCapital(). Returns
-- (nil, nil) before the active player has founded their first city.
function HexGeom.originalCapitalPlot()
    local activePlayer = Game.GetLocalPlayer();
    if activePlayer == nil or activePlayer < 0 then return nil, nil; end
    local maxPlayers = (GameDefines and GameDefines.MAX_CIV_PLAYERS) or 64;
    for playerId = 0, maxPlayers - 1 do
        local player = Players[playerId];
        if player ~= nil then
            local cities = player:GetCities();
            if cities ~= nil then
                for _, city in cities:Members() do
                    if city.GetOriginalOwner ~= nil and city.IsOriginalCapital ~= nil then
                        local origOwnerOk, origOwner = pcall(function() return city:GetOriginalOwner(); end);
                        local isOrigCapOk, isOrigCap = pcall(function() return city:IsOriginalCapital(); end);
                        if origOwnerOk and isOrigCapOk
                           and origOwner == activePlayer
                           and isOrigCap == true then
                            return city:GetX(), city:GetY();
                        end
                    end
                end
            end
        end
    end
    return nil, nil;
end

-- Absolute coords, spoken as "X 47, Y 23". Useful for orientation when
-- the capital hasn't been founded yet (pre-settle window) or when the
-- player wants raw position for debugging.
function HexGeom.absoluteCoords(x, y)
    return "X " .. tostring(x) .. ", Y " .. tostring(y);
end

-- Hex-direction decomposition of the vector FROM (fromX,fromY) TO (toX,toY),
-- spoken as "5 east, 3 southeast" (no anchor suffix). Returns nil for the same
-- tile. Shared by relativeToCapital and the cursor survey (nearest-city bearing).
function HexGeom.relativeDirection(fromX, fromY, toX, toY)
    if fromX == toX and fromY == toY then return nil; end
    local twX, twY = nearestWrappedTo(fromX, fromY, toX, toY);
    local fx, fy, fz = offsetToCube(fromX, fromY);
    local tx, ty, tz = offsetToCube(twX, twY);
    local counts = decomposeCube(tx - fx, ty - fy, tz - fz);
    local parts = {};
    for _, d in ipairs(OUTPUT_ORDER) do
        local n = counts[d.dir];
        if n > 0 then parts[#parts + 1] = tostring(n) .. " " .. d.name; end
    end
    if #parts == 0 then return nil; end
    return table.concat(parts, ", ");
end

-- Direction-decomposed relative to the original capital, spoken as
-- "5 east, 3 southeast of capital." Returns nil when the active player
-- has no original capital yet — caller should fall back to absolute
-- coords or speak "no capital yet" depending on context.
function HexGeom.relativeToCapital(x, y)
    local capX, capY = HexGeom.originalCapitalPlot();
    if capX == nil then return nil; end
    if capX == x and capY == y then return "at capital"; end
    -- Mode-aware so the where-am-I bearing follows the user's direction
    -- vocabulary (Shift+D) just like the scanner does.
    local dir = HexGeom.directionString(capX, capY, x, y);
    if dir == nil then return "at capital"; end
    return dir .. " of capital";
end

-- ===========================================================================
-- Direction vocabulary: hex (default) / compass / clock / degrees.
--
-- One runtime mode decides how a (from)->(to) delta is spoken. Hex mode keeps
-- the two-axis decomposition ("5 east, 3 southeast") that implies its own
-- distance; the other three collapse the delta to a single bearing and append
-- the hex distance ("northeast, 6 hexes" / "2 o'clock, 6 hexes" / "60 degrees,
-- 6 hexes"). All phrasing comes from LOC_CIVVIACCESS_DIR_* so it localizes and
-- the wording lives in one place. cycleDirectionMode (Shift+D, forwarded into
-- this VM) rotates the mode and speaks its name.
-- ===========================================================================

-- 8-point compass: bin angle into pi/4 slots CCW from east, same as Civ V.
-- Index -> the compass LOC tag. N and S exist here even though a hex grid has
-- no pure N/S step — they're where an endpoint delta's diagonal parts cancel.
local COMPASS_LOC = {
    [0] = "LOC_CIVVIACCESS_DIR_COMPASS_E",
    [1] = "LOC_CIVVIACCESS_DIR_COMPASS_NE",
    [2] = "LOC_CIVVIACCESS_DIR_COMPASS_N",
    [3] = "LOC_CIVVIACCESS_DIR_COMPASS_NW",
    [4] = "LOC_CIVVIACCESS_DIR_COMPASS_W",
    [5] = "LOC_CIVVIACCESS_DIR_COMPASS_SW",
    [6] = "LOC_CIVVIACCESS_DIR_COMPASS_S",
    [7] = "LOC_CIVVIACCESS_DIR_COMPASS_SE",
};

local function compassPhrase(fromX, fromY, toX, toY, angle)
    local index = math.floor(angle / (math.pi / 4) + 0.5) % 8;
    local dir = Locale.Lookup(COMPASS_LOC[index]);
    local dist = hexDistance(fromX, fromY, toX, toY);
    return Locale.Lookup("LOC_CIVVIACCESS_DIR_COMPASS_PHRASE", dist, dir);
end

-- Clock face: 12 = north, 3 = east, 6 = south, 9 = west (clockwise). The
-- bearing runs CCW from east, so hour = 3 - angle*6/pi, rounded, folded into
-- 1..12. Verified: E->3, N->12, W->9, S->6.
local function clockPhrase(fromX, fromY, toX, toY, angle)
    local raw = 3 - angle * 6 / math.pi;
    local h = math.floor(raw + 0.5);
    h = ((h - 1) % 12 + 12) % 12 + 1;
    local dist = hexDistance(fromX, fromY, toX, toY);
    return Locale.Lookup("LOC_CIVVIACCESS_DIR_CLOCK_PHRASE", dist, h);
end

-- Navigation degrees: N = 0, E = 90, S = 180, W = 270 (clockwise from north).
-- heading = (90 - deg(angle)) mod 360, rounded to the nearest 5 to keep it
-- speakable. Verified: E->90, N->0, W->270, S->180.
local function degreesPhrase(fromX, fromY, toX, toY, angle)
    local heading = (90 - math.deg(angle)) % 360;
    heading = (math.floor(heading / 5 + 0.5) * 5) % 360;
    local dist = hexDistance(fromX, fromY, toX, toY);
    return Locale.Lookup("LOC_CIVVIACCESS_DIR_DEGREES_PHRASE", dist, heading);
end

-- Runtime mode. Idempotent on re-include (Civ VI re-runs included files), so
-- a toggle set before a reload survives. Default "hex" matches prior behavior.
HexGeom._directionMode = HexGeom._directionMode or "hex";

local MODE_ORDER = { "hex", "compass", "clock", "degrees" };
local MODE_LOC = {
    hex     = "LOC_CIVVIACCESS_DIR_MODE_HEX",
    compass = "LOC_CIVVIACCESS_DIR_MODE_COMPASS",
    clock   = "LOC_CIVVIACCESS_DIR_MODE_CLOCK",
    degrees = "LOC_CIVVIACCESS_DIR_MODE_DEGREES",
};

-- Mode-aware direction text for the (from)->(to) delta. nil at the same tile
-- (callers fall back to "Here"). Hex mode delegates to relativeDirection (no
-- distance suffix — the decomposition carries it); the bearing modes append
-- the hex distance. This is the single seam the scanner / surveyor / cursor
-- call so a mode change reaches every spoken direction at once.
function HexGeom.directionString(fromX, fromY, toX, toY)
    if fromX == toX and fromY == toY then return nil; end
    local mode = HexGeom._directionMode or "hex";
    if mode == "hex" then
        return HexGeom.relativeDirection(fromX, fromY, toX, toY);
    end
    local angle = bearingAngle(fromX, fromY, toX, toY);
    if angle == nil then return nil; end
    if     mode == "compass" then return compassPhrase(fromX, fromY, toX, toY, angle);
    elseif mode == "clock"   then return clockPhrase(fromX, fromY, toX, toY, angle);
    elseif mode == "degrees" then return degreesPhrase(fromX, fromY, toX, toY, angle);
    end
    return HexGeom.relativeDirection(fromX, fromY, toX, toY);   -- unknown -> hex
end

function HexGeom.getDirectionMode()
    return HexGeom._directionMode or "hex";
end

-- Set the mode directly (the future settings entry calls this). Ignores an
-- unknown value. Returns the spoken mode name (or nil if unchanged/invalid).
function HexGeom.setDirectionMode(mode)
    if MODE_LOC[mode] == nil then return nil; end
    HexGeom._directionMode = mode;
    return Locale.Lookup(MODE_LOC[mode]);
end

-- Advance to the next mode and return its spoken name (for the toggle key).
function HexGeom.cycleDirectionMode()
    local cur = HexGeom._directionMode or "hex";
    local idx = 1;
    for i, m in ipairs(MODE_ORDER) do
        if m == cur then idx = i; break; end
    end
    idx = (idx % #MODE_ORDER) + 1;
    HexGeom._directionMode = MODE_ORDER[idx];
    return Locale.Lookup(MODE_LOC[HexGeom._directionMode]);
end
