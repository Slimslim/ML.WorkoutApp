# Owner input (2026-11-01, 22:30): one day of Mayhem programming (as shown in the programming app the owner uses)
Screenshots: (owner screenshots, not in repo)
Owner: "Also think about it for workouts like this: this is a typical Mayhem programming for one day. Lifting, Metcon, some gym, core or extra work."

One day = a list of BLOCKS, each a card with: title, prescription text, movement icons/links, "Athlete instructions" (intent, %1RM, scaling), and buttons LOG (big), START, N RESULTS, DETAILS. App tab bar: Home · Community · (+) · Activity · Messages.
Blocks seen (order in the day roughly):
1. Metcon-specific warm-up (not scored): "1. Movement prep/activation: Row 1:30 easy, :30 moderate…"
2. Back Squat 3-3-3-3-3 — "Use the heaviest weight you can for each set. Rest as needed." Instructions: 3–5 sets, 65–75% 1RM. Card shows PREVIOUS RESULT "3675 lbs | 245, 245, 245, 245, 245 lbs | Rx'd (2024-12-06)" and RECENT MAXES "3RM 215 lbs (2/11/26), 10RM 135 lbs". (Note: 3675 lb = sum of load × reps = 5 sets × 3 reps × 245 lb, i.e. total volume, not a sum of loads.)
3. Front Squat 3-3-3-3-3 — same pattern; 68–70% 1RM; previous result (total volume = sum of load × reps, + each set + Rx'd); recent maxes 5RM 235, 10RM 185.
4. Metcon "IT'S JUST A FLESH WOUND!" — For time: 40/32 row cal, 7 power cleans 185/125 lb, 30/24 row cal, 7 PC, 20/16, 7 PC, 30/24, 7 PC, 40/32, 7 PC. Time cap 17 min. (M/F numbers "40/32", loads "185/125".) Target score in instructions.
5. Core work — "2 rounds for quality of: 25 GHD sit-ups, hollow hold 30 s, 20 toes-to-bar. Rest as needed between rounds." (not for time; quality)
6. Mayhem Gymnastics – Core/Plank holds — For time: 100 V-ups, time cap 7 min; instructions describe the cycle intent.
7. Cool down — "3–5 min easy cardio; 2 sets 1:00 couch stretch" (not scored).
8. "RPE guide and scaling/substitution document" (reference block).

Implications to design for: a training DAY/SESSION made of typed blocks (warm-up, strength sets with %1RM and rep scheme, metcon with cap and M/F standards, accessory/quality rounds, gymnastics test, cool-down, reference doc); each block has its own score type (load per set / total, time or reps at cap, none) and its own LOG + START; lift blocks show previous result and recent maxes (3RM/5RM/10RM) next to the prescription; programs come from a subscription (Mayhem) → import whole day (photo/paste/screenshot of several cards) into one session; the watch should run the day block by block.
