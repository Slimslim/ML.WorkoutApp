# Watch UX review (independent reviewer) — APPLY, with the athlete's overrides at the bottom

## Top 5 issues
1. Redundancy. Run: next station twice; km index three times ("RUN 3/8", "KM 3/8" label, 8 dots). Roxzone: "ROX 1/15" + "ROXZONE" heading; next station twice. Fix: say each thing once (see overrides for run).
2. One hero per state (>=40 px): run = pace; erg = est. split; sled = length "3 OF 4"; BBJ/lunges = count; farmers = metres; WB = reps (on break: break clock swaps into hero, reps dimmed to row 3); Rox = rox clock; Rest = rest clock. Segment elapsed drops to a 24-26 px row 1 (yellow).
3. Legibility floor: labels >= 11 px (demo px = pt at 45 mm), secondary values >= 22 px, max 2 columns and 4 rows. Kill the WB 2x2 grid.
4. Top-right = total race time on EVERY screen incl. Rest, never replaced. Undo hint goes to the bottom line for 5 s ("Wrong station? Turn Crown"). Station names <= 9-10 chars in the top bar: SKIERG, SLED PUSH, SLED PULL, BURPEES, ROW, FARMERS, LUNGES, WALL BALLS.
5. Colour semantics: yellow = segment elapsed only; red = HR only; blue = run; orange = station; pink = Rox; volt = progress toward target (metres/reps/length, bars, rings); teal = rates/cadence (spm, /min, s/rep); white = plain counts. Trend as signed delta "+4 s vs avg" (orange when slower) / "−3 s vs avg" (volt when faster), inline next to the split. Rename tokens --fast -> --rate, --slow -> --accent (or similar) and stop using volt for "sets so far", purple for "proj. finish".

## Layout spec (all dark screens; Rox/Rest are full-colour variants)
Top bar (11 px): dot + segment + index left; total race time right (always).
Row 1 (26 px, yellow): segment elapsed.
Hero (40-44 px; WB 58 px + edge ring): the number above, in segment colour or volt if progress-to-target.
Row 3: two columns 24 px: left = secondary work metric, right = HR in red (ALWAYS row 3 right).
Row 4: progress (bar / dots).
Bottom line (12 px): context, blank by default.
Per state:
- Run: hero pace "4:31 /KM" (label "PACE"); row 3 left "223 M" label "INTO KM" (volt), right HR; row 4: 8 km dots FULL WIDTH (see override); bottom: see override. Run start first 40 s: bottom "Settle your pace." ok.
- Exit soon: bottom becomes blue banner + haptic.
- Roxzone: top bar "ROXZONE 1/15" + total time; delete the big "ROXZONE" heading; hero rox clock (ink on pink, 54 px); HR row; ONE next line "SkiErg next" / "Run 2 next" (no duplicate cue). Always-on: pulse off, pink as a 6 px inner border on black.
- Ergs: hero est. split "1:47" label "EST /500 M" (teal); inline "+4 s vs avg" (hide until data); row 3 left "45 SPM" (teal), right HR; strokes as small white count; no metres.
- Sleds: hero "3 OF 4" label "LENGTH" (volt); 4-segment bar; row 3 left steps/pulls (white), right HR; no metres number.
- BBJ: hero "24" label "JUMPS" (volt); row 3 left "6.3 S/JUMP" (teal), right HR; bar /80 m est. (bar only, no metres number).
- Farmers: hero "113" label "OF 200 M" (volt); bar; row 3 left "153 SPM" (teal), right HR.
- Lunges: hero "63" label "LUNGES" (volt); row 3 left "25 /MIN" (teal), right HR; bar /100 m est. (bar only).
- Wall balls: hero "43 /100" 58 px + edge ring; row 3 left "17.2 /MIN" (teal), right HR; row 4 "ON PACE FOR 5:48" (white, one line); bottom "Set 2". Break: hero becomes "0:05" label "BREAK" (purple), reps dimmed into row 3. Doubles: "12 /55" and "ON PACE FOR · TEAM 5:13".
- Resting (Doubles): kicker "RESTING · SKIERG", total race time top-right, rest clock 62 px, HR 40 px, bottom "Zone 3". Recovered: pulsing inset border, bottom "Zone 2 · ready". No countdown.
- Armed: "87 BPM" label "RESTING HR"; countdown hero volt; bottom "Starts on your first steps."
- Finish: drop "8/8"; three breakdown rows at 24 px with 11 px labels; "See overview ›".
- Always-on/wrist-down (describe in the caption, and optionally render via a small "Wrist down" toggle if cheap): top bar + row 1 + hero only, bars/rings hidden, bottom blank except the Exit soon banner (>=16 px).

## Copy
"CURRENT PACE"→"PACE"; "/500 M · EST. SPLIT"→"EST /500 M"; "JUMPS · COUNTED"→"JUMPS"; "S/REP · AVG"→"S/JUMP"; "/ 200 M · FROM STEPS"→"OF 200 M"; "25 /MIN · LUNGES"→"25 /MIN"; "REPS · SET 2"→"SET 2"; delete "2 SETS · SO FAR"; "5:48 PROJ. · FINISH"→"ON PACE FOR 5:48"; "BREAK · 0:05"→ hero "0:05" label "BREAK"; "↶ CROWN" top-right→ bottom "Wrong station? Turn Crown"; "Zone 2 · under 150"→"Zone 2 · ready"; "87 BPM · RESTING"→ label "RESTING HR".

## Cut
Run "KM 3/8" sub-label; Roxzone heading + duplicate next line; est. metres NUMBERS on sleds/BBJ/lunges (keep bars); WB sets-so-far tile and the 2x2 grid; "FINISH 8/8"; the Crown hint in the clock slot.

## ATHLETE OVERRIDES (these win)
- Run: REMOVE the "→ <station>" text next to the km dots, so the 8 blue km dots take the FULL screen width. The bottom line shows the next station instead, always, as "Next: Burpee Broad Jumps" (full station name, may wrap to 2 lines). Near the end of the km it turns into the blue Exit soon banner: "Exit soon · Next: Burpee Broad Jumps" (keep the full name; wrap allowed). First 40 s may still show "Settle your pace." only if it fits with the Next line; otherwise prefer "Next: …".
- Roxzone: apply the reviewer's change (delete the big "ROXZONE" heading; top bar "ROXZONE 1/15").
