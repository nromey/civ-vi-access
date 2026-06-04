Civ VI Access RE-TEST, 2026-06-03 fixes (after your first run)

Same format: type your result on the line under each colon. Save, tell me to pull it back.

Before testing: close game AND launcher, relaunch so the edited Lua/XML deploys. All changes are Lua/XML — no launcher rebuild. If a fix does nothing, first confirm the deployed mod matches source (the launcher embeds source; if it didn't redeploy, say so).

VERBOSITY IS NOW ON SHIFT+V (world AND menus — standardized, no side effects)

1. In the world, press Shift+V. You should hear "Verbose on". Shift+V again: "Verbose off". It should NEVER say "Alert":
nothing appears to happen
2. With it OFF (terse), move the cursor over tiles — brief line only. Press Shift+V to go on, move again — full datasheet (yields, water, defense, appeal, movement, continent):
pass
3. In a MENU (a setup screen, or in-game options): press Shift+V — should toggle verbosity there too, and should NOT type-ahead jump to an item starting with V:
pass, I tested it in the pause menu
4. Press Shift+V right after a notification fires (the case Alt+V used to mishandle as "Alert"). Should just toggle verbosity:
pass
WHERE-AM-I (Alt+S was dropped)

5. Bare S and Shift+S still speak coordinates as before:
pass
6. Alt+S now does nothing for coords (it was redundant + broken). Just confirm you didn't lose anything you used:
yep
DIPLOMACY (Alt+M debug meet)

7. Press Alt+M. You should hear the leader ONCE now — "Tokugawa of Japan" (NOT "Japanese Empire", and not said twice), their mood, the greeting, then "N options" and the first option:
pass
8. Arrow Up/Down through the options — each should read. THIS is the main fix (the modal used to tear down before you could arrow):
arrowing does nothing still ... Wait, now it's reading what the crap. It did hits after I hit shift+b, then when I press escape on that, it bropught me to diplomacy options
9. Ctrl+T re-reads the greeting while options are up:
nope, ctrl+t does nothing
10. Enter on a safe option — "Selecting <name>" or "Couldn't complete that selection" (either confirms the path):
Once 
if it's in the mode that you can arrow up and down, enter does work11. Escape — should now say "Closing diplomacy options" and close cleanly:
11. escape exits
escape exits but nothing said
12. NOTE: Alt+M is a debug path with no real session, so it may still behave oddly. If you get a real first contact, test there too — that's the true case:

LOAD SCREEN WORDING

13. New game — the briefing should now START with "Creating game." then the civ intro:
yep
14. Resume / load a save — the briefing should START with "Loading game." (this was the bug — it used to say Creating). Note: the word now leads the briefing instead of firing the instant the screen shows; tell me if the slight delay bothers you:
pass
BUILD PICKER (Shift+B with a Builder)

15. Find a locked WATER improvement (e.g. Offshore Oil Rig). It should now say both the tech AND the terrain, e.g. "needs Plastics; requires Coast or Ocean":
yes
ANYTHING ELSE

16. Anything wrong, doubled, or out of order:
not that I haven't mentioned, game is closed and ready for debug / analysis
