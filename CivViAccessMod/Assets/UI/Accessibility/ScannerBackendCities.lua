-- ScannerBackendCities.lua — scanner backend for CITIES. Walks every player's
-- cities, classifies each by relationship, gates on the city plot being revealed
-- (cities stay known once seen, like terrain — IsRevealed, not IsVisible).
--
-- Subcategories: mine / city_states / neutral / enemy. (barb_camps is a separate
-- improvement, not a city — deferred to the improvements backend.) Each city is
-- unique, so itemName = the city's name (one instance each); FormatName returns
-- the live decorated "American city Boston" via StringifyCity.

include("Log");
include("ScannerCore");
include("ScreenReaderPlotUtils");   -- StringifyCity

ScannerBackendCities = { name = "cities" };

local function localPlayerId()
    if Game == nil or Game.GetLocalPlayer == nil then return -1; end
    local ok, id = pcall(Game.GetLocalPlayer);
    return (ok and id ~= nil) and id or -1;
end

local function revealedPlot(vis, x, y)
    if vis == nil or vis.IsRevealed == nil then return true; end
    local ok, r = pcall(function() return vis:IsRevealed(x, y); end);
    return (not ok) or (r == true);
end

local function classify(localId, pid, player, localDiplo)
    if pid == localId then return "mine"; end
    local isMajor = false;
    if player.IsMajor ~= nil then
        local ok, m = pcall(function() return player:IsMajor(); end);
        isMajor = ok and m == true;
    end
    if isMajor then
        if localDiplo ~= nil and localDiplo.IsAtWarWith ~= nil then
            local ok, atWar = pcall(function() return localDiplo:IsAtWarWith(pid); end);
            if ok and atWar == true then return "enemy"; end
        end
        return "neutral";
    end
    -- Minor (city-state). Barbarians have no cities, so anything non-major here is
    -- a city-state.
    return "city_states";
end

local function plotIndexAt(x, y)
    if Map == nil or Map.GetPlot == nil then return nil; end
    local plot = nil;
    pcall(function() plot = Map.GetPlot(x, y); end);
    if plot == nil then return nil; end
    local ok, idx = pcall(function() return plot:GetIndex(); end);
    return (ok and idx ~= nil) and idx or nil;
end

function ScannerBackendCities.Scan(_activePlayer, _activeTeam)
    local out = {};
    local localId = localPlayerId();
    if localId < 0 or Players == nil then return out; end
    local localDiplo = nil;
    if Players[localId] ~= nil and Players[localId].GetDiplomacy ~= nil then
        pcall(function() localDiplo = Players[localId]:GetDiplomacy(); end);
    end
    local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;

    local maxPlayers = (GameDefines and GameDefines.MAX_PLAYERS) or 64;
    for pid = 0, maxPlayers - 1 do
        local player = Players[pid];
        if player ~= nil and player.GetCities ~= nil then
            local cities = player:GetCities();
            if cities ~= nil then
                for _, city in cities:Members() do
                    if city ~= nil then
                        local x, y = city:GetX(), city:GetY();
                        -- Own cities always; others only once their plot is revealed.
                        if x ~= nil and (pid == localId or revealedPlot(vis, x, y)) then
                            local plotIndex = plotIndexAt(x, y);
                            if plotIndex ~= nil then
                                out[#out + 1] = {
                                    plotIndex   = plotIndex,
                                    category    = "cities",
                                    subcategory = classify(localId, pid, player, localDiplo),
                                    itemName    = Locale.Lookup(city:GetName()),
                                    key         = "city:" .. pid .. ":" .. city:GetID(),
                                    data        = { owner = pid, cityId = city:GetID() },
                                };
                            end
                        end
                    end
                end
            end
        end
    end
    return out;
end

function ScannerBackendCities.ValidateEntry(entry, _cursorPlotHint)
    if Players == nil or entry.data == nil then return false; end
    local player = Players[entry.data.owner];
    if player == nil or player.GetCities == nil then return false; end
    local city = nil;
    pcall(function() city = player:GetCities():FindID(entry.data.cityId); end);
    if city == nil then return false; end
    local localId = localPlayerId();
    if entry.data.owner ~= localId then
        local vis = (PlayersVisibility ~= nil) and PlayersVisibility[localId] or nil;
        if not revealedPlot(vis, city:GetX(), city:GetY()) then return false; end
    end
    local idx = plotIndexAt(city:GetX(), city:GetY());
    if idx ~= nil then entry.plotIndex = idx; end
    return true;
end

function ScannerBackendCities.FormatName(entry)
    if Players ~= nil and entry.data ~= nil then
        local player = Players[entry.data.owner];
        if player ~= nil and player.GetCities ~= nil then
            local city = nil;
            pcall(function() city = player:GetCities():FindID(entry.data.cityId); end);
            if city ~= nil then
                local name = StringifyCity(city);
                if name ~= nil and name ~= "" then return name; end
            end
        end
    end
    return entry.itemName or "city";
end

Scanner.registerBackend(ScannerBackendCities);

Log.info("ScannerBackendCities.lua: loaded");
