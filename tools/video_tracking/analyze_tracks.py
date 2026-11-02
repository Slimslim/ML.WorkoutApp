"""Turn tracks into per-lift bar-path CSVs, a per-lift table and overlay images.

Olympic lifts: videos/tracks/lifts/<video>_lift<k>.npz (one watch lift each, track_lifts.py).
Deadlifts: videos/tracks/<video>.npz (whole set, track_plate.py), split into reps here.

Usage: .venv/bin/python tools/video_tracking/analyze_tracks.py [--data data/raw/<date>]
"""
import argparse, csv, datetime as dt, glob, os, re, subprocess
import cv2
import numpy as np
from scipy.signal import savgol_filter, medfilt

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VID = os.path.join(REPO, "videos")
GYM = os.path.join(REPO, "data", "raw", "2026-10-29-gym")  # session CSVs (--data)
OUT = os.path.join(GYM, "video_paths")


def set_data(path):
    global GYM, OUT
    GYM = os.path.abspath(path)
    OUT = os.path.join(GYM, "video_paths")
OVL = os.path.join(VID, "overlays")

PLATE_CM = 45.0
# lifter faces right (+1) outdoors, left (-1) in the indoor deadlift videos
FACING = {"other_8B36E5AE": -1, "other_0A3AE1B5": -1, "unmatched_IMG9234": -1}
DEADLIFTS = ("other_", "unmatched_")


def key(name):
    return name.split("_", 1)[1].rsplit("_", 1)[0]  # e.g. snatch_C288475F


def sessions():
    out = {}
    for f in glob.glob(os.path.join(GYM, "session-*.csv")):
        lines = [l for l in open(f) if l.startswith("#")]
        h = lines[0]
        sid = re.search(r"sessionId=(\S+),", h).group(1)
        start = dt.datetime.fromisoformat(re.search(r"startDate=(\S+),", h).group(1).replace("Z", "+00:00"))
        lifts, s = [], None
        for l in lines:
            if "liftStarted" in l:
                s = float(re.search(r"homing=([\d.]+)", l).group(1))
            elif "liftEnded" in l:
                lifts.append((s, float(re.search(r"end=([\d.]+)", l).group(1))))
        out[sid[:8]] = dict(sid=sid, start=start, lifts=lifts,
                            type=re.search(r"liftType=(\S+)", h).group(1))
    return out


def video_start(path):
    s = subprocess.run(["mdls", "-raw", "-name", "kMDItemContentCreationDate", path],
                       capture_output=True, text=True).stdout.strip()
    return dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z")


def segment(y, fps, deadlift):
    """Lift episodes: bar > 10 cm above rest; start = last low point before the main rise,
    finish = last held position (still >= 0.2 s) above half height before the bar comes down."""
    speed = np.abs(np.gradient(y) * fps)
    up = y > 10
    eps, i, n = [], 0, len(y)
    while i < n:
        if up[i]:
            j = i
            while j < n and up[j]:
                j += 1
            eps.append((i, j - 1))
            i = j
        i += 1
    lifts = []
    for a, b in eps:
        peak = a + int(np.nanargmax(y[a:b + 1]))
        rise = y[peak]
        if rise < (30 if deadlift else 90) or b - a < 0.5 * fps:
            continue
        c = a + int(np.argmax(y[a:b + 1] > 30))
        s = c
        while s > 1 and y[s - 1] < y[s] - 0.05:
            s -= 1
        still = (speed < 25) & (y > 0.5 * rise)
        f0 = f1 = None
        k = b
        while k > peak:
            if still[k]:
                e = k
                while k > peak and still[k]:
                    k -= 1
                if e - k >= 6:
                    f0, f1 = k + 1, e
                    break
            k -= 1
        if f0 is None:
            f0 = f1 = peak
        end = b
        while end < n - 1 and y[end] > y[s] + 3 and end - b < 2 * fps:
            end += 1
        catch = None
        p1 = c
        while p1 < f1 and not (y[p1 + 1] < y[p1] and y[p1] > 60):
            p1 += 1
        if p1 < f1:
            lo = p1 + int(np.argmin(y[p1:f1 + 1]))
            if y[p1] - y[lo] >= 3 and lo < f1 and not deadlift:
                catch = lo
        lifts.append(dict(start=s, peak=peak, f0=f0, f1=f1, catch=catch, pull_peak=p1,
                          end=min(end + int(0.3 * fps), n - 1)))
    return lifts


