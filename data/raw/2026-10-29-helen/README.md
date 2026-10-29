# Helen, 2026-10-29 (first real workout-mode recording)

Apple Watch Series 12, left wrist, watchOS 27. BarPath workout mode, "Helen" sent from the
phone, Data mode on. 3 rounds for time: 400 m run, 21 KB swings, 12 pull-ups. Result 12:47.

Files
- `session-….csv`: full-session device motion at 100 Hz, plus `# event` lines for segment
  switches (Crown), HR (`name=hr`, ~every 5 s) and pedometer (`name=pedometer`). t = 0 at START.
- `workout-….json`: the WorkoutResult the watch sent to the phone (version 1, no HR series).

How the athlete switched: the Crown was turned **as soon as a movement ended**, so each segment
(except the first) begins with a transition (walking to the kettlebell / bar / track) before the
movement starts. Motion shows ~7–9 s of arms-down walking at the start of each KB segment.

Labels from the athlete (video-checked)
- KB swings: all three rounds unbroken (21).
- Pull-ups by set: round 1 `2-3-3-2-2`, round 2 `1-2-3-3-3`, round 3 `3-3-2-2-2` (5 sets each).
- No video in the repo (public repo).

Crown switch times (s from START): 128.6 run→KB, 181.2 KB→pull, 235.7 pull→run, 384.7, 437.3,
499.6, 655.7, 712.5, finish 767.3.

First analysis (2026-10-29): a run rule on |userAccel| (dominant frequency 130–200/min, SD > 0.25 g,
4 s windows, 6 s debounce) finds every run end within 1 s of the Crown and every run start 2–8 s
after it (the transition). No false switches. Pull-up sets show as "wrist up" (gravity x > 0.5)
bouts on the bar: 5, 5, 5–6 bouts per round.
