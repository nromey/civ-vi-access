# Audio Description — runtime insertion points & timing models

Where, in the live mod, audio description (AD) can be injected — and the
timing models available at each point. This is the *delivery* side; the
*production* pipeline (extract → AI-describe → human-edit → TTS-render) lives in
the AD production plan memory and is unchanged. This doc answers the question
that plan doesn't: **once an AD asset exists, at what code hook does it play, and
how is it timed against the cinematic?**

Written 2026-05-31 while the reveal-popup cinematic gate was fresh. Rock Band is
the worked example throughout — it's the easiest first AD target (see §4).

---

## 1. The two delivery rails

There are exactly two places AD can come out of, and they have different timing
properties:

### Rail A — Lua-side speech (screen reader / Tolk)
`Speech.emit(text, kind)` from any mod VM → the screen reader speaks it.
- **Pro:** trivial to author (it's just text, often the same `_LONG` string the
  **I** key already reads). No new asset, no render step, ships today.
- **Con:** timing is *approximate*. Speech is queued through the Speech scheduler
  ([[project_speech_scheduler]]); we control *when we call emit*, not the exact
  word-level landing. Rate depends on the user's screen-reader speed. So Lua-side
  AD is good for **one block spoken at one moment**, not for lines synced to
  specific frames.
- **Con:** it's TTS via the user's reader, not a voiced track — some users
  dislike TTS AD ([[project_cinematic_playback_behavior]]). Mitigated by the gate
  being opt-in (§3).

### Rail B — Launcher-side pre-rendered audio (.wav)
The mod emits a marker to Lua.log when a cinematic starts; the launcher catches
the marker and plays a pre-rendered AD `.wav` whose **timing is baked into the
file** (silence-padded so each line lands at its authored offset). This is
"Path B" in the AD production plan.
- **Pro:** exact timing — a real voiced track, lines land frame-accurately
  because the silence padding *is* the timing. This is the only way to do
  **synced/timed AD** reliably.
- **Pro:** can be a human-voiced track, not TTS.
- **Con:** needs the production pipeline run (render + ship the .wav) and the
  launcher playback helper (~30 LOC, not yet built) + the marker hook.

**Rule of thumb:** Rail A for "speak a description at a moment" (read-after-spawn);
Rail B for "narrate along with the footage" (timed/synced).

---

## 2. The three timing models

For any cinematic, AD can land at one of three moments:

- **(A) Pre-roll (on open, before the cinematic plays).** We already do this —
  the reveal modal speaks its briefing on open, *clean*, with the native audio
  held back (the Sean-Bean gate, [[speech-audio-coordination]]). This is
  orientation, not description-of-footage: "Rock band concert. <band>. Level N."
- **(B) Synced / timed (during the cinematic).** AD lines land at timestamps
  while the footage plays. Needs **Rail B** (baked-timing .wav) to be reliable —
  Lua-side timers in our VM are coarse (frame-counting `ContextPtr:SetUpdate`, no
  clean ms timer). Use for long, multi-beat cinematics.
- **(C) Read-after-spawn (post-roll).** Speak the whole AD block once, right when
  the cinematic spawns (or right after it ends). **Rail A** is fine here — one
  `Speech.emit` at the spawn moment. Simplest possible AD; ideal for short clips
  where one paragraph covers the whole thing.

The user's framing for Rock Band — *"by timing, or with a read after the
cinematic spawns"* — is exactly (B) vs (C). For Rock Band, **(C) on Rail A is
the MVP**; (B) on Rail B is the upgrade.

### DESIGN RULE: short clips get a clean description block, NOT synced AD
(Noel, 2026-05-31.) For a short cinematic (~10s, e.g. rock band), do **not** try
to fit timed AD into the runtime. Squeezing description lines into a 10-second
window forces a bad trade: either rush the words past comprehension, or talk over
the music for the clip's whole length. Both lose. **Better to have *some* AD,
delivered as one clean decoupled block, than synced AD crammed into the clip.**
- So for short clips: prefer model **(A) pre-roll** or **(C) read-after-spawn** —
  speak the description once, clean, *outside* the footage window, where it has
  room to breathe and isn't fighting the soundtrack.
- This is the Sean-Bean idiom already in the gate: briefing speaks clean first
  (no native audio over it), THEN Enter plays the cinematic. The description and
  the footage are deliberately *sequential*, not overlapping.
- Reserve synced AD (model B) for **long** multi-beat cinematics (victory/boot
  intros) where there's genuinely time to land lines against distinct visual
  beats and silence between dialogue. Don't reach for it on short clips at all.
- Corollary: this means short-clip AD needs NO precise timing infrastructure —
  it's just text spoken at one moment. Rail A (`Speech.emit`) fully covers it;
  Rail B (baked-timing .wav) is overkill for short clips and only earns its
  complexity on the long ones.

---

## 3. The reveal-popup hook: `playCinematic` IS the AD rail

