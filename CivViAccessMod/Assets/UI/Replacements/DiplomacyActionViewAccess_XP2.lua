-- DiplomacyActionViewAccess_XP2.lua — accessible DiplomacyActionView, Gathering
-- Storm ruleset (RULESET_EXPANSION_2).
--
-- Registered via <ReplaceUIScript LuaContext="DiplomacyActionView"> gated on
-- criteria RULESET_EXPANSION_2. Includes the Expansion2 screen replacement
-- (which include()s Expansion1 → base) so the full XP2 behaviour runs in our VM,
-- then the shared wrap. See DiplomacyActionViewWrap.lua for the architecture note.
include("Log");
Log.info("DiplomacyActionViewAccess: ENTRY loaded (XP2 / Gathering Storm) — our ReplaceUIScript won the DiplomacyActionView LuaContext.");
include("DiplomacyActionView_Expansion2.lua");
include("DiplomacyActionViewWrap");
