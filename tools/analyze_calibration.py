import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(__file__))

from barpath import recording
from barpath.analyzer import AnalyzerConfig, stillness_mask, still_runs
from barpath.geometry import quat_rotate, quat_conj, normalize, G
S = recording.load_session_csv(sys.argv[1])
m = S.motion; t = m.t
print("n", len(t), "rate", 1/np.median(np.diff(t)), "dur", t[-1])
print("marks", [round(k['t'],1) for k in S.marks])
q = normalize(m.q)
zA = np.median(quat_rotate(q, m.gravity)[:, 2]); zB = np.median(quat_rotate(quat_conj(q), m.gravity)[:, 2])
qq = q if abs(zA+1) <= abs(zB+1) else quat_conj(q)
print("quat mode", "direct" if qq is q else "conj", zA, zB)
aW = -quat_rotate(qq, m.user_accel * G)
c = AnalyzerConfig()
still = stillness_mask(t, m.user_accel, m.rotation_rate, c.emaTau, c.stillRot, c.stillAcc)
stillB = stillness_mask(t, m.user_accel, m.rotation_rate, c.emaTau, c.stillRot, c.stillAcc, reverse=True)
runs = still_runs(still)
def cumtrapz(y, x):
    out = np.zeros_like(y); out[1:] = np.cumsum(0.5*(y[1:]+y[:-1])*np.diff(x)[:, None] if y.ndim > 1 else 0.5*(y[1:]+y[:-1])*np.diff(x), axis=0); return out
marks = [k['t'] for k in S.marks] + [t[-1]]
names = "A table,B hang,C slow50,D fast50,E fwd50,F turn,G lifts1,G lifts2".split(",")
seg = {names[i]: (marks[i], marks[i+1]) for i in range(len(names))}

def window(a, b): return (t >= a) & (t < b)
# --- A, B: static drift
for nm in ["A table", "B hang"]:
    a, b = seg[nm]; w = window(a + 2, b - 2); idx = np.nonzero(w)[0]
    ua = np.linalg.norm(m.user_accel[idx], axis=1); rr = np.linalg.norm(m.rotation_rate[idx], axis=1)
    bias = aW[idx].mean(0)
    print(f"\n{nm}: {t[idx[-1]]-t[idx[0]]:.1f}s  |ua| median {np.median(ua)*1000:.1f} mg  rms {np.sqrt(np.mean(ua**2))*1000:.1f} mg, |rot| median {np.median(rr):.3f} rad/s")
    print(f"   world accel mean (bias) = {np.round(bias,4)} m/s²  -> {np.round(bias/G*1000,1)} mg ; still fraction {still[idx].mean():.2f}")
    for T in [1, 2, 5, 10]:
        j = idx[t[idx] - t[idx[0]] <= T]
        v = cumtrapz(aW[j], t[j]); p = cumtrapz(v, t[j])
        print(f"   uncorrected after {T:>2}s: |v| {np.linalg.norm(v[-1]):.3f} m/s, |p| {np.linalg.norm(p[-1])*100:.1f} cm (vert {p[-1,2]*100:+.1f})")
    gh = normalize(m.gravity[idx]); ang = np.degrees(np.arccos(np.clip(gh @ gh[0], -1, 1)))
    print(f"   gravity direction wander max {ang.max():.2f} deg")

# --- moves between still runs (ZUPT) for C, D, E, F
def moves(nm, minhold=0.4):
    a, b = seg[nm] if isinstance(nm, str) else nm
    rs = [(r0, r1) for (r0, r1) in runs if t[r0] >= a and t[r1] <= b and t[r1]-t[r0] >= minhold]
    out = []
    for (p0, p1), (n0, n1) in zip(rs[:-1], rs[1:]):
        nz = np.nonzero(stillB[p0:p1+1])[0]; s = p0 + (nz[-1] if len(nz) else 0)
        e = n0
        if e - s < 5: continue
        vr = cumtrapz(aW[s:e+1], t[s:e+1]); drift = vr[-1].copy()
        frac = (t[s:e+1]-t[s])/(t[e]-t[s])
        v = vr - drift[None]*frac[:, None]; p = cumtrapz(v, t[s:e+1])
        pr = cumtrapz(vr, t[s:e+1])
        ang = np.degrees(np.arccos(np.clip(normalize(m.gravity[s]) @ normalize(m.gravity[e]), -1, 1)))
        out.append(dict(t=t[s], dur=t[e]-t[s], dz=p[-1, 2], dh=np.linalg.norm(p[-1, :2]), d3=np.linalg.norm(p[-1]),
                        drift=np.linalg.norm(drift), vpk=np.abs(v[:, 2]).max(), vhpk=np.linalg.norm(v[:, :2], axis=1).max(),
                        rawdz=pr[-1, 2], rot=np.degrees(np.trapezoid(np.linalg.norm(m.rotation_rate[s:e+1], axis=1), t[s:e+1])), gang=ang))
    return out
for nm in [(163.3,212.2),(212.2,259.0),(259.0,304.0)] if len(sys.argv)>2 else ["C slow50", "D fast50", "E fwd50", "F turn"]:
    mv = moves(nm)
    print(f"\n{nm}: {len(mv)} moves")
    for d in mv:
        print(f"   t={d['t']:6.1f} dur {d['dur']:.2f}s  dz {d['dz']*100:+6.1f} cm  dh {d['dh']*100:5.1f} cm  |d| {d['d3']*100:5.1f}  "
              f"drift {d['drift']:.3f} m/s  vz pk {d['vpk']:.2f}  vh pk {d['vhpk']:.2f}  raw dz {d['rawdz']*100:+6.1f}  rot {d['rot']:.0f}°  tilt chg {d['gang']:.0f}°")

# ---- experiment: drift distributed by time vs by rotation
def zupt(s, e, mode):
    tt = t[s:e+1]; vr = cumtrapz(aW[s:e+1], tt); drift = vr[-1].copy()
    if mode == 'time':
        w = (tt - tt[0]) / (tt[-1] - tt[0])
    else:
        r = np.linalg.norm(m.rotation_rate[s:e+1], axis=1)
        cr = np.concatenate([[0], np.cumsum(0.5*(r[1:]+r[:-1])*np.diff(tt))])
        wr = cr / cr[-1] if cr[-1] > 0 else (tt-tt[0])/(tt[-1]-tt[0])
        wt = (tt - tt[0]) / (tt[-1] - tt[0])
        a = {'rot': 1.0, 'mix': 0.5}[mode]
        w = a*wr + (1-a)*wt
    v = vr - drift[None]*w[:, None]
    return cumtrapz(v, tt)[-1]
if len(sys.argv) > 3:
    for nm, sec, key in [("D fast", (129.5,163.3), 'z'), ("E fwd", (212.2,246.0), 'h')]:
        a, b = sec
        rs = [(r0, r1) for (r0, r1) in runs if t[r0] >= a and t[r1] <= b and t[r1]-t[r0] >= 0.4]
        res = {k: [] for k in ['time','mix','rot']}
        for (p0,p1),(n0,n1) in zip(rs[:-1], rs[1:]):
            nz = np.nonzero(stillB[p0:p1+1])[0]; s = p0 + (nz[-1] if len(nz) else 0)
            for k in res:
                d = zupt(s, n0, k)
                val = abs(d[2]) if key=='z' else np.linalg.norm(d[:2])
                if val > 0.2: res[k].append(val)
        for k,vals in res.items():
            vals=np.array(vals)*100; print(f"{nm} [{k:4}] n={len(vals)} mean {vals.mean():.1f} cm  sd {vals.std():.1f}  vals {np.round(vals,1)}")
