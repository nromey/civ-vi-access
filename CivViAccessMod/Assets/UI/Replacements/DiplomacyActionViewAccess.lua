-- DiplomacyActionViewAccess.lua — accessible DiplomacyActionView, BASE ruleset.
--
-- Registered via <ReplaceUIScript LuaContext="DiplomacyActionView"> gated on
-- criteria RULESET_STANDARD. We include() the unmodified base screen so all its
-- globals/Controls/handlers run in THIS context's VM exactly as Firaxis built
-- them, then include() the shared wrap, which captures the option lists and
-- re-registers the input handler for screen-reader navigation. See
-- DiplomacyActionViewWrap.lua for the full architecture note.
include("Log");
Log.info("DiplomacyActionViewAccess: ENTRY loaded (BASE ruleset) — our ReplaceUIScript won the DiplomacyActionView LuaContext.");
include("DiplomacyActionView.lua");
include("DiplomacyActionViewWrap");
