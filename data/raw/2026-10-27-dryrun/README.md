# Dry run, 2026-10-27 (home, broomstick)

First real recordings from the watch (Apple Watch Series 12, watchOS 27.0.1), recorded at
home with a broomstick before any calibration. No ground truth (no video, no measured heights).
Two sessions: snatch / clean & jerk, then power snatch. Analyzer output below is from the
Python reference at the time of commit (after Revision C), for regression tracking only.

| time (UTC) | file | lift | # | watch end | confidence | max h (m) | final h (m) | peak v (m/s) | max back (m) |
|---|---|---|---|---|---|---|---|---|---|
| 04:20:21 | `E14A93B8-FAE6-42DF-957C-726F6F5B0F53.json` | snatch | 1 | drop | medium | 1.24 | 1.02 | 2.07 | -0.09 |
| 04:20:38 | `FE152D40-0B94-4F41-91A7-4E7AFFD67B83.json` | snatch | 2 | timeout | medium | 1.76 | 1.76 | 1.79 | -0.48 |
| 04:22:58 | `01235305-BC4D-4F5B-A432-F9811E04C7C2.json` | cleanAndJerk | 1 | drop | high | 1.22 | 1.21 | 1.86 | -0.03 |
| 04:23:17 | `CD497A4F-865C-4E01-AF51-F43EAFFE9669.json` | cleanAndJerk | 2 | timeout | low | 1.08 | 1.03 | 1.36 | -0.45 |
| 04:23:42 | `E58F1249-9DB5-406E-BDE8-DFFBB9C1647C.json` | powerSnatch | 3 | timeout | medium | 1.64 | 1.62 | 1.72 | -0.21 |
| 04:23:55 | `07027AF6-D5E5-42E7-A146-5267D65AF46B.json` | powerSnatch | 4 | drop | medium | 1.24 | 0.70 | 1.42 | -0.27 |
| 04:24:12 | `A21A80A8-056A-4956-810D-F019369AA32E.json` | powerSnatch | 5 | timeout | medium | 0.31 | 0.31 | 0.62 | -0.05 |
| 04:24:24 | `6D41B247-FF5E-475F-9FDC-35CFE99CED2F.json` | powerSnatch | 6 | timeout | low | 1.94 | 1.19 | 2.76 | -0.98 |

Observations: the finish was rarely held still (overhead wobble ≈ 0.1 g), which led to
Revision C in `docs/RECORDER_SPEC.md`. Horizontal (forward/back) drift remains large on
several lifts.

## Athlete measurements (reported 2026-10-27, same athlete and broomstick)

- Watch height in the set position (stick on the floor): **0.25 m**
- Watch height at the top of the snatch (standing, arms locked overhead): **1.80 m**
- So the expected watch rise from homing to snatch lockout is **≈ 1.55 m**.
