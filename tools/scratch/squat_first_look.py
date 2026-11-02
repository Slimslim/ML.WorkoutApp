import numpy as np, re, sys
def bp(x,fs,lo,hi):
    n=len(x); X=np.fft.rfft(x-x.mean()); f=np.fft.rfftfreq(n,1/fs)
    X[(f<lo)|(f>hi)]=0; return np.fft.irfft(X,n)
files={'BS 45x5':'session-A3745A71-D6E1-4BE2-BAC0-92BDB85E92F5.csv','BS 95x6':'session-60A37E96-24F3-4A6F-9991-AA09B0663A71.csv','FS 95x5':'session-D4C61F27-0DA6-4846-B091-732BD9CCEAD9.csv'}
for k,f in files.items():
    p='data/raw/2026-11-01-squats/'+f; rows=[];marks=[]
    for l in open(p):
        if l.startswith('#'):
            m=re.search(r'# mark t=([\d.]+)',l)
            if m: marks.append(float(m.group(1)))
            continue
        if l.startswith('t,'): continue
        try:
            r=[float(x) for x in l.split(',')]
            if len(r)==14: rows.append(r)
        except: pass
    d=np.array(rows); t=d[:,0]; a=d[:,5:8]; g=d[:,8:11]
    fs=1/np.median(np.diff(t))
    up=-(a*g).sum(1)*9.81
    upf=bp(up,fs,0.1,4)
    v=bp(np.cumsum(upf)/fs,fs,0.12,4); x=bp(np.cumsum(v)/fs,fs,0.12,4)
    marks=sorted(set(marks)); lo,hi=marks[0],marks[-1]
    # bottoms = local minima of x with prominence, spaced >=1.2 s
    sel=np.where((t>lo)&(t<hi))[0]; xs=x[sel]
    w=int(0.6*fs); bots=[]
    for i in range(w,len(xs)-w):
        if xs[i]==xs[i-w:i+w].min() and xs[i-w:i+w].max()-xs[i] > 0.15:
            if not bots or i-bots[-1]>1.2*fs: bots.append(i)
    out=[]
    for i in bots:
        j=sel[i]; seg=v[j:j+int(1.5*fs)]
        out.append(f"t={t[j]:.1f}s depth {(x[sel[max(0,i-w):i+w]].max()-x[j])*100:.0f}cm upV {seg.max():.2f}m/s")
    print(f"{k}: {fs:.0f} Hz, {t[-1]:.0f}s, marks {[round(m,1) for m in marks]}, set {hi-lo:.1f}s, reps found {len(bots)}")
    for o in out: print('   ',o)
