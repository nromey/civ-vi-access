-- Logging shim for Civ VI Access. Funnels diagnostic output through one
-- channel, tags every line with a level, and survives missing-print contexts.
--
-- Levels:
--   Log.debug - verbose internals; suppressed by default (raise via setLevel)
--   Log.info  - normal progress / lifecycle events
--   Log.warn  - recoverable abnormalities (missing optional API, fallback fired)
--   Log.error - unrecoverable; the calling feature will not function correctly
--
-- Every line goes to Civ VI's Lua.log via print(), prefixed so adopters and
-- users can grep:
--     [CivViAccess][INFO]  HandlerStack.push 'HexCursor' (depth=2)
--
-- Log lines are NEVER prefixed with #SCREENREADER. They go to Lua.log only;
-- the launcher's log-tail does not route them to Tolk.
--
-- Civ VI's print() does printf-style format processing on its argument, so
-- a stray '%' followed by a letter (e.g. "+15% Science") would be parsed as
-- a format spec, find no arg, and silently null the line. Same hazard
-- ScreenReader.lua handles; double the '%' before emitting.
--
-- This module is intentionally engine-agnostic: nothing here references
-- DirectionTypes / LuaEvents / UI.* or any other Civ-VI-specific API. It
-- ports as-is to future games per [[project-cross-game-foundation]].

Log = Log or {}

local LEVEL_DEBUG = 0
local LEVEL_INFO  = 1
local LEVEL_WARN  = 2
local LEVEL_ERROR = 3

local LEVEL_NAMES = { [0] = "DEBUG", [1] = "INFO ", [2] = "WARN ", [3] = "ERROR" }

-- Default to DEBUG so the diagnostic-instrumentation drop captures
-- everything during the in-game failure investigation. After we have a
-- working in-game baseline, dial back to INFO for normal play.
local _currentLevel = LEVEL_DEBUG

Log.LEVEL_DEBUG = LEVEL_DEBUG
Log.LEVEL_INFO  = LEVEL_INFO
Log.LEVEL_WARN  = LEVEL_WARN
Log.LEVEL_ERROR = LEVEL_ERROR

function Log.setLevel(level)
    _currentLevel = level
end

function Log.getLevel()
    return _currentLevel
end

local function emit(level, message)
    if level < _currentLevel then
        return
    end
    local body = tostring(message or "")
    body = body:gsub("%%", "%%%%")
    print("[CivViAccess][" .. LEVEL_NAMES[level] .. "] " .. body)
end

function Log.debug(message) emit(LEVEL_DEBUG, message) end
function Log.info(message)  emit(LEVEL_INFO,  message) end
function Log.warn(message)  emit(LEVEL_WARN,  message) end
function Log.error(message) emit(LEVEL_ERROR, message) end

-- Run fn under pcall; log an error with label on throw. Returns true on
-- success, false on throw. Use anywhere a handler-author-supplied callback
-- should not crash the whole stack (onActivate, onSuspend, onDeactivate,
-- binding fn, etc.). Variadic args are passed through to fn.
--
-- Return values from fn are deliberately not surfaced — Havok Script's
-- table.unpack support is iffy, and the common case is "fire and forget."
-- If a future caller needs the call's return, add a `tryCallReturn` variant
-- rather than complicating the hot path.
function Log.tryCall(label, fn, ...)
    if type(fn) ~= "function" then
        Log.warn("Log.tryCall '" .. tostring(label) .. "': not a function")
        return false
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        Log.error(tostring(label) .. " failed: " .. tostring(err))
        return false
    end
    return true
end
