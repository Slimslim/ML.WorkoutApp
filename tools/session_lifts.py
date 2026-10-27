import sys, os, datetime
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from barpath import recording, analyzer
from barpath.recording import LiftRecording, AccelSeries
S = recording.load_session_csv(sys.argv[1]); m = S.motion; t = m.t
ends = [e for e in S.events if e['name'] == 'liftEnded']
recs = []
for k, e in enumerate(ends):
    h, en = float(e['homing']), float(e['end'])
    i0 = int(np.searchsorted(t, h - 2.0)); i1 = int(np.searchsorted(t, en + 1.0))
    sl = m.slice(i0, i1)
    sl = type(sl)(sl.t - sl.t[0], sl.q, sl.user_accel, sl.gravity, sl.rotation_rate)
    rec = LiftRecording(session_id=S.session_id, index=k+1, lift_type='snatch', start_date=S.start_date, motion=sl,
                        homing_time=h - t[i0], end_time=en - t[i0], end_reason=e.get('reason'))
    recs.append((t[i0], rec))
if __name__ == '__main__':
    for t0, rec in recs:
        A = analyzer.analyze(rec); M = A.metrics
        print(f"lift at {t0:6.1f}: watch end={rec.end_reason} conf={A.confidence} notes={A.notes}")
        print(f"   peak v {M.peakVerticalVelocity:.2f}  max h {M.maxHeight:.2f}  catch {M.catchHeight}  FINAL {M.finalHeight:.2f} (expect 1.55)  fwd [{M.maxBackward:.2f},{M.maxForward:.2f}]  dur {M.duration:.2f}")
        for s in A.segments: print(f"   seg dur {s.duration:.2f} gain {s.heightGain:+.2f} drift {s.driftCorrection:.2f}")
