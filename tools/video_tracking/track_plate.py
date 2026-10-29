"""Track the near bumper plate centre (= bar end) in a side-view lifting video.

Usage (videos/ is git-ignored):
    .venv/bin/python tools/video_tracking/track_plate.py videos/<name>.mov
        [--init x,y,r] [--init-time s] [--res f] [--box px] [--no-hough]

Writes videos/tracks/<name>.npz with per-frame t, u, v (full-res px), r, ok.
"""
import argparse, os, sys
import cv2
import numpy as np

HALF = 0.5  # work at half resolution (540x960)


def hough(gray, rmin, rmax, param2=0.75):
    cs = cv2.HoughCircles(gray, cv2.HOUGH_GRADIENT_ALT, 1.5, 20, param1=150,
                          param2=param2, minRadius=int(rmin), maxRadius=int(rmax))
    return [] if cs is None else cs[0].tolist()


def prep(frame):
    small = cv2.resize(frame, None, fx=HALF, fy=HALF, interpolation=cv2.INTER_AREA)
    gray = cv2.medianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), 5)
    return small, gray


def find_init(cap, t0=2.0, t1=8.0):
    """Strongest large circle on the static bar before the first lift."""
    fps = cap.get(cv2.CAP_PROP_FPS)
    votes = []
    for t in np.arange(t0, t1, 0.5):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
        ok, f = cap.read()
        if not ok:
            break
        _, g = prep(f)
        cs = [c for c in hough(g, 55, 100) if c[1] > g.shape[0] * 0.5]
        if cs:
            votes.append(cs[0])
    if not votes:
        raise SystemExit("no plate found for init")
    v = np.array(votes)
    med = np.median(v, axis=0)
    keep = v[np.hypot(v[:, 0] - med[0], v[:, 1] - med[1]) < 15]
    return np.median(keep, axis=0)


def box_of(x, y, r):
    s = 1.6 * r
    return (int(x - s / 2), int(y - s / 2), int(s), int(s))


def track(cap, fps, n, start, stop, x, y, r0, no_hough=False, box=0, label=""):
    """Track frames [start, stop). x, y, r0 at working resolution. Returns T, U, V, R, OK
    (full-res px, length n, NaN outside the window)."""
    cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    T, U, V, R, OK = (np.full(n, np.nan) for _ in range(5))
    OK[:] = 0
    tracker = None
    radii = []
    lost = 0
    for i in range(start, stop):
        okf, f = cap.read()
        if not okf:
            break
        T[i] = i / fps
        small, g = prep(f)
        if tracker is None:
            tracker = cv2.TrackerCSRT_create()
            bx = (int(x - box / 2), int(y - box / 2), int(box), int(box)) if box else box_of(x, y, r0)
            tracker.init(small, bx)
            px, py, tok = x, y, True
        else:
            tok, b = tracker.update(small)
            px, py = (b[0] + b[2] / 2, b[1] + b[3] / 2) if tok else (x, y)
        rref = np.median(radii[-200:]) if len(radii) > 20 else r0
        found = None
        if not no_hough:
            # search around the tracker prediction and the last position
            cands = []
            for cx, cy in ((px, py), (x, y)):
                w = 2.2 * rref
                x0, y0 = int(max(cx - w, 0)), int(max(cy - w, 0))
                x1, y1 = int(min(cx + w, g.shape[1])), int(min(cy + w, g.shape[0]))
                if x1 - x0 < 2 * rref or y1 - y0 < 2 * rref:
                    continue
                for c in hough(g[y0:y1, x0:x1], 0.88 * rref, 1.12 * rref, 0.80):
                    cands.append((c[0] + x0, c[1] + y0, c[2]))
            if not cands and lost >= 15:
                # lost for half a second: search the whole frame for a plate-sized circle
                for c in hough(g, 0.9 * rref, 1.1 * rref, 0.85):
                    if c[1] > g.shape[0] * 0.25:
                        cands.append(tuple(c))
                        px, py = c[0], c[1]
                        break
            if cands:
                cands.sort(key=lambda c: np.hypot(c[0] - px, c[1] - py))
                c = cands[0]
                # accept if close to the prediction or to the last position
                if min(np.hypot(c[0] - px, c[1] - py), np.hypot(c[0] - x, c[1] - y)) < 0.6 * rref:
                    found = c
        if found is not None:
            x, y = found[0], found[1]
            radii.append(found[2])
            OK[i] = 1
            R[i] = found[2]
            lost = 0
            if not tok or np.hypot(px - x, py - y) > 0.15 * rref:
                tracker = cv2.TrackerCSRT_create()
                tracker.init(small, box_of(x, y, rref))
        elif tok:
            jump = np.hypot(px - x, py - y)
            x, y = px, py
            lost += 1
            OK[i] = 1 if (no_hough and jump < 0.5 * (box or rref)) else 0
        else:
            lost += 1
        U[i], V[i] = x / HALF, y / HALF
        if i % 300 == 0:
            print(f"{label} {i}/{n} ok={int(OK[start:i+1].sum())}", flush=True)

    return T, U, V, R, OK


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--init", help="x,y,r at half res (skip auto detection)")
    ap.add_argument("--init-time", type=float, default=0.0)
    ap.add_argument("--no-hough", action="store_true", help="tracker only (no plate)")
    ap.add_argument("--box", type=float, default=0, help="tracker box side (working-res px)")
    ap.add_argument("--res", type=float, default=0.5, help="working resolution factor")
    a = ap.parse_args()
    global HALF
    HALF = a.res

    cap = cv2.VideoCapture(a.video)
    fps = cap.get(cv2.CAP_PROP_FPS)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if a.init:
        x, y, r0 = map(float, a.init.split(","))
    else:
        x, y, r0 = find_init(cap)
    start = int(a.init_time * fps)
    T, U, V, R, OK = track(cap, fps, n, start, n, x, y, r0, a.no_hough, a.box,
                           os.path.basename(a.video))
    rr = np.nanmedian(R[:int(10 * fps)]) if np.isfinite(R[:int(10 * fps)]).any() else r0
    out = os.path.join(os.path.dirname(a.video), "tracks")
    os.makedirs(out, exist_ok=True)
    name = os.path.splitext(os.path.basename(a.video))[0]
    np.savez(os.path.join(out, name + ".npz"), t=T, u=U, v=V, r=R, ok=OK,
             r_plate_px=rr / HALF, fps=fps, init=np.array([r0]))
    print(f"done {name}: frames={n} ok={int(OK.sum())} r_plate={rr/HALF:.1f}px")


if __name__ == "__main__":
    main()
