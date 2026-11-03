# Workout header study (started 2026-11-03)

Status: the workout report v3 mockups (docs/concepts/workout-report-v3.html, lighter version,
owner: "getting much better") are PARKED. Focus now: one standard for the first block at the top
of every workout — the header.

## What the header must hold (owner)
- Date
- Name (the workout's title, e.g. "Freedom", "Every 1:00 × 8: Power C&J", "AMRAP 40")
- Movements
- Summary (format, score)

## Method
1. Owner provides screenshots of many workouts from different programs (Mayhem, class
   whiteboards, benchmarks/Hero WODs, HYROX, lifting days, partner WODs…). Not committed to the
   repo (public): only a written inventory.
2. Inventory: for each workout, how the source writes the title, format line, movement list,
   loads (M/F, %1RM), rep schemes (21-15-9, 3-3-3-3-3, 40/32), caps, rests, scaling notes.
3. Find the patterns and the hard cases (no name, long Hero names, multi-block days, "this or
   that" movements, EMOM with loads per set).
4. Propose 2–3 header variants that work for all of them, mock them with real examples, owner picks.

## Inventory, batch 1 (2026-11-03, 16 screenshots: Mayhem app + a benchmark/logbook app)

| # | Source title (as written) | Kind of title | Format line | Movements / loads | Meta | Score type |
|---|---|---|---|---|---|---|
| 1 | Double Unders, AbMat Sit-ups | none → movement list | E3MOM, ping pong, 3 rounds | 50 DU, 25 AbMat sit-ups | "not a timed workout" | none / done |
| 2 | 13.4 - CrossFit Games Open | competition code | AMRAP 7 min, ladder +3 reps/round | C&J 135/95 lb, T2B | levels (58 reps = level 50), ages | reps |
| 3 | The Chief | named benchmark | 5 cycles × AMRAP 3 min, rest 1 min, restart each cycle | 3 power cleans 135/95, 6 push-ups, 9 air squats | long dedication story | total rounds |
| 4 | Diane | named benchmark | 21-15-9, for time | deadlift 225/155, HSPU | levels, previous 8:54 Rx'd (2023) | time |
| 5 | "GAME OVER" (1/2 versions) | quoted fun name | for time 21-15-9, cap 8 min | deadlift 225/155, T2B | strategy/scaling behind "Read more" | time or reps at cap |
| 6 | "CHEAT CODE" (1/2) | quoted fun name | AMRAP 8, ladder +2 reps/round | alt DB snatch 70/50, lateral burpee double jumps | movement standard note | reps |
| 7 | Weighted Strict Pull-up : 1X3 | lift + scheme | 1×3 heaviest; 10 min, ≥5 sets to a 3RM | weighted strict pull-up | recent maxes (5RM 30 lb) | load |
| 8 | "What is the air-speed velocity of an unlade…" | very long quoted name (truncated) | for time, 22 movements × 22 reps; team of 2 split; cap 60 | 22 movements, loads 95/65, KB 53/35, box 24/20 in | target sub 40, RPE 8, scaling version "Mission 22", dedication | time |
| 9 | Push Press : 75 Reps For Time | lift + scheme | 75 reps for time, sets AMRAP(−1), 30 s mandatory rest | push press 75/55 | rest rule | time |
| 10 | Knee Health | block purpose | 3 rounds for quality | backward sled drag 100 ft (pick load), 40 calf raises, 20 tibia raises | — | none |
| 11 | Complex: Tall Jerks, Jerk Balances, Jerks, A… | complex (truncated) | 3 × [3+3+3+3], heaviest, rest as needed | 4 jerk variations | RPE 5/10 | load |
| 12 | "Your mother was a hamster and your fathe…" | very long quoted name | for time chipper 20/30 alternating, cap 14 | DB snatch 50/35, T2B, burpee-to-target | target 9–11 min, RPE 8.5, strategy per movement, scaling | time |
| 14 | Every 1 min for 15 mins: Power Snatch | interval + lift | EMOM 15, 5 power snatches, pick load | power snatch | recent maxes 1RM 135, 3RM 105 lb | load per minute / none |
| 15 | Front Squat : 3-3-3-3-3 | lift + scheme | 5 × 3, heaviest each set; 3–5 sets at 65–75 % 1RM | front squat | previous result "2655 lbs" = Σ load × reps (150→205 lb), Rx'd; recent maxes 5RM 235, 10RM 185 | heaviest set / volume |
| 13 | Core Work ("3 RFQ: Turkish Get-ups, …") | block purpose + subtitle | 3 rounds for quality | TGU (pick load), suitcase hold 1 min, front rack carry 50 ft | per-side notes | none |

Note on lift blocks (14, 15): the app's "previous result" leads with total volume (2655 lb),
which is hard to read; the heaviest set and the maxes are what the athlete looks at. Our header
should lead with the heaviest set (205 lb) and show volume second, and turn %1RM into real loads.

### Patterns
- **Titles come in five kinds:** named benchmark (Diane, The Chief) · competition code (13.4) ·
  quoted fun name, often very long and truncated · lift + scheme ("Push Press : 75 reps for time",
  "Weighted strict pull-up : 1x3") · block purpose ("Core work", "Knee health"). Some have none,
  and the app falls back to the movement list.
- **The format line carries the real meaning** and has a small grammar: for time / AMRAP N /
  N rounds for quality / EMOM–E3MOM / cycles × AMRAP + rest / rep scheme (21-15-9, 3-3-3-3-3,
  1×3, ladder +N) / complex [a+b+c] / team split.
- **Loads:** M/F pairs (135/95 lb), heights (24/20 in), distances (ft), times (1 min hold),
  "pick load", "heaviest", %1RM, RPE.
- **Meta is long and secondary:** cap, target time/score, RPE, stimulus, strategy, scaling
  version, dedication story — never in the header except cap and target.
- **Score types:** time · reps · rounds + reps · total over cycles · load (heaviest set) · none.

### First header idea (to mock)
1. Date · program/source · block tag (Metcon / Strength / Accessory / Benchmark)
2. Name — max 2 lines; quoted names keep their quotes; no name → generated
   ("DL + T2B" style short form); benchmark names get a small "Benchmark" tag
3. Format in one compact line: "For time · 21-15-9 · cap 8:00", "AMRAP 7 · ladder +3",
   "5 × AMRAP 3:00 · rest 1:00", "E3MOM × 3 · ping-pong", "1×3 · heaviest", "3 × complex · RPE 5"
4. Movement chips with *your* load (your division picked once), max 4 + "+18 more"
5. After the workout: score · Rx/Scaled · vs last time / vs target

## Decisions (owner, round 1 feedback, 2026-11-03)

Round 1 (variants A editorial, B format-led, C card/chips) is in commit f15421a. The owner's
decisions, now binding for the header ("D", mocked in `header-study.html`, round 2):

1. **Movements: one line per movement, stacked** (like B's list), not a sentence. No divider
   lines or borders between movement rows: plain stacked lines with even spacing
   (reps · movement · your load).
2. **Keep the block tag:** Metcon · Strength · Accessory.
3. **Add a workout-type tag from a fixed vocabulary:** Chipper, EMOM (incl. E2MOM/E3MOM),
   AMRAP, AMREP (as many reps as possible, e.g. 13.4 / "Cheat Code" ladders), Death by, Ladder,
   RFT (rounds for time), Complex, plus other variations: For quality, Cycles (e.g. The Chief),
   Sets × reps (lift days). "Each RFT" (owner's term) is **pending an example** from the owner:
   not in the legend or on any card until then.
4. **Name:** some workouts have one, some don't; keep the no-name fallback (movements joined
   with "+", lighter text). 2 lines max.
5. **No notes, instructions, stimulus or strategy anywhere in the header** (also no targets or
   RPE). The app logs what was done; it is not a planning tool.

Open (round 2 questions): The Chief tagged AMRAP or Cycles; whether planned lift days show the
load range from the stored max. "Each RFT": pending an example from the owner.

## Writing conventions (living list, started round 3, 2026-11-03)

How the header writes a workout, the way the athlete writes it on a whiteboard or in a log.
Owner: "we will have to create conventions on how we write things… we can keep training the
system as we see workouts." This is a living list: add a rule (or an open question) every time
a new workout doesn't fit.

### Rules (decided)
1. **Shared rep scheme on top, once.** When every movement follows the same scheme, the scheme
   is its own line above the movements and the movements carry no reps:
   `21-15-9` / `Deadlift @225 lb` / `Handstand Push-up`. Same for `3-3-3-3-3`, ladders
   (`3-3, 6-6, 9-9 …`), `22 each`.
2. **Mixed schemes:** the shared part goes on top with its unit, movements with their own fixed
   reps keep them. Freedom: `40-30-20-30-40 Cal` / `Row` / `7 Power Cleans @155 lb`.
3. **One movement per line:** quantity, unit, movement, `@load`.
   `12 Cal Row` · `15 Push-ups` · `12 DB C&J @40 lb` · `50 ft Front-Rack Carry` ·
   `1:00 Suitcase Hold @pick`. Number first; the unit (`Cal`, `m`, `ft`, `s`, `1:00`) sits
   between the number and the movement; the load goes last after `@`.
4. **Loads inline, never in a right-aligned column** (picked for round 3, applied to every card).
5. Movement names in Title Case, plural when the quantity is more than 1 (`7 Power Cleans`).
6. **Abbreviate** the common names: HSPU, T2B, C&J, DB, KB, DU (round 4).
7. **Units:** heights in inches (`Box Jumps @24 in`), run distances in m (miles only when the
   workout says so), `lb` never `lbs`.
8. **Alternating** = `ALT` (`12 ALT DB Snatches @40 lb`); two dumbbells = `Double DB`.
9. **Cap at the bottom** of the card, under the movements: `Cap 8:00`. Not in the format line.
10. **CrossFit Open** workouts get the `Open` prefix: `Open 13.4` (scheme `3-6-9-12…`).
11. **No name → the format is the name** (`Every 3:00 × 3`), no generated movement name.
12. **Lift blocks:** planned stays simple (`5×3 Front Squat @165–190 lb`); logged = one line per
    set or minute with load and average bar speed (`3 Front Squats @200 lb · 0.60 m/s`). Same for
    lift EMOMs (one line per minute).
13. **Rx/Scaled:** the header shows the athlete's own division load from the profile (no manual
    pick). "See details" shows the original card with Rx M/F weights. After logging the app asks
    "Rx or scaled?" and lets the athlete edit loads/reps; the score then says `Scaled`.

### Open questions
- **More abbreviations** (decided so far: HSPU, T2B, C&J, DB, KB, DU): GHD, OHS, RDL, MU, C2B…?
- **Carries and sleds:** `ft` or `m`?
- **Holds and timed work:** `1:00 Suitcase Hold @pick`, `:30 Plank`, `0:30` vs `30 s`?
- **Load picked by the athlete:** `@pick` before the workout, replaced by the real load after?
- **Bar speed** on logged sets: average concentric speed (as velocity-based training apps show) or the peak? Today the wrist gives a peak estimate.
- **Per side:** `1/side Turkish Get-up` or `6/6`? (alternating is decided: `ALT`)
- **Calories:** `12 Cal Row` vs `Row 12 cal` (decided: `12 Cal Row`); M/F calories (`15/12 Cal`).
- **Ranges and progressions:** `@125 → 175 lb` for building sets, `@165–190 lb` from %1RM.

## Final card spec (2026-11-03, mockups: `workout-cards.html`)

The workout card used everywhere (Choose list, preview before the watch, Log, top of the report,
program days, logged lifts). Built from the decisions and writing conventions above.

- **Anatomy, top to bottom:** date · program (left) and block tag + type tag (right); name, or
  the format as the name (2 lines max, Open prefix); format line only when needed (rounds,
  intervals, rest); shared rep scheme once; one movement per line `qty unit movement @load`, no
  dividers; `Cap mm:ss` at the bottom; after logging, one score line under a thin rule: score,
  unit, Rx / Scaled badge (dashed `?` = not answered yet), one comparison (last time or cap).
- **Type scale:** name 20/500 (compact row 16/500, 1 line) · score 26/500 tabular · lines 14/400
  (scheme 14/500) · format 13.5 · meta 12 · tags 10.5/500. **Spacing:** card padding 16, 9 between
  blocks, 5 between movement lines, radius 16, 1 px border. Neutrals + one accent (type tag,
  links); green only for "better than last time". Colours not final.
- **States:** planned · in progress (live line "On the watch · Round 3 of 5 · 11:02") · done Rx ·
  done Scaled · capped (reps at the cap).
- **Compact row** (Choose / Log): name, `block · type`, one-line movement summary; right side last
  score (Choose) or score + badge (Log).
- **Report:** the card's score line replaces the report v3 hero number; the time budget, tiles and
  "What stood out" follow.
- **Program day:** date and program move to a day header; each block keeps its card and tags.
- **Logged lifts / lift EMOMs:** one line per set or minute with load and bar speed (labelled
  `peak` until average vs peak is decided).
- **Open:** average vs peak bar speed; Freedom Rx weight (85 kg = 187 lb?) so 19:37 @155 lb is
  Scaled or not; final colours; send a program day to the watch all at once or block by block.
