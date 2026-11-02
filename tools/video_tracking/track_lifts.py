"""Track each watch lift separately in its own video window.

Window (video time) = [homing - 0.7 s, liftEnded + 1.0 s], shifted from watch time by
offset = watch startDate - video creation time. The plate is re-detected on the resting bar
at the start of each window, so drops and rolling between lifts don't matter.

Usage: .venv/bin/python tools/video_tracking/track_lifts.py [--data data/raw/<date>] [name-substring ...]
Writes videos/tracks/lifts/<video>_lift<k>.npz
"""
import argparse, glob, os, sys
from multiprocessing import Pool
import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import track_plate as tp
import analyze_tracks
from analyze_tracks import sessions, video_start, VID

PRE, POST = 0.7, 1.0
SKIP = ("other_", "unmatched_", "hangSnatch_")  # deadlifts: whole-set tracks; empty bar: no plate


def init_plate(cap, fps, f0, rguess):
    rmin, rmax = (0.85 * rguess, 1.15 * rguess) if rguess else (55, 100)
    found = []
    for i in range(f0, f0 + int(0.6 * fps), 3):
        cap.set(cv2.CAP_PROP_POS_FRAMES, i)
        ok, f = cap.read()
        if not ok:
            break
        _, g = tp.prep(f)
        cs = [c for c in tp.hough(g, rmin, rmax) if c[1] > g.shape[0] * 0.55]
        if cs:
            found.append(cs[0])
    if not found:
        return None
    v = np.array(found)
    med = np.median(v, 0)
    keep = v[np.hypot(v[:, 0] - med[0], v[:, 1] - med[1]) < 15]
    return np.median(keep if len(keep) else v, 0)


def run(job):
    path, data = job
    analyze_tracks.set_data(data)  # workers are fresh processes on macOS (spawn)
    name = os.path.splitext(os.path.basename(path))[0]
    ses = sessions()
    s = ses[name.split("_")[2]]
    offset = (s["start"] - video_start(path)).total_seconds()
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    old = os.path.join(VID, "tracks", name + ".npz")
    rguess = None
    if os.path.exists(old):
        r = np.load(old)["r"]
        rguess = float(np.nanmedian(r)) if np.isfinite(r).any() else None
    out = os.path.join(VID, "tracks", "lifts")
    os.makedirs(out, exist_ok=True)
    msgs = []
    for k, (h, e) in enumerate(s["lifts"], 1):
        f0 = int((h + offset - PRE) * fps)
        stop = e + offset + POST
        if s["type"] == "cleanAndJerk":
            # the watch times out ~8 s after homing, before the hand adjustment and the jerk:
            # extend to 2 s before the next homing (or the end of the video)
            nxt = s["lifts"][k][0] + offset - 2 if k < len(s["lifts"]) else n / fps
            stop = max(stop, nxt)
        f1 = min(int(stop * fps), n)
        if f0 >= n - fps:
            msgs.append(f"{name} lift{k}: outside video (homing at {h + offset:.1f} s)")
            continue
        init = init_plate(cap, fps, max(f0, 0), rguess)
        if init is None:
            msgs.append(f"{name} lift{k}: no plate at window start")
            continue
        x, y, r0 = init
        T, U, V, R, OK = tp.track(cap, fps, n, max(f0, 0), f1, x, y, r0, label=f"{name} lift{k}")
        sl = slice(max(f0, 0), f1)
        np.savez(os.path.join(out, f"{name}_lift{k}.npz"), t=T[sl], u=U[sl], v=V[sl], r=R[sl],
                 ok=OK[sl], fps=fps, offset=offset, watch_lift=k, homing=h, end=e,
                 session=s["sid"], r_plate_px=float(np.nanmedian(R[sl])) / tp.HALF)
        msgs.append(f"{name} lift{k}: frames={f1 - f0} ok={OK[sl].mean():.2f} r={np.nanmedian(R[sl]) / tp.HALF:.1f}px")
    return "\n".join(msgs)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=analyze_tracks.GYM, help="folder with the session-*.csv files")
    ap.add_argument("names", nargs="*", help="only videos whose name contains one of these")
    a = ap.parse_args()
    vids = [v for v in sorted(glob.glob(os.path.join(VID, "*.mov")))
            if not any(k in v for k in SKIP) and (not a.names or any(n in v for n in a.names))]
    with Pool(4) as p:
        for m in p.imap_unordered(run, [(v, a.data) for v in vids]):
            print(m, flush=True)
