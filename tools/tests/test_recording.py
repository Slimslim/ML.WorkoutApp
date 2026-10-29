import json

import numpy as np

from barpath.recording import LiftRecording, load_session_csv, parse_iso8601, save_session_csv
from barpath.simulate import simulate_lift, simulate_session


def test_json_roundtrip(tmp_path):
    rec = simulate_lift("snatch", seed=3, fill_detector_fields=False).recording
    p = tmp_path / "r.json"
    rec.save(p)
    d = json.loads(p.read_text())
    assert set(d["motion"]) == {"t", "qw", "qx", "qy", "qz", "ax", "ay", "az", "gx", "gy", "gz", "rx", "ry", "rz"}
    assert set(d["accel"]) == {"t", "x", "y", "z"}
    assert d["startDate"].endswith("Z") and "." not in d["startDate"]
    back = LiftRecording.load(p)
    assert back.id == rec.id and back.lift_type == "snatch" and back.end_reason == "drop"
    assert np.allclose(back.motion.user_accel, rec.motion.user_accel, atol=1e-6)
    assert np.allclose(back.accel.accel, rec.accel.accel, atol=1e-6)


def test_empty_accel_and_fractional_date(tmp_path):
    rec = simulate_lift("snatch", seed=3, fill_detector_fields=False).recording
    d = rec.to_dict(6)
    d["accel"] = {"t": [], "x": [], "y": [], "z": []}
    d["startDate"] = "2026-10-25T18:03:11.250Z"
    r = LiftRecording.from_dict(d)
    assert len(r.accel) == 0
    assert r.start_date == parse_iso8601("2026-10-25T18:03:11.250+00:00")


def test_session_csv_roundtrip_with_comment_lines(tmp_path):
    ses = simulate_session(seed=1)
    p = tmp_path / "s.csv"
    m = ses.motion.slice(0, 500)
    save_session_csv(p, m, ses.session_id, ses.start_date, "snatch")
    lines = p.read_text().splitlines()
    lines.insert(100, "# mark t=0.485 n=1 label=mark")
    lines.insert(300, "# event t=1.4 name=liftEnded homing=0.2 end=1.1 reason=drop")
    p.write_text("\n".join(lines) + "\n")
    s = load_session_csv(p)
    assert s.session_id == ses.session_id and s.lift_type == "snatch"
    assert len(s.motion) == 500
    assert np.allclose(s.motion.t, m.t, atol=1e-6)
    assert np.allclose(s.motion.gravity, m.gravity, atol=1e-5)
    assert s.marks == [{"t": 0.485, "n": 1, "label": "mark"}]
    assert s.events[0]["name"] == "liftEnded" and s.events[0]["end"] == 1.1 and s.events[0]["reason"] == "drop"


def test_simulator_uses_physical_coremotion_convention():
    """raw = gravity + userAccel, and |raw| > 1 g while the wrist accelerates upward."""
    sim = simulate_lift("snatch", seed=1, fill_detector_fields=False)
    m, acc = sim.recording.motion, sim.recording.accel
    raw_at_motion = np.column_stack([np.interp(m.t, acc.t, acc.accel[:, k]) for k in range(3)])
    assert np.median(np.linalg.norm(raw_at_motion - (m.gravity + m.user_accel), axis=1)) < 0.03
    a_up = sim.trajectory.acceleration(m.t + sim.t_offset)[:, 2]
    strong = a_up > 5.0
    assert strong.sum() > 10
    assert np.all(np.linalg.norm(raw_at_motion[strong], axis=1) > 1.2)
    ghat = m.gravity / np.linalg.norm(m.gravity, axis=1, keepdims=True)
    assert np.all(np.sum(m.user_accel[strong] * ghat[strong], axis=1) > 0.3)   # userAccel·ĝ ≈ a_up/G
