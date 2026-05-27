-- Speech gateway for Civ VI Access.
--
-- Every spoken line in the mod funnels through this file. The Lua side
-- does not talk to Tolk directly — it prints prefix-marked lines into
-- Civ VI's Lua.log, and the C# launcher (CivVIAccess.Launcher) tails
-- that log, parses the prefix, and routes the body to Tolk with the
-- right interrupt level. Two prefixes mean two routes:
--
--   #SCREENREADER -             interrupting (replaces in-flight speech)
--   #SCREENREADER[NOINTERRUPT] - queued (waits in line behind whatever
--                                is speaking now)
--
-- Both arms auto-strip Civ VI's inline icon markers ([ICON_Faith],
-- [ICON_Bullet], etc.) and double '%' to survive Civ VI's printf-style
-- print processing.
--
-- =====================================================================
-- Speech.emit(message, kind) — the preferred call shape (0.5.x onward).
-- =====================================================================
--
-- Background: a boolean interrupt flag isn't enough. When two emits
-- fire in quick succession both as interrupts, the second clobbers the
-- first. The classic failure is City founded → engine auto-selects
-- another unit → "Warrior" interrupt clobbers the "City of X founded
-- at coords. Population 1." announce mid-word. Boosting the city-
-- founded message's volume doesn't help; what's needed is a notion of
-- WHICH announce wins when two race.
--
-- Each emit declares a `kind`. Each kind has a priority and a shield
-- window (ms). When a kind fires, it installs a "shield": for the
-- next shield-window ms, any emit with strictly lower priority is
-- downgraded from interrupt to queued (NOINTERRUPT). Same-priority
-- emits queue unless the kind opts into coalesce, which lets a
-- same-kind emit replace its own prior in-flight speech (used for
-- engine double-fires and arrow-key mashes where the user only wants
-- the most recent state).
--
-- Kinds and their semantics:
--
--   critical    pri 10  shield 2000ms  major game state — turn begin,
--                                       city founded, victory, defeat
--   event       pri  8  shield 1500ms  user-driven game state change —
--                                       Fortify, Building Monument,
--                                       Researching Pottery
--   move_result pri  7  shield 1200ms  unit move outcome — "Moved west.
--                                       1 move remaining" / "Stopped
--                                       short". Coalesces (engine
--                                       multi-fires events for one move)
--   picker      pri  6  shield  600ms  picker preamble, group header,
--                                       item focus. Coalesces (arrow-
--                                       mash collapses to latest)
--   selection   pri  5  shield  400ms  unit / city selection. Coalesces
--   nav         pri  4  shield  200ms  cursor tile description.
--                                       Coalesces aggressively
--   meta        pri  3  shield  100ms  key-press feedback ("No unit
--                                       selected"), notification arrivals,
--                                       reminders. Coalesces
--   status      pri  2  no shield      query results (Ctrl+T, where-am-I,
--                                       unit info). Always queues —
--                                       user asked, don't clobber what's
--                                       in flight
--
-- =====================================================================
-- OutputMessageToScreenReader(message, nointerrupt) — back-compat shim.
-- =====================================================================
--
-- The 0.4.x API. 168 call sites at audit time. Each call routes
-- through the gateway as a "_legacy" kind so the shielding still
-- applies (legacy_interrupt rides selection-tier; legacy_queue rides
-- meta-tier). Migration is incremental — rewrite a file's emit sites
-- as Speech.emit(msg, "kind") one batch at a time; the back-compat
-- shim stays until every caller is migrated.
--
-- include("ScreenReader") in any companion to gain access to the
-- exported globals: Speech, OutputMessageToScreenReader, stripIconTags.

include("Log");

-- Marker prefixes. The kind is now embedded in the bracket alongside
-- any NOINTERRUPT flag so the launcher can apply cross-VM shielding
-- (the within-VM gateway can only see emits from its own Lua state;
-- a critical-tier announce in the gameplay VM doesn't shield a
-- selection-tier announce in the addin VM. The launcher sees ALL
-- log lines from ALL VMs and re-runs the shield logic globally).
local MARKER = "#SCREENREADER";

-- =====================================================================
-- Kind taxonomy. Tweak these numbers in one place to retune the whole
-- mod's speech priority. shield is in milliseconds (converted to
-- seconds at compare-time since os.clock returns float seconds).
-- =====================================================================

