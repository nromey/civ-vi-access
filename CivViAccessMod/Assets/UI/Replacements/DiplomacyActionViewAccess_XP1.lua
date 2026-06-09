-- DiplomacyActionViewAccess_XP1.lua — accessible DiplomacyActionView, Rise &
-- Fall ruleset (RULESET_EXPANSION_1).
--
-- Registered via <ReplaceUIScript LuaContext="DiplomacyActionView"> gated on
-- criteria RULESET_EXPANSION_1. Includes the Expansion1 screen replacement
-- (which itself include()s the base) so the XP1 behaviour runs in our VM, then
-- the shared wrap. See DiplomacyActionViewWrap.lua for the architecture note.
include("Log");
Log.info("DiplomacyActionViewAccess: ENTRY loaded (XP1 / Rise & Fall) — our ReplaceUIScript won the DiplomacyActionView LuaContext.");
include("DiplomacyActionView_Expansion1.lua");
include("DiplomacyActionViewWrap");
