#!/usr/bin/env python3
"""Per-segment report of the B2 detector on a session CSV (data/raw/<date>-<name>/session-*.csv).

  python tools/segments_report.py data/raw/2026-10-29-helen/session-*.csv [--plot out.png]

Prints, for every Crown segment: start, detected work onset (transition = onset - Crown),
detected running intervals and bar hangs. Athlete labels are printed for the Helen recording.
A plot is written only if --plot is given."""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from barpath import recording, segments  # noqa: E402

# Athlete labels (data/raw/2026-10-29-helen/README.md): pull-up reps per set, per round.
HELEN_PULL_LABELS = {"pull": [[2, 3, 3, 2, 2], [1, 2, 3, 3, 3], [3, 3, 2, 2, 2]]}


def analyse(path, kinds=segments.HELEN_KINDS):
    s = recording.load_session_csv(path)
    m = s.motion
    segs = segments.crown_segments(s.events, kinds)
    runs = segments.detect_running(m)
    for sg in segs:
        sg["onset"] = segments.work_onset(m, sg["start"], sg["end"], sg["kind"])
        sg["hangs"] = segments.bar_hangs(m, sg["start"], sg["end"]) if sg["kind"] == "pull" else []
        # 1 s slack: a run may end/start up to ~1 s on the wrong side of the Crown
        sg["runs"] = [(a, b) for (a, b) in runs if b > sg["start"] + 1.0 and a < sg["end"] - 1.0]
    return s, segs, runs


def plot(s, segs, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    m = s.motion
    wins = segments.run_windows(m)
    wt = [w + segments.RUN_WINDOW_S / 2 for w, _ in wins]
    feats = [segments.window_features(m, w, w + segments.RUN_WINDOW_S) for w, _ in wins]
    fig, ax = plt.subplots(3, 1, figsize=(16, 8), sharex=True)
    ax[0].plot(wt, [f["cadence"] if f else np.nan for f in feats], ".-", ms=3)
    ax[0].axhspan(segments.RUN_CADENCE_MIN, segments.RUN_CADENCE_MAX, color="g", alpha=.1)
    ax[0].set_ylabel("|a| cadence /min")
    ax[1].plot(m.t, m.gravity[:, 0], lw=.4)
    ax[1].axhline(segments.HANG_GX_MIN, color="r", lw=.5)
    ax[1].set_ylabel("gravity x")
    ax[2].plot(m.t, np.linalg.norm(m.user_accel, axis=1), lw=.3)
    ax[2].set_ylabel("|userAccel| g")
    for a in ax:
        for sg in segs:
            a.axvline(sg["start"], color="k", lw=.8)
            if sg["onset"] is not None:
                a.axvline(sg["onset"], color="orange", lw=.8, ls="--")
        for sg in segs:
            for (x, y) in sg["runs"]:
                a.axvspan(x, y, color="g", alpha=.08)
            for (x, y) in sg["hangs"]:
                a.axvspan(x, y, color="r", alpha=.2)
    for sg in segs:
        ax[0].text(sg["start"] + 1, ax[0].get_ylim()[1] * .9, sg["kind"], fontsize=8)
    ax[2].set_xlabel("s (black = Crown, orange = detected work onset)")
    fig.tight_layout()
    fig.savefig(out, dpi=110)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("csv")
    ap.add_argument("--kinds", default=",".join(segments.HELEN_KINDS),
                    help="movement kinds cycling per segment (run,kb,pull)")
    ap.add_argument("--plot", metavar="OUT.PNG", help="write a timeline plot here (needs matplotlib)")
    args = ap.parse_args(argv)
    s, segs, runs = analyse(args.csv, tuple(args.kinds.split(",")))
    helen = s.workout == "wod.helen" or "helen" in os.path.abspath(args.csv).lower()
    print(f"{os.path.basename(args.csv)}  workout={s.workout}  {len(s.motion)} samples")
    pull_round = 0
    for sg in segs:
        on = sg["onset"]
        tr = f"{on - sg['start']:5.1f} s transition" if on is not None else "no onset found"
        print(f"\n[{sg['index']}] {sg['kind']:<4} Crown {sg['start']:7.1f}  end {sg['end']:7.1f}  "
              f"onset {on if on is None else round(on, 1)}  ({tr})")
        for (a, b) in sg["runs"]:
            print(f"     run window {a:7.1f} - {b:7.1f}  (start {a - sg['start']:+.1f} s, "
                  f"end {b - sg['end']:+.1f} s vs Crown)")
        if sg["kind"] == "pull":
            lab = HELEN_PULL_LABELS["pull"][pull_round] if helen and pull_round < 3 else None
            pull_round += 1
            print(f"     {len(sg['hangs'])} hangs" + (f"   athlete sets {'-'.join(map(str, lab))} "
                  f"({len(lab)} sets)" if lab else ""))
            for (a, b) in sg["hangs"]:
                print(f"       hang {a - sg['start']:5.1f} - {b - sg['start']:5.1f} s  dur {b - a:4.1f} s")
    if args.plot:
        plot(s, segs, args.plot)
        print("\nplot written to", args.plot)


if __name__ == "__main__":
    main()