The reveal popup framework already has the injection point built. In
`RevealPopupAccess.lua`, `opts.playCinematic` is a **payload-agnostic** function
fired by the first **Enter** (the Sean-Bean gate). It currently carries:
- found-wonder: the voiced quote (`UI.PlaySound`)
- rock band: the camera + unit cinematic replay (`rbPlayCinematic` in
  `RevealListeners.lua`)

Because it's just "a function fired on Enter", **AD drops straight into it** with
no framework change. Two concrete shapes:

- **Read-after-spawn (C / Rail A):** inside the `playCinematic` body, after
  kicking off the cinematic, `Speech.emit(adText, "selection")`. The cinematic
  and the spoken description start together; the description plays over the
  footage. (For rock band that's `rbPlayCinematic` → start camera/anim → emit AD.)
- **Synced (B / Rail B):** inside `playCinematic`, emit the launcher marker
  (`#SCREENREADER_CINEMATIC ROCK_BAND` style) instead of speaking; the launcher
  plays the timed .wav. The Lua side just signals "it started now".

**Opt-in for free:** AD only fires when the user presses Enter to play the
cinematic. A user who doesn't want TTS AD just presses Escape (skip) or never
plays it. This sidesteps the "don't force TTS AD" concern
([[project_cinematic_playback_behavior]]) with zero extra UI — the gate that
already exists *is* the opt-in.

### Where each reveal type lands
- **Rock Band** — cinematic IS the concert footage. AD describes the concert.
  Identical every time → one authored description (§4). Rail A/(C) MVP.
- **Found-wonder (NaturalWonder / WonderBuilt)** — `playCinematic` is the voiced
  quote; the *visual* AD of the wonder already exists as the **I**-key `_LONG`
  describer string. So "AD" here = the quote (already voiced by the game) + the
  on-demand image description (already shipped). Likely no extra AD work needed.
- **Hero / Secret Society** — no cinematic (hero modal has no `playCinematic`);
  the **I**-key image description is their "AD". Nothing to insert at a cinematic
  hook because there's no cinematic.
- **Disaster / Era** — Disaster has a cinematic scene; an authored
  read-after-spawn description could ride its `playCinematic` if/when we gate it
  (currently disaster is not cinematic-gated — see reveal handoff).

---

## 4. Why Rock Band is the easiest first AD target

- **The cinematic is identical every concert** — same camera path
  (`ROCK_BAND_CONCERT_CAMERA`), same unit animation (`ACTION_1`). So **one
  hand-authored description covers all instances** — no per-instance AI-AD, no
  per-band variation. Write it once.
- **It's short** — a single paragraph (read-after-spawn, model C) covers it; no
  need for timed/synced multi-line AD. Per the short-clip design rule (§2), we
  deliberately do NOT sync — one clean block beats cramming lines into ~10s.
  Placement choice for rock band: pre-roll (describe before Enter plays it) or
  post-roll (after the concert) — both keep the description out of the music's
  way. Pre-roll fits the existing gate idiom most naturally.
- **The delivery hook already exists and is validated** — `rbPlayCinematic` in
  the rock-band gate. Adding AD = one `Speech.emit` (Rail A) or one marker emit
  (Rail B) inside that function.
- **Only blocker is the gate itself**, not the AD: the rock-band gate
  (`ROCKBAND_DELAY_CINEMATIC`) still needs live validation on a real concert (the
  event-hold-release question). Once the gate is proven, the AD line is trivial
  to add. Don't author the AD until the gate is confirmed working live.

### Concrete next step (when the gate is validated)
1. Hand-write the rock-band concert description (one short paragraph).
2. Store as a LOC string `LOC_CIVVIACCESS_RB_CONCERT_AD` (so it's localizable
   later, like the other describer strings).
3. In `rbPlayCinematic`, after starting the cinematic:
   `Speech.emit(Locale.Lookup("LOC_CIVVIACCESS_RB_CONCERT_AD"), "selection")`.
4. (Upgrade path) If timed AD is wanted later, render the paragraph to a
   silence-padded .wav, swap the emit for a launcher marker, build the ~30 LOC
   launcher playback helper.

---

## 5. Open items
- Rail B (launcher playback + marker hook) is **not yet built** — it's the
  Path-B work in the AD production plan. Rail A works today.
- Lua-side timed AD (model B without the launcher) is **not reliable** — no clean
  ms timer in the popup VM. If we ever want it Lua-only, frame-counting via
  `ContextPtr:SetUpdate` at ~60fps is the crude option; prefer Rail B.
- Confirm the rock-band gate live before authoring any rock-band AD (§4).

## Related
- AD production plan (memory `audio-description-production-plan`) — generation
  pipeline, costs, batch order. THIS doc is its missing "runtime delivery" half.
- `project_speech_audio_coordination` — duck/speak/never-talk-over rules, the
  briefing-then-sound idiom the pre-roll model follows.
- `dlc_reveal_popups_2026_05_29` — "the deferred-cinematic gate is the AD delivery
  rail" framing; the Sean-Bean gate that makes AD opt-in.
- `project_audio_description_vision` — the three-tier north star.
- `reference_civ_vi_cinematic_audio_pipeline` — extracting/mixing source for
  Rail B assets.
