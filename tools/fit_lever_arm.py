"""Fit the wrist→bar lever arm r (watch device frame) so that bar = watch + R(t)·r matches the
video-tracked bar paths. Usage: python3 tools/fit_lever_arm.py (uses data/raw/2026-10-29-gym)."""
import sys, glob, numpy as np
import os; sys.path.insert(0, os.path.dirname(__file__))
import compare_video as cv
from barpath.analyzer import world_acceleration
from barpath.geometry import quat_rotate
from scipy.optimize import least_squares
from barpath.recording import LiftRecording
data=[]
for v in sorted(glob.glob('data/raw/2026-10-29-gym/video_paths/2026-10-29_*_1.csv')):
    lt=v.split('_')[-3]; sid=v.split('_')[-2]
    if lt not in ('snatch','powerSnatch','powerClean','cleanAndJerk'): continue
    s=glob.glob(f'data/raw/2026-10-29-gym/session-{sid}*.csv')[0]
    tv,xv,yv=cv.load_video(v); vz=np.gradient(yv,tv)
    S,lifts=cv.watch_lifts(s)
    m=S.motion; t=m.t
    for k,(th,a) in enumerate(lifts,1):
        p=a.path; tw=p.t+th
        off,corr=cv.align(tw,p.vVertical,tv,vz)
        if off is None or corr<0.85: continue
        # rebuild the rotation for the analyzed slice
        i_home=int(np.searchsorted(t,th-1e-6))
        n=len(p.t); idx=np.clip(i_home+np.arange(n),0,len(t)-1)
        q=m.q[idx]
        # choose convention like analyzer: test gravity -> -z
        from barpath.geometry import normalize, quat_conj
        qn=normalize(q); g=m.gravity[idx]
        zA=np.median(quat_rotate(qn,g)[:,2]); zB=np.median(quat_rotate(quat_conj(qn),g)[:,2])
        qq=qn if abs(zA+1)<=abs(zB+1) else quat_conj(qn)
        f=quat_rotate(qq[:1],np.array([0,0,1.0]))[0]; f[2]=0; f/=np.linalg.norm(f)
        x0=np.interp(tw[0]+off,tv,xv); y0=np.interp(tw[0]+off,tv,yv)
        xvi=np.interp(tw+off,tv,xv)-x0; yvi=np.interp(tw+off,tv,yv)-y0
        xc=cv.end_over_start(p.t,p.forward)
        data.append(dict(name=f'{lt[:6]}{sid[:4]}#{k}',qq=qq,f=f,zw=p.vertical,xw=xc,xv=xvi,yv=yvi))
print(len(data),'lifts')
def resid(r, use_x=True):
    out=[]
    for d in data:
        off=quat_rotate(d['qq'],r)  # world offset
        rel=off-off[0]
        out.append(d['zw']+rel[:,2]-d['yv'])
        if use_x: out.append(0.5*(d['xw']+rel@d['f']-d['xv']))
    return np.concatenate(out)
for use_x in (False,True):
    sol=least_squares(lambda r: resid(r,use_x), x0=np.zeros(3))
    r=sol.x
    print(('vertical only' if not use_x else 'vertical+horizontal'),'offset r (device frame, cm):',np.round(r*100,1),'|r|',round(np.linalg.norm(r)*100,1))
r=sol.x
print('lift: vert RMS before -> after | horiz(eos) RMS before -> after (cm) | rise video / watch / watch+offset')
for d in data:
    off=quat_rotate(d['qq'],r); rel=off-off[0]
    vb=np.sqrt(np.mean((d['zw']-d['yv'])**2)); va=np.sqrt(np.mean((d['zw']+rel[:,2]-d['yv'])**2))
    hb=np.sqrt(np.mean((d['xw']-d['xv'])**2)); ha=np.sqrt(np.mean((d['xw']+rel@d['f']-d['xv'])**2))
    print(f"{d['name']:14} {vb*100:5.1f} -> {va*100:5.1f} | {hb*100:5.1f} -> {ha*100:5.1f} | {d['yv'][-1]*100:4.0f} / {d['zw'][-1]*100:4.0f} / {(d['zw'][-1]+rel[-1,2])*100:4.0f}")
