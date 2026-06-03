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
-- Ported from Civ V Access's CivVAccess_HexGeom.lua, trimmed to the
-- functions HexCursor needs today: offsetToCube, decomposeCube,
-- nearestWrappedTo, originalCapitalPlot, absoluteCoords, relativeDirection.
-- The directionString / compassDirectionString / displacement / surveyor
-- helpers are deliberately omitted until a feature in this repo asks for
-- them.

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
    local dir = HexGeom.relativeDirection(capX, capY, x, y);
    if dir == nil then return "at capital"; end
    return dir .. " of capital";
end
