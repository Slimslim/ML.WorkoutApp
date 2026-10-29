"""Compare watch-derived paths with video-tracked bar paths.

    python3 tools/compare_video.py <session.csv> <video_path.csv> [--plot out.png]

<video_path.csv> has columns t,x_cm,y_cm,ok (t in s from video start, x positive away from
the lifter, y up), as written by the video-tracking session into
data/raw/<date>/video_paths/. The two clocks are unrelated, so each watch lift (cut from
the session's liftEnded events, analyzed with the Python reference) is aligned with the
video by cross-correlating vertical velocity. Reports, per lift: vertical rise (watch vs
video), horizontal error at the top of the pull and at the finish, and the same for the
"end-over-start" prior (forward(T) = 0 via a linearly growing velocity correction).
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from barpath import analyzer, recording  # noqa: E402
from barpath.recording import LiftRecording  # noqa: E402


def load_video(path):
    d = np.genfromtxt(path, delimiter=",", names=True)
    ok = d["ok"].astype(bool) if "ok" in d.dtype.names else np.ones(len(d), bool)
    t, x, y = d["t"][ok], d["x_cm"][ok] / 100.0, d["y_cm"][ok] / 100.0
    # resample to 100 Hz for correlation
    tg = np.arange(t[0], t[-1], 0.01)
    return tg, np.interp(tg, t, x), np.interp(tg, t, y)


def watch_lifts(session_path):
    S = recording.load_session_csv(session_path)
    m, t = S.motion, S.motion.t
    out = []
    for e in [e for e in S.events if e["name"] == "liftEnded"]:
        h, en = float(e["homing"]), float(e["end"])
        i0 = int(np.searchsorted(t, h - 2.0))
        i1 = int(np.searchsorted(t, en + 1.0))
        sl = m.slice(i0, i1)
        sl = type(sl)(sl.t - sl.t[0], sl.q, sl.user_accel, sl.gravity, sl.rotation_rate)
        rec = LiftRecording(session_id=S.session_id or "", index=len(out) + 1, lift_type=S.lift_type or "other",
                            start_date=S.start_date, motion=sl, homing_time=h - t[i0], end_time=en - t[i0],
                            end_reason=e.get("reason"))
        try:
            a = analyzer.analyze(rec)
        except Exception as ex:  # noqa: BLE001
            print(f"  lift {len(out) + 1}: analyzer failed ({ex})")
            continue
        out.append((t[i0] + a.path.t[0] + sl.t[a.homingIndex], a))
    return S, out


def end_over_start(tt, x):
    T = tt[-1]
    k = 2 * x[-1] / T ** 2 if T > 0 else 0.0
    return x - k * tt ** 2 / 2


def align(tw, vz_w, tv, vz_v):
    """Best offset (s) so that video time = watch time + offset, by vertical-velocity xcorr."""
    tg = np.arange(tw[0], tw[-1], 0.01)
    w = np.interp(tg, tw, vz_w)
    best, best_off = -np.inf, None
    for off in np.arange(tv[0] - tg[0], tv[-1] - tg[-1], 0.01):
        v = np.interp(tg + off, tv, vz_v)
        c = float(np.dot(w - w.mean(), v - v.mean()) / (np.linalg.norm(w - w.mean()) * np.linalg.norm(v - v.mean()) + 1e-9))
        if c > best:
            best, best_off = c, off
    return best_off, best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session")
    ap.add_argument("video")
    ap.add_argument("--plot")
    args = ap.parse_args()

    tv, xv, yv = load_video(args.video)
    vz_v = np.gradient(yv, tv)
    S, lifts = watch_lifts(args.session)
    print(f"{os.path.basename(args.session)}: {S.lift_type}, {len(lifts)} lifts; video {tv[-1] - tv[0]:.1f} s")
    rows = []
    for k, (t_home, a) in enumerate(lifts, 1):
        p = a.path
        tw = p.t + t_home
        off, corr = align(tw, p.vVertical, tv, vz_v)
        if off is None:
            print(f"  lift {k}: no overlap with the video")
            continue
        # video path re-based at the watch homing time
        x0 = np.interp(tw[0] + off, tv, xv)
        y0 = np.interp(tw[0] + off, tv, yv)
        xvi = np.interp(tw + off, tv, xv) - x0
        yvi = np.interp(tw + off, tv, yv) - y0
        xc = end_over_start(p.t, p.forward)
        itop = int(np.argmax(p.vertical))
        r = dict(lift=k, corr=corr, rise_w=p.vertical[-1], rise_v=yvi[-1],
                 top_w=p.forward[itop], top_c=xc[itop], top_v=xvi[itop],
                 end_w=p.forward[-1], end_v=xvi[-1],
                 rms_raw=float(np.sqrt(np.mean((p.forward - xvi) ** 2))),
                 rms_eos=float(np.sqrt(np.mean((xc - xvi) ** 2))),
                 rms_vert=float(np.sqrt(np.mean((p.vertical - yvi) ** 2))))
        rows.append((r, tw, off, p, xc, xvi, yvi))
        print(f"  lift {k}: xcorr {corr:.2f} | rise watch {r['rise_w']*100:5.0f} video {r['rise_v']*100:5.0f} cm | "
              f"horiz at highest point: watch {r['top_w']*100:+5.0f} eos {r['top_c']*100:+5.0f} video {r['top_v']*100:+5.0f} | "
              f"finish: watch {r['end_w']*100:+5.0f} video {r['end_v']*100:+5.0f} | RMS horiz raw {r['rms_raw']*100:.0f} "
              f"eos {r['rms_eos']*100:.0f}, vert {r['rms_vert']*100:.0f} cm")
    if args.plot and rows:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(1, len(rows), figsize=(4 * len(rows), 5), squeeze=False)
        for ax, (r, tw, off, p, xc, xvi, yvi) in zip(axes[0], rows):
            ax.plot(xvi * 100, yvi * 100, "k-", lw=2, label="video (bar)")
            ax.plot(p.forward * 100, p.vertical * 100, "r--", lw=1, label="watch raw")
            ax.plot(xc * 100, p.vertical * 100, "b-", lw=1, label="watch end-over-start")
            ax.set_aspect("equal")
            ax.set_title(f"lift {r['lift']}")
            ax.set_xlabel("forward cm")
            ax.set_ylabel("up cm")
            ax.grid(alpha=0.3)
        axes[0][0].legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(args.plot, dpi=110)
        print("saved", args.plot)


if __name__ == "__main__":
    main()
