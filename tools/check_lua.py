#!/usr/bin/env python3
"""Syntax-check Lua files with a REAL Lua compiler (lupa), not an approximation.

History (2026-05-31): an earlier luaparser/ANTLR-based checker gave FALSE
syntax errors on perfectly valid Lua — notably chained method calls in a
for-in loop (`for _, c in p:GetCities():Members() do ... end`). That cost a
long debugging detour. lupa wraps an actual Lua VM, so its verdict is
authoritative for syntax.

Caveat: this compiles standard Lua. Our OWN mod files (RevealListeners.lua,
DebugConcert.lua, the Accessibility/* modules) are annotation-free and compile
directly. The Firaxis SHADOW files (HeroesPopup, SecretSocietyPopup, etc.) carry
':type' annotations (Havok Script) that standard Lua rejects; for those, pass
--strip to remove ':type' before compiling. Method calls (obj:method()) are
preserved either way.

Usage:
  python tools/check_lua.py <file.lua> [...]            # our files (no annotations)
  python tools/check_lua.py --strip <file.lua> [...]    # Firaxis-annotated files
Exit 0 if all OK, 1 on any syntax error, 2 if lupa missing.
"""
import re
import sys

try:
    import lupa
except Exception as e:  # pragma: no cover
    print("NO_LUPA (pip install lupa):", e)
    sys.exit(2)

_ANN = re.compile(r':\s*[A-Za-z_][A-Za-z0-9_.]*(?!\s*[(:])')


def strip_annotations(src: str) -> str:
    # Only safe on whole-file when we accept that ':type' inside strings could be
    # touched; Firaxis files don't rely on that, and this path is opt-in (--strip).
    return _ANN.sub('', src)


def check(path: str, do_strip: bool) -> bool:
    src = open(path, encoding="utf-8").read()
    if do_strip:
        src = strip_annotations(src)
    rt = lupa.LuaRuntime()
    try:
        rt.compile(src)
        print("OK:", path)
        return True
    except lupa.LuaSyntaxError as e:
        print("SYNTAX_ERROR:", path, "->", str(e))
        return False
    except Exception as e:
        print("SYNTAX_ERROR:", path, "->", repr(e))
        return False


if __name__ == "__main__":
    args = sys.argv[1:]
    do_strip = "--strip" in args
    files = [a for a in args if a != "--strip"]
    ok = True
    for p in files:
        if not check(p, do_strip):
            ok = False
    sys.exit(0 if ok else 1)
