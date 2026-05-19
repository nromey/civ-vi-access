-- Speech gateway for Civ VI Access.
--
-- Every spoken line in the mod funnels through OutputMessageToScreenReader.
-- The Lua side does not talk to Tolk directly — it prints prefix-marked
-- lines into Civ VI's Lua.log, and the C# launcher (CivVIAccess.Launcher)
-- tails that log, parses the prefix, and routes the body to Tolk with the
-- right interrupt level. Two prefixes mean two routes:
--
--   #SCREENREADER -             interrupting (replaces in-flight speech)
--   #SCREENREADER[NOINTERRUPT] - queued (waits in line behind whatever is
--                                speaking now)
--
-- Both arms also auto-strip Civ VI's inline icon markers ([ICON_Faith],
-- [ICON_Bullet], etc.) so callers can pass raw button labels straight
-- through. The launcher does not need to know about icon tags — they're
-- gone by the time the log line is written.
--
-- include("ScreenReader") in any companion to gain access to the two
-- exported globals: OutputMessageToScreenReader and stripIconTags.

local PREFIX_INTERRUPT    : string = "#SCREENREADER - ";
local PREFIX_NO_INTERRUPT : string = "#SCREENREADER[NOINTERRUPT] - ";

-- Civ VI's UI text frequently embeds inline icon markers — "[ICON_Faith]",
-- "[ICON_Bullet]", "[ICON_GreatPerson_Individual]" — that the engine renders
-- as small graphics inline with the surrounding text. Spoken literally by a
-- screen reader these come out as "icon faith production five" which is
-- meaningless. We strip them, then collapse the whitespace they leave behind
-- so the body reads cleanly. The regex matches [ICON_<anything-but-]>] so
-- nested or malformed tags don't escape, and the whitespace pass handles
-- both interior runs and leading/trailing space.
function stripIconTags(text)
    if text == nil or text == "" then
        return "";
    end
    text = string.gsub(text, "%[ICON_[^%]]*%]", "");
    text = string.gsub(text, "%s+", " ");
    text = string.gsub(text, "^%s+", "");
    text = string.gsub(text, "%s+$", "");
    return text;
end

-- message:     the line to speak. Icon markers are stripped automatically;
--              callers don't need to pre-strip.
-- nointerrupt: false / nil (default) speaks immediately, cutting whatever
--              Tolk is currently saying. true queues the line behind
--              in-flight speech. Use noninterrupt for status announcements
--              that aren't a direct reaction to a keystroke, so the user's
--              own navigation cues don't get clobbered by background events.
function OutputMessageToScreenReader(message: string, nointerrupt: boolean)
    if message == nil then
        return;
    end
    local body = stripIconTags(tostring(message));
    if body == "" then
        return;
    end
    -- Civ VI's print runs printf-style format processing on its argument,
    -- so a stray '%' followed by a letter (e.g. "+15% Science") is parsed
    -- as a format spec, finds no arg, and silently nulls the entire
    -- output line — the body never reaches Lua.log and the screen reader
    -- speaks nothing. This was hit by city-state Suzerain bonuses that
    -- contain percent-yield language (Geneva, Taruga). Double the '%' so
    -- the format processor emits a literal '%' instead.
    body = body:gsub("%%", "%%%%");
    if nointerrupt == true then
        print(PREFIX_NO_INTERRUPT .. body);
    else
        print(PREFIX_INTERRUPT .. body);
    end
end
