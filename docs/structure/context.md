# Context for the Rx Lab structure review

## The athlete / owner
Non-developer hybrid athlete (CrossFit box "Blue Republic", class WODs incl. Hero/benchmarks, strength + Olympic lifting, HYROX Anaheim Dec 3-6 2026, partner/doubles WODs on Saturdays). Apple Watch Series 12 + iPhone. Will share with 2-3 friends via TestFlight (one in Switzerland), App Store later.
Vision (repo docs/VISION.md): one app that MEASURES every workout (HYROX, CrossFit benchmarks/Hero/class WODs, strength & Olympic lifting) and turns data into insights/recommendations ("a second opinion on every workout"). Working name "Rx Lab". BarPath = the lifting analysis feature.
Likes Beyond the Whiteboard (btwb): Fitness Level (0-100, avg of 8 categories: power lifts, Olympic lifts, speed, endurance, metcon bodyweight/light/heavy/long), workout level 1-99 with a pre-workout slider, imbalances, benchmarks/PRs/badges, calendar. Our edge: the watch measures (splits by Crown turn, HR + recovery, run pace via pedometer, bar path/velocity, later reps/work-rest) instead of manual entry.
HYROX friend feedback: racers watch the clock vs target times and want ahead/behind.

## What exists today (audit)
iPhone tabs: Live (shows newest result: a workout overview OR the last lift session), Workouts (results list + thin "Next workout on watch: X · Choose" bar → chooser → preview → Send to watch), History (lifts only), Debug (raw files, connection). No settings (max HR missing, units lb only). No builder, no import.
Workout report: hero score + delta vs previous attempt, HR chart with segments + recovery tail, recovery card, story per format (race, round grid, every N:00 slots, AMRAP clock), splits table, Fix splits (move boundaries, partial reps after cap, apply newer definition, restore original). Share JSON/CSV.
Lift: phone analyzes each lift file: bar path chart, velocity chart, peak velocity, pull/catch heights, confidence; compare with previous lift only; session view.
Watch: two unlabelled swipe pages: Lifting (lift type, load, START, auto lift detection, Data mode) and Workouts (3x3 picker of 9 built-ins, START, Screen demo). Workout screen "D+": big coloured segment name, timer, metric + HR, progress border, Crown turn = next / back = undo, timed rests with 3-2-1, AMRAP cap + partial reps picker, done screen with 3-min recovery clock. Phone sends a workout to watch via WatchConnectivity; results come back as files only when phone app is reachable/open.
Planned: target splits ahead/behind, run calibration, auto run detection, rep counting, paste/photo import, Fitness/Health integration, TestFlight.

## Proposal v1
File: proposal-v1.html (same folder). Tabs Today · Library · + · Log · Insights; Settings behind avatar; bar path inside as per-lift analysis; page tree; add flow (paste/photo → confirm screen); wireframes; build order; open questions.
