# tools/ — Python reference implementation

Python 3.13 mirror of BarPathKit's detector and analyzer (`docs/RECORDER_SPEC.md` §4–§5),
a physically based simulator, the Swift test fixture generator and a plotting CLI.

```
tools/
  barpath/
    recording.py   LiftRecording JSON (§2) load/save, debug session CSV (§2.1) load/save
    detector.py    OnlineLiftDetector (§4), sample by sample, same defaults/events as Swift
    analyzer.py    LiftAnalyzer (§5) -> LiftAnalysis / LiftMetrics / LiftSegment dataclasses
    simulate.py    synthetic snatch, clean & jerk and full-session recordings with ground truth
    geometry.py    quaternion/vector helpers (Quat.rotate = q v q^-1)
  tests/           pytest
  make_fixtures.py writes BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/*
  plot_lift.py     plot a recording or replay the detector over a session CSV
  out/             plots (gitignored)
```

Requirements: numpy, scipy, matplotlib, and pytest (`pip install pytest`).

## Run the tests

```sh
python -m pytest tools/tests -q
```

## Regenerate the Swift fixtures

```sh
python tools/make_fixtures.py
```

This writes `sim_snatch.json`, `sim_clean_and_jerk.json` and `sim_snatch_conjugate.json`
(the conjugate one stores q* so the analyzer has to auto-detect the convention). Each has a
`<name>.expected.json` holding **simulator ground truth** and the §6 tolerances. It also
writes `sim_session.csv` and `sim_session.expected.json` for the detector. The output is
deterministic because the seeds are fixed in `make_fixtures.py`.

## Plot a recording exported from the phone

Use the iPhone app's share sheet (AirDrop or Files) to export a lift `<id>.json` or a debug
`session-<id>.csv`, then:

```sh
python tools/plot_lift.py ~/Downloads/<id>.json --out tools/out/lift.png
python tools/plot_lift.py ~/Downloads/session-<id>.csv --out tools/out/session.png
```

- **Lift plot:** side-view bar path (forward vs vertical in cm, colored by speed, with
  markers at homing, max height, catch and end), vertical velocity with the ZUPT segment
  bounds, and the raw signals (|userAccel|, vertical userAccel, 800 Hz |raw| − 1, rotation
  rate, forearm tilt). Shaded bands mark the anchor runs.
- **Session plot:** replays the Python detector. It shows the vertical userAccel, |ĝx| and
  rotation rate, with each detected lift (homing to end) shaded and armed/disarmed/started
  markers. Any `# mark …` and `# event …` comment lines the watch wrote are drawn too.

Without `--out`, the PNG is written next to the input.

## Using it from Python

```python
import sys; sys.path.insert(0, "tools")
from barpath import load_recording, analyze, load_session_csv, detected_lifts
a = analyze(load_recording("lift.json"))
print(a.metrics, a.confidence, a.notes)
print(detected_lifts(load_session_csv("session.csv").motion))
```

## Simulator

Each channel is a C2 quintic-Hermite spline: body position and yaw, the wrist offset in the
lifter's body frame, and the forearm angles (turnover about the lateral axis, splay,
pronation twist). Walking adds arm swing and vertical bob under a smooth envelope.
Acceleration comes from a 5-point stencil on the position function, and body rate from
Rᵀ·Ṙ. Sensor model: 0.01 g white noise on accel, a constant accel bias with |b| between
0.003 and 0.005 g, 0.01 rad/s gyro noise plus a 0.002 rad/s bias, a slowly varying fusion
attitude error of 0.1° rms per axis, and 0.5°/min of yaw drift. Gravity and userAccel come
from the *estimated* attitude, so tilt error leaks into userAccel the way it does in real
fusion. The heading is 37°. The device frame has +x down the forearm and +z out of the face,
so gravity reads ≈ (+1, 0, 0) with the arm hanging.

### Sign convention (physical CoreMotion)

CoreMotion reports `raw = gravity + userAcceleration` in g. The gravity vector points down,
and a physical accelerometer reads `|raw| = 1 + a_up/G`. Therefore `userAccel = −a/G`: it is
the *negative* of the device's acceleration. The detector, analyzer and simulator all use
this convention:

- detector: `aUp = +(userAccel · ĝ) · G`
- analyzer: `aW = −rot(userAccel) · G` (world z up); gravity-only vertical = `+(aDev · ĝ)`
- simulator: `raw = gravity − a/G`, `userAccel = raw − gravity`
  (`simulate.sense(user_accel_sign=+1)` produces the old inverted convention, for
  robustness tests only)

To check a real recording, look at the "Acceleration" panel of `plot_lift.py`. During the
pull, "vertical userAccel (up)" and "|raw 800 Hz| − 1" must have the same sign and nearly
overlap.

## Differences from the original spec text (mirror these in Swift)

See the module docstrings of `detector.py` and `analyzer.py` for every resolved ambiguity.
There are two agreed changes. The first is the sign convention above. The second, in the
analyzer only, is described below:

**Motion onset ("release") index.** The causal EMA keeps flagging samples as still for a
while after motion has started, roughly `emaTau·ln(|a|/stillAcc)`, which is 50–130 ms on a
pull. Starting the ZUPT integration at the last sample of the forward still run therefore
drops real velocity. That loses about 2–7 cm of height per segment, always downward. The fix
runs the same EMA a second time *backward in time* (samples n−1…0,
`dt_i = clamp(t_{i+1} − t_i, 0, 0.05)`, EMAs starting at 0, same thresholds). For each still
run `[r0, r1]`, the release index is the last `i` in `[r0, r1]` that the backward pass also
calls still (`r0` if none). The release index replaces "last sample of the run" everywhere
§5 uses it:
- the homing index, and the starting point of the homing velocity test
- the start of the motion segment after each anchor
- the start of the drop-test tail, and the path end when a drop is found

Velocity is forced to 0 on `[r0, release]`. Run detection and run durations still use the
forward mask only. Call `analyze(rec, spec_literal=True)` to get the spec-literal behaviour
for comparison.