def radius_fit(v, r, ok, fps):
    """Plate radius (full-res px) as a linear function of image row, from sharp slow frames.
    The phone is not exactly parallel to the bar's plane, so the scale changes with height."""
    rf = r / 0.5  # tracker radii are at half resolution
    slow = np.abs(np.gradient(v) * fps) < 150
    sel = (ok == 1) & np.isfinite(rf) & np.isfinite(v) & slow & (v > 1.2 * rf)  # not clipped
    if sel.sum() < 10:
        sel = np.isfinite(rf) & np.isfinite(v)
    vv, rr = v[sel], rf[sel]
    p = np.array([0.0, np.median(rr)])
    if np.ptp(vv) > 300:
        keep = np.ones(len(vv), bool)
        for _ in range(3):
            p = np.polyfit(vv[keep], rr[keep], 1)
            res = rr - np.polyval(p, vv)
            mad = np.median(np.abs(res[keep])) + 1e-6
            keep = np.abs(res) < 3 * 1.4826 * mad
    return p  # r(v) = p[0] * v + p[1]


def positions(u, v, r, ok, fps, facing, rest_frames, p=None):
    valid = np.isfinite(u)
    idx = np.arange(len(u))
    uf = np.interp(idx, idx[valid], u[valid])
    vf = np.interp(idx, idx[valid], v[valid])
    if p is None:
        p = radius_fit(v, r, ok, fps)
    R = lambda vv: np.polyval(p, vv)
    vref = float(np.median(vf[rest_frames]))
    half = PLATE_CM / 2
    # y: integrate the local scale (half / r(v)) along the image column
    if abs(p[0]) > 1e-6:
        y_raw = -(half / p[0]) * np.log(R(vf) / R(vref))
    else:
        y_raw = -(vf - vref) * half / p[1]
    # x: distance from the image centre column times the local scale at that row
    x_raw = facing * (uf - 540.0) * half / R(vf)
    xs = savgol_filter(medfilt(x_raw, 3), 7, 2)
    ys = savgol_filter(medfilt(y_raw, 3), 7, 2)
    y0 = np.median(ys[rest_frames])
    rpx = float(R(vref))
    return uf, vf, x_raw, y_raw - y0, xs, ys - y0, half / rpx, rpx, valid, p


def overlay(cap, frame, uf, vf, ok, L, rpx, title, m):
    cap.set(cv2.CAP_PROP_POS_FRAMES, frame)
    okf, img = cap.read()
    if not okf:
        return None
    a, pk, f1 = L["start"], L["peak"], L["f1"]
    pts = np.stack([uf, vf], 1)
    for j in range(a, L["end"]):
        col = (160, 160, 160) if j >= f1 else (0, 255, 255) if ok[j] == 1 else (0, 0, 255)
        cv2.line(img, tuple(np.int32(pts[j])), tuple(np.int32(pts[j + 1])), col, 4)
    for j, c in ((a, (0, 255, 0)), (pk, (255, 0, 255)), (f1, (255, 128, 0))):
        cv2.circle(img, tuple(np.int32(pts[j])), 14, c, -1)
    cv2.circle(img, tuple(np.int32(pts[a])), int(rpx), (0, 255, 0), 2)
    txt = [title,
           f"rise {m['rise_cm']} cm  peak {m['peak_cm']} cm",
           f"fwd {m['fwd_max_cm']}  back {m['back_max_cm']}  finish dx {m['finish_dx_cm']} cm",
           "yellow circle found, red tracker only / plate clipped, grey after finish"]
    for k, s_ in enumerate(txt):
        yy = img.shape[0] - 230 + 50 * k
        cv2.putText(img, s_, (30, yy), 0, 1.1, (0, 0, 0), 6)
        cv2.putText(img, s_, (30, yy), 0, 1.1, (255, 255, 255), 2)
    return img


def clip_flag(ok, vf, p):
    """Plate partly above the top of the frame: the circle fit is unreliable there."""
    ok = ok.copy()
    ok[vf < np.polyval(p, vf)] = 0
    return ok


