-- WorldInputAccess_XP2.lua — capture-all input host, Gathering Storm (RULESET_EXPANSION_2).
-- Includes the Expansion2 WorldInput replacement (which includes XP1 → base) then the wrap.
-- This is the path proven by the 2026-06-08 capture-all probe.
include("Log");
Log.info("WorldInputAccess: ENTRY loaded (XP2 / Gathering Storm) — our ReplaceUIScript won the WorldInput LuaContext.");
include("WorldInput_Expansion2.lua");
include("WorldInputAccessWrap");
