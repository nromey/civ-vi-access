-- WorldInputAccess.lua — capture-all input host, BASE ruleset (RULESET_STANDARD).
-- Registered via <ReplaceUIScript LuaContext="WorldInput">. Includes the unmodified
-- base WorldInput so the map plays normally, then the shared capture-all wrap.
include("Log");
Log.info("WorldInputAccess: ENTRY loaded (BASE ruleset) — our ReplaceUIScript won the WorldInput LuaContext.");
include("WorldInput.lua");
include("WorldInputAccessWrap");
