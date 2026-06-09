-- WorldInputAccess_XP1.lua — capture-all input host, Rise & Fall (RULESET_EXPANSION_1).
-- Includes the Expansion1 WorldInput replacement (which includes base) then the wrap.
include("Log");
Log.info("WorldInputAccess: ENTRY loaded (XP1 / Rise & Fall) — our ReplaceUIScript won the WorldInput LuaContext.");
include("WorldInput_Expansion1.lua");
include("WorldInputAccessWrap");