local KINDS = {
    critical    = { priority = 10, shield = 2000, coalesce = false },
    event       = { priority =  8, shield = 1500, coalesce = false },
    move_result = { priority =  7, shield = 1200, coalesce = true  },
    picker      = { priority =  6, shield =  600, coalesce = true  },
    selection   = { priority =  5, shield =  400, coalesce = true  },
    nav         = { priority =  4, shield =  200, coalesce = true  },
    meta        = { priority =  3, shield =  100, coalesce = true  },
    status      = { priority =  2, shield =    0, coalesce = false },
    -- Back-compat. Old callers that passed nointerrupt=false ride the
    -- interrupt path at selection-tier; those that passed true ride
    -- the queue path at meta-tier. Tagged legacy=true so the audit can
    -- count them and surface "still on legacy" call sites.
    _legacy_interrupt = { priority = 5, shield = 400, coalesce = false, legacy = true },
    _legacy_queue     = { priority = 3, shield = 100, coalesce = false, legacy = true },
};

-- Per-kind last-emit timestamp. Drives both shield checks (am I
-- still inside another kind's shield?) and coalesce detection (did
-- the same kind fire within its own shield window?).
local _emitTime = {};

-- One-shot warn dedup for unknown kinds. Without this, a typo in one
-- emit call site would spam the log on every fire.
local _unknownKindWarned = {};

local function timeNow()
    if os ~= nil and os.clock ~= nil then
        local ok, v = pcall(os.clock);
        if ok and v ~= nil then return v; end
    end
    return 0;
end

-- =====================================================================
-- Public helpers
-- =====================================================================

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

Speech = Speech or {};

-- Emit a screen-reader line classified by kind. Default kind is
-- _legacy_interrupt to keep parity with bare OutputMessageToScreenReader
-- calls (which is what the back-compat shim hands us when callers
-- haven't migrated yet).
function Speech.emit(message, kind)
    if message == nil then return; end
    kind = kind or "_legacy_interrupt";
    local def = KINDS[kind];
    if def == nil then
        if not _unknownKindWarned[kind] then
            _unknownKindWarned[kind] = true;
            Log.warn("Speech.emit: unknown kind '" .. tostring(kind)
                     .. "', routing as _legacy_interrupt (further occurrences silenced)");
        end
        kind = "_legacy_interrupt";
        def = KINDS[kind];
    end

    local body = stripIconTags(tostring(message));
    if body == "" then return; end
    body = body:gsub("%%", "%%%%");

    local now = timeNow();

    -- Shield check: any OTHER kind at >= my priority still inside its
    -- shield window? If so, downgrade to queued. Same-kind self-check
    -- happens separately below via the coalesce branch.
    local otherShielded = false;
    for k, kdef in pairs(KINDS) do
        if k ~= kind and kdef.priority >= def.priority and _emitTime[k] ~= nil then
            if (now - _emitTime[k]) < (kdef.shield / 1000) then
                otherShielded = true;
                break;
            end
        end
    end

    -- Same-kind back-to-back inside own shield window?
    local sameKindShield = (_emitTime[kind] ~= nil)
        and ((now - _emitTime[kind]) < (def.shield / 1000));

    -- Decision matrix:
    --   other higher/equal kind shielding → queue (NOINTERRUPT)
    --   same kind within own shield + coalesce → interrupt (replace
    --       our own prior in-flight speech with this fresh line)
    --   same kind within own shield + no coalesce → queue (so the
    --       user hears both back-to-back announces in order)
    --   clear path → interrupt
    local interrupt;
    if otherShielded then
        interrupt = false;
    elseif sameKindShield then
        interrupt = def.coalesce == true;
    else
        interrupt = true;
    end

    -- Emit format includes the kind so the launcher (C# side) can
    -- run the same shield/coalesce logic globally across VMs:
    --   #SCREENREADER[kind=critical] - body
    --   #SCREENREADER[NOINTERRUPT,kind=meta] - body
    -- The launcher may further downgrade interrupt → NOINTERRUPT if
    -- a higher-priority kind fired recently in any VM. Our in-VM
    -- decision still informs Tolk and provides defense-in-depth if
    -- the launcher is briefly behind on log-tail reads.
    if interrupt then
        print(MARKER .. "[kind=" .. kind .. "] - " .. body);
    else
        print(MARKER .. "[NOINTERRUPT,kind=" .. kind .. "] - " .. body);
    end

    _emitTime[kind] = now;
end

-- Back-compat shim. Routes the legacy boolean-flag callers through
-- Speech.emit so they get the shielding for free. Migration target:
-- zero legacy emits at runtime.
function OutputMessageToScreenReader(message: string, nointerrupt: boolean)
    if nointerrupt == true then
        Speech.emit(message, "_legacy_queue");
    else
        Speech.emit(message, "_legacy_interrupt");
    end
end
