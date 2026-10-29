"""Fill tracker-only frames (ok=0) from the yellow post-it on the sleeve end.

The post-it sits on the bar end, nearer the camera than the plate centre, so it appears at an
offset from the plate centre. The offset is measured on frames where both the plate circle and
the post-it are found (median of the nearest 60 such frames in time) and subtracted.
Frames filled this way get ok=2. Rewrites videos/tracks/<name>.npz in place (keeps a .bak).

Usage: .venv/bin/python tools/video_tracking/postit_refine.py videos/tracks/lifts/<video>_lift<k>.npz ...
"""
import os, shutil, sys
import cv2
import numpy as np

LO, HI = (26, 25, 150), (42, 95, 255)
WIN = 70  # search half-window around the predicted post-it position (full-res px)
MIN_AREA = 60


def blob(hsv, cx, cy):
    h, w = hsv.shape[:2]
    x0, y0 = int(max(cx - WIN, 0)), int(max(cy - WIN, 0))
    x1, y1 = int(min(cx + WIN, w)), int(min(cy + WIN, h))
    if x1 <= x0 or y1 <= y0:
        return None
    m = cv2.inRange(hsv[y0:y1, x0:x1], LO, HI)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    n, lab, st, cen = cv2.connectedComponentsWithStats(m)
    best = None
    for i in range(1, n):
        if st[i, 4] < MIN_AREA:
            continue
        c = cen[i] + [x0, y0]
        dd = np.hypot(c[0] - cx, c[1] - cy)
        if best is None or dd < best[0]:
            best = (dd, c)
    return None if best is None else best[1]


def main(npz):
    name = os.path.splitext(os.path.basename(npz))[0]
    vid = name.rsplit("_lift", 1)[0]
    video = os.path.join(os.path.dirname(npz), "..", "..", vid + ".mov")
    src = npz + ".bak" if os.path.exists(npz + ".bak") else npz
    d = dict(np.load(src))
    u, v, ok = d["u"], d["v"], d["ok"].copy()
    n = len(u)
    P = np.full((n, 2), np.nan)
    cap = cv2.VideoCapture(video)
    cap.set(cv2.CAP_PROP_POS_FRAMES, int(round(d["t"][0] * float(d["fps"]))))
    # pass 1: post-it on confirmed frames, searched over the whole lower hub region
    off_guess = None
    for i in range(n):
        okf, f = cap.read()
        if not okf:
            break
        if not np.isfinite(u[i]):
            continue
        hsv = cv2.cvtColor(f, cv2.COLOR_BGR2HSV)
        if off_guess is None:
            # first sighting: look below/around the hub with a wide window
            c = None
            for dy in (40, 80, 120):
                c = blob(hsv, u[i], v[i] + dy)
                if c is not None:
                    break
        else:
            c = blob(hsv, u[i] + off_guess[0], v[i] + off_guess[1])
        if c is not None:
            P[i] = c
            if ok[i] == 1:
                o = P[i] - [u[i], v[i]]
                off_guess = o if off_guess is None else 0.9 * off_guess + 0.1 * o
    both = np.where((ok == 1) & np.isfinite(P[:, 0]))[0]
    if len(both) < 30:
        print(name, "post-it not found reliably; unchanged", len(both))
        return
    offs = P[both] - np.stack([u[both], v[both]], 1)
    filled = 0
    n_tracker = int((ok == 0).sum())
    for i in np.where((ok == 0) & np.isfinite(P[:, 0]))[0]:
        near = both[np.argsort(np.abs(both - i))[:60]]
        o = np.median(P[near] - np.stack([u[near], v[near]], 1), axis=0)
        cu, cv_ = P[i] - o
        # reject if it disagrees wildly with the tracker (wrong blob)
        if np.hypot(cu - u[i], cv_ - v[i]) > 120:
            continue
        u[i], v[i], ok[i] = cu, cv_, 2
        filled += 1
    if not os.path.exists(npz + ".bak"):
        shutil.copy(npz, npz + ".bak")
    d.update(u=u, v=v, ok=ok)
    np.savez(npz, **d)
    print(f"{name}: post-it seen on {len(both)} circle frames, offset median "
          f"{np.median(offs, 0).round(1)} px (spread {offs.std(0).round(1)}), "
          f"filled {filled} of {n_tracker} tracker-only frames")


if __name__ == "__main__":
    for v in sys.argv[1:]:
        main(v)