def metrics(L, xs, ys):
    a, f0, f1, pk = L["start"], L["f0"], L["f1"], L["peak"]
    dx = xs[a:f1 + 1] - xs[a]
    cc = L.get("catch")
    return dict(catch_after_start_s=f"{(cc - a) / 30.0:.2f}" if cc is not None else "",
                catch_y_cm=f"{ys[cc] - ys[a]:.1f}" if cc is not None else "",
                catch_dx_cm=f"{xs[cc] - xs[a]:.1f}" if cc is not None else "",
                peak_cm=f"{ys[pk] - ys[a]:.1f}",
                rise_cm=f"{np.median(ys[f0:f1 + 1]) - ys[a]:.1f}",
                fwd_max_cm=f"{dx.max():.1f}", back_max_cm=f"{dx.min():.1f}",
                finish_dx_cm=f"{np.median(xs[f0:f1 + 1]) - xs[a]:.1f}")


def write_csv(path, t, x_raw, y_raw, ok, valid, x0, y0):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["t", "x_cm", "y_cm", "ok"])
        for i in range(len(t)):
            if valid[i]:
                w.writerow([f"{t[i]:.4f}", f"{x_raw[i] - x0:.2f}", f"{y_raw[i] - y0:.2f}", int(ok[i])])


def main():
    ses = sessions()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(OVL, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "*.csv")):
        os.remove(old)  # regenerated below
    rows = []
    # Olympic lifts: one npz per watch lift
    for npz in sorted(glob.glob(os.path.join(VID, "tracks", "lifts", "*.npz"))):
        lname = os.path.splitext(os.path.basename(npz))[0]
        name, k = lname.rsplit("_lift", 1)
        d = np.load(npz)
        t, fps, ok = d["t"], float(d["fps"]), d["ok"]
        facing = FACING.get(key(name), +1)
        rest = slice(0, int(0.3 * fps))
        # pass 1 (constant scale) only to find the lift; then fit the radius over
        # window start -> finish, before the drop moves the bar toward/away from the camera
        _, _, _, _, _, ys, _, _, _, _ = positions(d["u"], d["v"], d["r"], ok, fps, facing, rest,
                                                  p=np.array([0.0, np.nanmedian(d["r"][rest]) / 0.5]))
        lifts = segment(ys, fps, deadlift=False)
        if not lifts:
            print(lname, "no lift found in window")
            continue
        L = max(lifts, key=lambda L: ys[L["peak"]])
        pre = slice(0, L["f1"] + 1)
        p = radius_fit(d["v"][pre], d["r"][pre], ok[pre], fps)
        uf, vf, x_raw, y_raw, xs, ys, cm, rpx, valid, p = positions(
            d["u"], d["v"], d["r"], ok, fps, facing, rest, p=p)
        ok = clip_flag(ok, vf, p)
        lifts = segment(ys, fps, deadlift=False)
        L = max(lifts, key=lambda L: ys[L["peak"]])
        a = L["start"]
        offset, h, e = float(d["offset"]), float(d["homing"]), float(d["end"])
        sl = slice(a, L["f1"] + 1)
        m = metrics(L, xs, ys)
        rows.append(dict(video=name, lift=k, csv=f"{lname}.csv",
                         t_start=f"{t[a]:.2f}", t_peak=f"{t[L['peak']]:.2f}",
                         t_finish=f"{t[L['f1']]:.2f}", t_end=f"{t[L['end']]:.2f}", **m,
                         ok_circle=f"{(ok[sl] == 1).mean():.2f}",
                         clipped=f"{(vf[sl] < np.polyval(p, vf[sl])).mean():.2f}",
                         cm_per_px=f"{cm:.4f}", r_slope=f"{p[0]:.4f}", facing=facing, session=str(d["session"]),
                         watch_lift=int(d["watch_lift"]), watch_homing_video_s=f"{h + offset:.2f}",
                         watch_end_video_s=f"{e + offset:.2f}",
                         video_minus_watch_s=f"{t[a] - (h + offset):+.2f}", video_offset_s=f"{offset:.2f}"))
        write_csv(os.path.join(OUT, lname + ".csv"), t, x_raw, y_raw, ok, valid, xs[a], ys[a])
        cap = cv2.VideoCapture(os.path.join(VID, name + ".mov"))
        img = overlay(cap, int(round(t[a] * fps)), uf, vf, ok, L, rpx, f"{name} lift {k}", m)
        if img is not None:
            cv2.imwrite(os.path.join(OVL, f"{lname}.jpg"), img)
        print(lname, m)
    # Deadlifts: whole-set tracks, one "lift" per rep
    for npz in sorted(glob.glob(os.path.join(VID, "tracks", "*.npz"))):
        name = os.path.splitext(os.path.basename(npz))[0]
        if not key(name).startswith(DEADLIFTS):
            continue
        d = np.load(npz)
        t, fps, ok = d["t"], float(d["fps"]), d["ok"]
        first = int(np.argmax(np.isfinite(d["u"])))
        facing = FACING.get(key(name), +1)
        uf, vf, x_raw, y_raw, xs, ys, cm, rpx, valid, p = positions(
            d["u"], d["v"], d["r"], ok, fps, facing, slice(first, first + int(fps)))
        tt = np.where(np.isfinite(t), t, np.arange(len(t)) / fps)
        lifts = segment(ys, fps, deadlift=True)
        s = ses.get(name.split("_")[2])
        offset = (s["start"] - video_start(os.path.join(VID, name + ".mov"))).total_seconds() if s else None
        # the watch logged one lift per deadlift set: match it to the nearest rep start
        match = {}
        if s:
            for wk, (h, e) in enumerate(s["lifts"], 1):
                j = int(np.argmin([abs(tt[L["start"]] - (h + offset)) for L in lifts]))
                match[j] = (wk, h, e)
        cap = cv2.VideoCapture(os.path.join(VID, name + ".mov"))
        for j, L in enumerate(lifts):
            k = j + 1
            a = L["start"]
            m = metrics(L, xs, ys)
            # per-rep CSV: from the previous rep's end (or 0.5 s before) to this rep's end
            w0 = max(lifts[j - 1]["end"] if j else 0, a - int(0.5 * fps))
            w1 = L["end"] + 1
            lname = f"{name}_lift{k}"
            sl = slice(a, L["f1"] + 1)
            wk = match.get(j)
            rows.append(dict(video=name, lift=k, csv=f"{lname}.csv",
                             t_start=f"{tt[a]:.2f}", t_peak=f"{tt[L['peak']]:.2f}",
                             t_finish=f"{tt[L['f1']]:.2f}", t_end=f"{tt[L['end']]:.2f}", **m,
                             ok_circle=f"{(ok[sl] == 1).mean():.2f}", clipped="0.00",
                             cm_per_px=f"{cm:.4f}", r_slope=f"{p[0]:.4f}", facing=facing, session=s["sid"] if s else "",
                             watch_lift=wk[0] if wk else "",
                             watch_homing_video_s=f"{wk[1] + offset:.2f}" if wk else "",
                             watch_end_video_s=f"{wk[2] + offset:.2f}" if wk else "",
                             video_minus_watch_s=f"{tt[a] - (wk[1] + offset):+.2f}" if wk else "",
                             video_offset_s=f"{offset:.2f}" if offset is not None else ""))
            write_csv(os.path.join(OUT, lname + ".csv"), tt[w0:w1], x_raw[w0:w1], y_raw[w0:w1],
                      ok[w0:w1], valid[w0:w1], xs[a], ys[a])
            img = overlay(cap, a, uf, vf, ok, L, rpx, f"{name} rep {k}", m)
            if img is not None:
                cv2.imwrite(os.path.join(OVL, f"{lname}.jpg"), img)
        print(name, f"{len(lifts)} reps")
    # per-video CSV (input of tools/compare_video.py): the video's lift windows in time order,
    # each in its own lift's coordinates; frames between windows are simply absent
    for name in sorted({r["video"] for r in rows}):
        seen, out = set(), []
        for f in sorted(glob.glob(os.path.join(OUT, name + "_lift*.csv")),
                        key=lambda f: int(f.rsplit("_lift", 1)[1][:-4])):
            for r in list(csv.reader(open(f)))[1:]:
                if r[0] not in seen:
                    seen.add(r[0])
                    out.append(r)
        out.sort(key=lambda r: float(r[0]))
        with open(os.path.join(OUT, name + ".csv"), "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["t", "x_cm", "y_cm", "ok"])
            w.writerows(out)
    rows.sort(key=lambda r: (r["video"], int(r["lift"])))
    with open(os.path.join(OUT, "lifts.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=GYM, help="folder with the session-*.csv files")
    set_data(ap.parse_args().data)
    main()
