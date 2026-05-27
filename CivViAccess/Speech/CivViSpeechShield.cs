namespace CivVIAccess.Launcher.Speech;

// Global per-kind speech shield. Mirrors the Lua-side gateway logic
// in CivViAccessMod/Assets/UI/Accessibility/ScreenReader.lua but
// operates ACROSS Lua VMs.
//
// Civ VI runs separate Lua state instances per Context (gameplay
// scripts vs each UI addin). Each VM has its own copy of Speech and
// its own _emitTime table; a critical-tier emit in the gameplay VM
// can't shield a selection-tier emit in the addin VM, so back-to-back
// emits from different VMs land in Tolk as interrupts and clobber.
//
// This class lives in the launcher (one process tailing one log file),
// sees every #SCREENREADER line from every VM, and re-runs the
// shield/coalesce decision globally. Output: a downgrade decision —
// "the line you parsed as INTERRUPT should actually be NOINTERRUPT
// because <higher-priority kind> fired <X ms> ago in some other VM."
//
// Kind taxonomy and shield windows MUST stay in sync with the Lua
// KINDS table. If you change one, change both.
public sealed class CivViSpeechShield
{
    private sealed record KindDef(int Priority, int ShieldMs, bool Coalesce);

    private static readonly Dictionary<string, KindDef> Kinds = new()
    {
        ["critical"]    = new(Priority: 10, ShieldMs: 2000, Coalesce: false),
        ["event"]       = new(Priority:  8, ShieldMs: 1500, Coalesce: false),
        ["move_result"] = new(Priority:  7, ShieldMs: 1200, Coalesce: true),
        ["picker"]      = new(Priority:  6, ShieldMs:  600, Coalesce: true),
        ["selection"]   = new(Priority:  5, ShieldMs:  400, Coalesce: true),
        ["nav"]         = new(Priority:  4, ShieldMs:  200, Coalesce: true),
        ["meta"]        = new(Priority:  3, ShieldMs:  100, Coalesce: true),
        ["status"]      = new(Priority:  2, ShieldMs:    0, Coalesce: false),
        // Legacy fallbacks for any path still calling the back-compat
        // shim. Match the Lua _legacy_interrupt / _legacy_queue values.
        ["_legacy_interrupt"] = new(Priority: 5, ShieldMs: 400, Coalesce: false),
        ["_legacy_queue"]     = new(Priority: 3, ShieldMs: 100, Coalesce: false),
    };

    private readonly Dictionary<string, DateTime> _emitTime = new();
    private readonly object _lock = new();

    // Decide whether an emit of `kind` should be downgraded from
    // interrupt to NOINTERRUPT given recent emits across all VMs.
    // Records this emit's time as a side effect (always, including
    // unknown kinds — so a future emit of the same unknown kind
    // gets the coalesce treatment).
    //
    // Returns true iff the caller should treat this emit as queued
    // instead of interrupting. The decision is symmetric to the
    // Lua gateway:
    //   - Other kind with priority >= mine inside its shield → queue
    //   - Same kind inside own shield + coalesce=false           → queue
    //   - Same kind inside own shield + coalesce=true            → interrupt
    //   - Clear path                                             → interrupt
    public bool ShouldDowngradeToQueue(string kind)
    {
        if (string.IsNullOrEmpty(kind))
        {
            return false;
        }

        if (!Kinds.TryGetValue(kind, out var def))
        {
            // Unknown kind (typo, version skew with Lua side). Don't
            // shield; just record so coalescing within unknown-kind
            // works if it ever repeats. The Lua gateway already warns
            // about unknown kinds at the source.
            lock (_lock) { _emitTime[kind] = DateTime.UtcNow; }
            return false;
        }

        var now = DateTime.UtcNow;
        bool downgrade = false;

        lock (_lock)
        {
            // Check shield from any OTHER kind at >= my priority.
            foreach (var (otherKind, otherDef) in Kinds)
            {
                if (otherKind == kind) continue;
                if (otherDef.Priority < def.Priority) continue;
                if (_emitTime.TryGetValue(otherKind, out var t)
                    && (now - t).TotalMilliseconds < otherDef.ShieldMs)
                {
                    downgrade = true;
                    break;
                }
            }

            // Same-kind back-to-back: coalesce flag decides.
            if (!downgrade
                && _emitTime.TryGetValue(kind, out var sameT)
                && (now - sameT).TotalMilliseconds < def.ShieldMs
                && !def.Coalesce)
            {
                downgrade = true;
            }

            // Record AFTER deciding, so this emit's time doesn't
            // poison its own check.
            _emitTime[kind] = now;
        }

        return downgrade;
    }
}
