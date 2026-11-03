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
