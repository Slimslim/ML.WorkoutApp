"""W29: every recording says how it was made. The loader keeps the new header keys and events,
older files still load, and the battery drain per hour comes out of the battery lines."""
import os
import sys

import pytest

from barpath import recording

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import recording_info  # noqa: E402

COLS = "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\n"
OLD_HEAD = ("# barpath-session v1, sessionId=00000000-0000-0000-0000-000000000029, "
            "startDate=2026-11-16T10:00:00.250Z, workout=wod.helen, watchModel=Watch7_5, "
            "watchOS=11.1, wrist=left, crown=right, appBuild=16, sampleRate=100, "
            "planProfile=standard, gps=off")
W29_KEYS = (", batteryStart=83, charging=no, lowPower=off, thermal=nominal, units=kg, "
            "hrZoneSource=custom, phoneModel=iPhone16_1, phoneOS=18.1, phoneBuild=16")


def _row(t):
    return f"{t:.6f},1.00000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,0.00000,-1.00000,0.00000,0.00000,0.00000\n"


def write(path, head, events, end=None, seconds=3):
    with open(path, "w") as f:
        f.write(head + "\n")
        f.write(COLS)
        f.write("# event t=0.000000 name=segment index=0 kind=station source=start\n")
        for i in range(seconds * 100):
            f.write(_row(i / 100.0))
        for line in events:
            f.write(line + "\n")
        if end:
            f.write(end + "\n")


def test_w29_header_and_events(tmp_path):
    p = tmp_path / "session-w29.csv"
    events = [f"# event t={60.0 * k:.6f} name=battery level={83 - k} charging=no" for k in range(1, 11)]
    events.insert(3, "# event t=200.000000 name=thermal state=fair")
    events.insert(5, "# event t=310.500000 name=lowPower state=on")
    write(p, OLD_HEAD + W29_KEYS, events,
          end="# event t=630.000000 name=end reason=athlete batteryEnd=72 duration=630.0 backgroundRecovery=yes")
    s = recording.load_session_csv(p)
    # the existing keys are unchanged
    assert s.workout == "wod.helen"
    assert (s.source_rate, s.plan_profile, s.gps) == (100.0, "standard", "off")
    assert s.header["watchModel"] == "Watch7_5" and s.header["appBuild"] == "16"
    info = s.recording_info()
    assert info.battery_start == 83.0 and info.battery_end == 72.0
    assert (info.charging, info.low_power, info.thermal) == ("no", "off", "nominal")
    assert (info.units, info.hr_zone_source) == ("kg", "custom")
    assert (info.phone_model, info.phone_os, info.phone_build) == ("iPhone16_1", "18.1", "16")
    assert info.end_reason == "athlete" and info.duration == 630.0
    assert len(info.battery) == 10 and info.battery[0] == (60.0, 82.0)
    # 83 % -> 72 % over 630 s
    assert info.battery_per_hour() == pytest.approx(11 / (630 / 3600))
    names = [e["name"] for e in s.events]
    assert names.count("battery") == 10 and "thermal" in names and "lowPower" in names
    lp = next(e for e in s.events if e["name"] == "lowPower")
    assert lp["state"] == "on" and lp["t"] == 310.5
    end = next(e for e in s.events if e["name"] == "end")
    assert end["backgroundRecovery"] == "yes"
    # the CLI prints it
    text = recording_info.report(p)
    assert "start 83%, end 72%" in text and "10 minute lines" in text and "%/h" in text
    assert "end        athlete" in text


def test_old_recording_still_loads(tmp_path):
    p = tmp_path / "session-old.csv"
    write(p, OLD_HEAD, ["# event t=5.000000 name=hr bpm=150"])
    s = recording.load_session_csv(p)
    assert s.workout == "wod.helen" and len(s.motion) == 300
    info = s.recording_info()
    assert info.battery_start is None and info.end_reason is None and info.battery == []
    assert info.battery_per_hour() is None
    assert "missing" in recording_info.report(p)


def test_cut_off_recording_has_no_end_reason(tmp_path):
    p = tmp_path / "session-crash.csv"
    events = [f"# event t={60.0 * k:.6f} name=battery level={90 - 2 * k} charging=no" for k in range(1, 7)]
    write(p, OLD_HEAD + W29_KEYS.replace("batteryStart=83", "batteryStart=90"), events)
    info = recording.load_session_csv(p).recording_info()
    assert info.end_reason is None and info.battery_end is None
    # start 90 at t=0, last line 78 at 360 s
    assert info.battery_per_hour() == pytest.approx(12 / 0.1)


def test_unknown_battery_is_skipped(tmp_path):
    # The watch writes 'unknown' when the level cannot be read (-1 from WatchKit).
    p = tmp_path / "session-unknown.csv"
    write(p, OLD_HEAD + W29_KEYS.replace("batteryStart=83", "batteryStart=unknown"),
          ["# event t=60.000000 name=battery level=unknown charging=unknown"],
          end="# event t=61.000000 name=end reason=system batteryEnd=unknown duration=61.0")
    info = recording.load_session_csv(p).recording_info()
    assert info.battery_start is None and info.battery == [] and info.battery_end is None
    assert info.end_reason == "system"
