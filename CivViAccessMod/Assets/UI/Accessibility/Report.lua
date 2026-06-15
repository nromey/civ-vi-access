-- Report.lua — WebView2 report emitter (the mod half of the report bridge).
--
-- Civ VI's Lua sandbox can't draw accessible rich text (its UI labels
-- don't expose to UIA well) and can't write files (no io). So a "report"
-- is streamed to the launcher over the SAME channel speech uses: lines
-- print()ed into Lua.log. The launcher's ReportBridge picks up our
-- #SHOWREPORT markers, reassembles the HTML, wraps it in an accessible
-- page shell, and renders it in a WebView2 window the screen reader
-- navigates in browse mode (headings, lists, tables, links — all free).
--
-- Wire protocol (each is one print() = one log line; the engine prefixes
-- every print with "Context: ", which the launcher matches past):
--
--   #SHOWREPORT[begin] - <title>     start; body of this line is the title
--   #SHOWREPORT[chunk] - <fragment>  one HTML body fragment (appended verbatim)
--   #SHOWREPORT[end]                 launcher renders + shows the window
--
-- Why chunked: one print is one log line, so framing the body as many
-- small marker lines sidesteps any per-line length cap and the engine
-- prefix. The launcher concatenates [chunk] bodies with NO separator, so
-- callers may pass a table of HTML fragments (or one big string) freely.
--
-- The mod sends HTML BODY content only; the page shell + styling live in
-- the launcher so every report is consistent and this stays simple.
--
-- include("Report") to gain the global Report table. Depends on Log.

include("Log");

Report = Report or {};

local MARKER = "#SHOWREPORT";

-- Conservative per-print payload size. Comfortably under anything Civ VI
-- has shown trouble with; oversized fragments are split across chunks.
local MAX_CHUNK = 700;

-- Escape % so Civ VI's printf-style print() doesn't consume it, matching
-- ScreenReader.lua's convention. The logged text comes out with a single
-- % per %%, so the launcher reads correct HTML.
local function emit(s)
    print((s:gsub("%%", "%%%%")));
end

local function emitChunk(fragment)
    local s = tostring(fragment or "");
    -- Split oversized fragments at raw character boundaries. The launcher
    -- joins chunks with no separator, so the split is seamless in the HTML.
    while #s > MAX_CHUNK do
        emit(MARKER .. "[chunk] - " .. s:sub(1, MAX_CHUNK));
        s = s:sub(MAX_CHUNK + 1);
    end
    emit(MARKER .. "[chunk] - " .. s);
end

-- Show a report in the launcher's WebView2 window.
--   title  short window/heading title (plain text)
--   body   HTML body content — either a single string, or an array of
--          HTML fragments concatenated verbatim (so a caller can build a
--          table of lines without worrying about separators)
function Report.show(title, body)
    title = tostring(title or "Civ VI Access");
    if Log ~= nil and Log.info ~= nil then
        Log.info("Report.show: emitting report '" .. title .. "'");
    end
    emit(MARKER .. "[begin] - " .. title);
    if type(body) == "table" then
        for _, fragment in ipairs(body) do
            emitChunk(fragment);
        end
    elseif body ~= nil then
        emitChunk(body);
    end
    emit(MARKER .. "[end]");
end

-- "Turn X of Y" (or just "Turn X" when the game has no hard turn limit),
-- matching the on-screen turn counter exactly (mirrors TopPanel.lua's
-- RefreshTurnsRemaining). GetGameEndTurn is EXCLUSIVE — the turn AFTER the last
-- playable one — and the displayed counter normalizes by the start turn when the
-- ruleset advertises CAPABILITY_DISPLAY_NORMALIZED_TURN (so a later-era start
-- still reads "Turn 1"). Pass a raw GetCurrentGameTurn value (the empire report
-- passes the current turn; the end-of-turn report passes the turn that ended);
-- omit the arg to use the current turn. Game speed sets the cap (Standard 500,
-- Quick 330, Online 250, Epic 750, Marathon 1500); the player picked it at setup.
function Report.turnPhrase(rawTurn)
    local turn = rawTurn;
    if turn == nil then
        turn = (Game ~= nil and Game.GetCurrentGameTurn ~= nil) and Game.GetCurrentGameTurn() or 0;
    end
    local endTurn = (Game ~= nil and Game.GetGameEndTurn ~= nil) and Game.GetGameEndTurn() or 0;
    local normalized = GameCapabilities ~= nil and GameCapabilities.HasCapability ~= nil
                       and GameCapabilities.HasCapability("CAPABILITY_DISPLAY_NORMALIZED_TURN");
    local startTurn = (GameConfiguration ~= nil and GameConfiguration.GetStartTurn ~= nil)
                      and GameConfiguration.GetStartTurn() or 0;
    if normalized then
        turn = (turn - startTurn) + 1;
        if endTurn > 0 then endTurn = endTurn - startTurn; end
    end
    if endTurn > 0 then
        local maxT = normalized and endTurn or (endTurn - 1);
        return "Turn " .. tostring(turn) .. " of " .. tostring(maxT);
    end
    return "Turn " .. tostring(turn);
end

-- Smoke test: a sample report exercising headings, a list, a table, and
-- an external link, so we can confirm the full Lua -> log -> launcher ->
-- WebView2 pipe and that browse-mode navigation works.
function Report.showTest()
    local body = {
        "<p class='muted'>WebView2 report bridge smoke test.</p>",
        "<h2>Headings, lists, and tables render</h2>",
        "<ul>",
        "<li>The screen reader navigates this like a web page (browse mode).</li>",
        "<li>Jump by heading (H), by link (K), by table (T).</li>",
        "<li>Escape closes the window and returns you to the game.</li>",
        "</ul>",
        "<h2>A small table</h2>",
        "<table><tr><th>City</th><th>Producing</th><th>Turns</th></tr>",
        "<tr><td>Capital</td><td>Monument</td><td>3</td></tr>",
        "<tr><td>Second City</td><td>Warrior</td><td>5</td></tr></table>",
        "<p>External links open in your browser: ",
        "<a href='https://github.com/nromey/civ-vi-access'>the project page</a>.</p>",
    };
    Report.show("Report bridge test", body);
end
