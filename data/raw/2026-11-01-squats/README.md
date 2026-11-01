# 2026-11-01 · First squat recordings (owner's own data)

Watch Lifting mode, lift type "Other", DATA on (200 Hz device motion), one session per set.
Mark taps at unrack / rerack (labels). Owner's labels:

| File | Start (UTC) | Lift | Load | Reps | Marks (s) |
|---|---|---|---|---|---|
| session-A3745A71-….csv | 18:18:59 | Back squat | 45 lb (empty bar) | 5 | 6.5, 33.6 |
| session-60A37E96-….csv | 18:20:20 | Back squat | 95 lb | 6 | 1.7, 31.1 |
| session-D4C61F27-….csv | 18:21:27 | Front squat | 95 lb | 5 | 0.9, 3.9 (double tap), 28.0 |

The Olympic-lift detector fired once (session A374, "liftStarted"/"liftEnded" around 22 s): ignore.

First look (tools/scratch/squat_first_look.py: vertical acceleration along gravity, FFT band-pass
0.1–4 Hz, integrated to velocity and position; bottoms = local minima > 15 cm, ≥ 1.2 s apart):
rep counts match the labels exactly (5 / 6 / 5) once the last "rep" of each set (peak up speed
< 0.3 m/s, the walk back to the rack) is dropped. Depth ≈ 40–50 cm, peak up speed ≈ 0.8–1.25 m/s.
Speeds and depths are unvalidated estimates (no reference measurement yet).
