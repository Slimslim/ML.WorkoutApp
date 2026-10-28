"""Workout model mirror of BarPathKit's Workout*.swift (docs/WORKOUT_SPEC.md §2).

Times are seconds since 1970 (or, for CSV replays, seconds on the CSV's own clock)."""
from __future__ import annotations

import json
import uuid as _uuid
import math
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

from .recording import format_iso8601, load_session_csv, parse_iso8601

SEGMENT_KINDS = ("run", "station", "transition", "rest")
TARGET_UNITS = ("meters", "reps", "calories", "seconds")
ADVANCE_SOURCES = ("crown", "press", "button", "auto")
EVENT_KINDS = ("start", "advance", "undo", "finish", "unfinish", "end")


def _number(v: float) -> str:
    return str(int(v)) if v == round(v) else f"{v:.1f}"


# ---- definition -------------------------------------------------------------------------------

@dataclass
class SegmentTarget:
    value: float
    unit: str  # meters | reps | calories | seconds

    @property
    def text(self) -> str:
        if self.unit == "meters":
            return _number(self.value) + " m"
        if self.unit == "reps":
            return _number(self.value) + " reps"
        if self.unit == "calories":
            return _number(self.value) + " cal"
        total = int(round(self.value))
        return f"{total // 60}:{total % 60:02d}"

    def to_dict(self) -> dict:
        return {"value": self.value, "unit": self.unit}

    @classmethod
    def from_dict(cls, d: dict) -> "SegmentTarget":
        return cls(float(d["value"]), d["unit"])


@dataclass
class WorkoutSegment:
    kind: str
    movement: str
    name: str
    target: Optional[SegmentTarget] = None

    @property
    def title(self) -> str:
        if self.target is None:
            return self.name
        if self.target.unit == "reps":
            return f"{self.name} {_number(self.target.value)}"
        return f"{self.name} {self.target.text}"

    def to_dict(self) -> dict:
        d = {"kind": self.kind, "movement": self.movement, "name": self.name}
        if self.target is not None:
            d["target"] = self.target.to_dict()
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "WorkoutSegment":
        t = d.get("target")
        return cls(d["kind"], d["movement"], d["name"], SegmentTarget.from_dict(t) if t else None)


class Movement:
    run = "run"
    skiErg = "skiErg"
    sledPush = "sledPush"
    sledPull = "sledPull"
    burpeeBroadJumps = "burpeeBroadJumps"
    row = "row"
    farmersCarry = "farmersCarry"
    sandbagLunges = "sandbagLunges"
    wallBalls = "wallBalls"
    dumbbellWalkingLunges = "dumbbellWalkingLunges"
    burpees = "burpees"
    medBallBoxStepOvers = "medBallBoxStepOvers"
    devilPress = "devilPress"
    dumbbellOverShoulder = "dumbbellOverShoulder"
    airSquats = "airSquats"
    kettlebellSwings = "kettlebellSwings"
    pullUps = "pullUps"
    thrusters = "thrusters"
    lateralBurpeeOverDumbbell = "lateralBurpeeOverDumbbell"
    doubleUnders = "doubleUnders"
    dumbbellSnatch = "dumbbellSnatch"
    rest = "rest"

    NAMES = {
        "run": "Run", "skiErg": "SkiErg", "sledPush": "Sled Push", "sledPull": "Sled Pull",
        "burpeeBroadJumps": "Burpee Broad Jumps", "row": "Row", "farmersCarry": "Farmers Carry",
        "sandbagLunges": "Sandbag Lunges", "wallBalls": "Wall Balls",
        "dumbbellWalkingLunges": "DB Walking Lunges", "burpees": "Burpees",
        "medBallBoxStepOvers": "Med Ball Box Step-Overs", "devilPress": "Devil Press",
        "dumbbellOverShoulder": "DB Over-Shoulder", "airSquats": "Air Squats",
        "kettlebellSwings": "KB Swings", "pullUps": "Pull-ups", "thrusters": "Thrusters",
        "lateralBurpeeOverDumbbell": "Lateral Burpee Over DB", "doubleUnders": "Double Unders",
        "dumbbellSnatch": "Alt. DB Snatch", "rest": "Rest",
    }

    @staticmethod
    def display_name(movement_id: str) -> str:
        return Movement.NAMES.get(movement_id, movement_id)


@dataclass
class WorkoutDefinition:
    id: str
    name: str
    short_name: str
    format: str            # forTime | amrap | emom
    team: str              # solo | doubles | team
    time_cap_seconds: Optional[float]
    health_kit_activity: str
    segments: list = field(default_factory=list)
    interval_seconds: Optional[float] = None

    @property
    def run_count(self) -> int:
        return sum(1 for s in self.segments if s.kind == "run")

    @property
    def station_count(self) -> int:
        return sum(1 for s in self.segments if s.kind == "station")

    def to_dict(self) -> dict:
        d = {"id": self.id, "name": self.name, "shortName": self.short_name, "format": self.format,
             "team": self.team, "healthKitActivity": self.health_kit_activity,
             "segments": [s.to_dict() for s in self.segments]}
        if self.time_cap_seconds is not None:
            d["timeCapSeconds"] = self.time_cap_seconds
        if self.interval_seconds is not None:
            d["intervalSeconds"] = self.interval_seconds
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "WorkoutDefinition":
        cap = d.get("timeCapSeconds")
        interval = d.get("intervalSeconds")
        return cls(d["id"], d["name"], d["shortName"], d["format"], d["team"],
                   None if cap is None else float(cap), d["healthKitActivity"],
                   [WorkoutSegment.from_dict(s) for s in d["segments"]],
                   None if interval is None else float(interval))


# ---- library ----------------------------------------------------------------------------------

def _run(meters: float) -> WorkoutSegment:
    return WorkoutSegment("run", Movement.run, Movement.display_name(Movement.run),
                          SegmentTarget(meters, "meters"))


def _station(movement: str, value: float, unit: str) -> WorkoutSegment:
    return WorkoutSegment("station", movement, Movement.display_name(movement),
                          SegmentTarget(value, unit))


def _rest() -> WorkoutSegment:
    return WorkoutSegment("rest", Movement.rest, Movement.display_name(Movement.rest), None)


def _runs_and_stations(run_meters: float, stations: list) -> list:
    out = []
    for s in stations:
        out.append(_run(run_meters))
        out.append(s)
    return out


def _hyrox_stations() -> list:
    return [_station(Movement.skiErg, 1000, "meters"), _station(Movement.sledPush, 50, "meters"),
            _station(Movement.sledPull, 50, "meters"), _station(Movement.burpeeBroadJumps, 80, "meters"),
            _station(Movement.row, 1000, "meters"), _station(Movement.farmersCarry, 200, "meters"),
            _station(Movement.sandbagLunges, 100, "meters"), _station(Movement.wallBalls, 100, "reps")]


def _half_hyrox_stations() -> list:
    return [_station(Movement.skiErg, 500, "meters"), _station(Movement.sledPush, 25, "meters"),
            _station(Movement.sledPull, 25, "meters"), _station(Movement.burpeeBroadJumps, 40, "meters"),
            _station(Movement.row, 500, "meters"), _station(Movement.farmersCarry, 100, "meters"),
            _station(Movement.sandbagLunges, 50, "meters"), _station(Movement.wallBalls, 50, "reps")]


class WorkoutLibrary:
    hyroxSolo = WorkoutDefinition("hyrox.solo", "HYROX Solo", "Hyrox Solo", "forTime", "solo", None,
                                  "mixedCardio", _runs_and_stations(1000, _hyrox_stations()))
    hyroxDoubles = WorkoutDefinition("hyrox.doubles", "HYROX Doubles", "Hyrox Dbl", "forTime", "doubles",
                                     None, "mixedCardio", _runs_and_stations(1000, _hyrox_stations()))
    halfHyrox = WorkoutDefinition("hyrox.half", "Half HYROX", "Half Hyrox", "forTime", "solo", None,
                                  "mixedCardio", _runs_and_stations(500, _half_hyrox_stations()))
    partnerWod1 = WorkoutDefinition(
        "partner.wod1", "Partner WOD 1", "WOD 1", "forTime", "doubles", None, "crossTraining",
        [_run(1000), _station(Movement.wallBalls, 100, "reps"),
         _run(800), _station(Movement.dumbbellWalkingLunges, 80, "reps"),
         _run(600), _station(Movement.burpees, 60, "reps"),
         _run(400), _station(Movement.medBallBoxStepOvers, 40, "reps"),
         _run(200), _station(Movement.devilPress, 20, "reps")])
    partnerWod2 = WorkoutDefinition(
        "partner.wod2", "Partner WOD 2", "WOD 2", "forTime", "doubles", None, "crossTraining",
        [_station(Movement.skiErg, 1000, "meters"), _station(Movement.sledPush, 40, "meters"),
         _station(Movement.farmersCarry, 100, "meters"), _station(Movement.dumbbellOverShoulder, 40, "reps"),
         _station(Movement.skiErg, 1000, "meters")])
    quickTest = WorkoutDefinition(
        "quick.test", "Quick Test", "Test", "forTime", "solo", None, "crossTraining",
        [_run(200), _station(Movement.airSquats, 20, "reps"),
         _run(200), _station(Movement.burpees, 10, "reps")])
    helen = WorkoutDefinition(
        "wod.helen", "Helen", "Helen", "forTime", "solo", 16 * 60, "crossTraining",
        [_run(400), _station(Movement.kettlebellSwings, 21, "reps"),
         _station(Movement.pullUps, 12, "reps")] * 3)
    rowThrusters = WorkoutDefinition(
        "wod.rowThrusters", "Every 3:00 × 6: Row + Thrusters", "Row Thrust", "emom", "solo", 18 * 60,
        "crossTraining",
        ([_station(Movement.row, 15, "calories"), _station(Movement.thrusters, 12, "reps"), _rest()] * 6)[:-1],
        interval_seconds=180.0)
    amrap20 = WorkoutDefinition(
        "wod.nightmareAmrap", "Nightmare AMRAP 20", "AMRAP 20", "amrap", "solo", 20 * 60, "crossTraining",
        [_station(Movement.lateralBurpeeOverDumbbell, 10, "reps"), _station(Movement.doubleUnders, 31, "reps"),
         _station(Movement.dumbbellSnatch, 10, "reps"), _station(Movement.doubleUnders, 31, "reps")] * 10)
    all = [hyroxSolo, hyroxDoubles, halfHyrox, partnerWod1, partnerWod2, quickTest,
           helen, rowThrusters, amrap20]

    @staticmethod
    def definition(id: str) -> Optional[WorkoutDefinition]:
        for d in WorkoutLibrary.all:
            if d.id == id:
                return d
        return None


# ---- progress ---------------------------------------------------------------------------------

@dataclass
class WorkoutEvent:
    t: float
    kind: str
    segment_index: int
    source: Optional[str] = None

    def to_dict(self) -> dict:
        d = {"t": self.t, "kind": self.kind, "segmentIndex": self.segment_index}
        if self.source is not None:
            d["source"] = self.source
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "WorkoutEvent":
        return cls(float(d["t"]), d["kind"], int(d["segmentIndex"]), d.get("source"))


@dataclass
class SegmentSplit:
    index: int
    start: float
    end: float

    @property
    def duration(self) -> float:
        return self.end - self.start


class WorkoutProgress:
    def __init__(self, definition: WorkoutDefinition):
        self.definition = definition
        self.segment_starts: list = []
        self.finish_time: Optional[float] = None
        self.events: list = []

    @property
    def is_started(self) -> bool:
        return len(self.segment_starts) > 0

    @property
    def is_finished(self) -> bool:
        return self.finish_time is not None

    @property
    def current_index(self) -> int:
        return max(0, len(self.segment_starts) - 1)

    @property
    def current_segment(self) -> Optional[WorkoutSegment]:
        if not self.is_started:
            return None
        i = self.current_index
        return self.definition.segments[i] if i < len(self.definition.segments) else None

    @property
    def next_segment(self) -> Optional[WorkoutSegment]:
        if not self.is_started or self.is_finished:
            return None
        i = self.current_index + 1
        return self.definition.segments[i] if i < len(self.definition.segments) else None

    @property
    def start_time(self) -> Optional[float]:
        return self.segment_starts[0] if self.segment_starts else None

    def start(self, t: float) -> None:
        if self.is_started:
            return
        self.segment_starts.append(t)
        self.events.append(WorkoutEvent(t, "start", 0, None))

    def advance(self, t: float, source: str) -> bool:
        if not self.is_started or self.is_finished:
            return False
        if t < self.segment_starts[-1]:
            return False
        if self.current_index >= len(self.definition.segments) - 1:
            self.finish_time = t
            self.events.append(WorkoutEvent(t, "finish", self.current_index, source))
        else:
            self.segment_starts.append(t)
            self.events.append(WorkoutEvent(t, "advance", self.current_index, source))
        return True

    def undo(self, t: float, source: str) -> bool:
        if not self.is_started:
            return False
        if self.is_finished:
            self.finish_time = None
            self.events.append(WorkoutEvent(t, "unfinish", self.current_index, None))
            return True
        if len(self.segment_starts) < 2:
            return False
        self.segment_starts.pop()
        self.events.append(WorkoutEvent(t, "undo", self.current_index, source))
        return True

    def finish(self, t: float, source: str) -> bool:
        """Finishes now, whatever the current segment (AMRAP time cap)."""
        if not self.is_started or self.is_finished or t < self.segment_starts[-1]:
            return False
        self.finish_time = t
        self.events.append(WorkoutEvent(t, "finish", self.current_index, source))
        return True

    def auto_advance_time(self) -> Optional[float]:
        """When the current rest ends by itself: a seconds target, or the next interval boundary."""
        if not self.is_started or self.is_finished:
            return None
        seg = self.current_segment
        if seg is None or seg.kind != "rest":
            return None
        seg_start = self.segment_starts[-1]
        start = self.start_time
        if seg.target is not None and seg.target.unit == "seconds" and seg.target.value > 0:
            return seg_start + seg.target.value
        interval = self.definition.interval_seconds
        if interval is not None and interval > 0:
            nxt = math.floor((seg_start - start) / interval) + 1.0
            return start + nxt * interval
        return None

    @property
    def cap_time(self) -> Optional[float]:
        d = self.definition
        if d.format != "amrap" or d.time_cap_seconds is None or d.time_cap_seconds <= 0 or not self.is_started:
            return None
        return self.start_time + d.time_cap_seconds

    def record_end(self, t: float) -> None:
        self.events.append(WorkoutEvent(t, "end", self.current_index, None))

    def segment_elapsed(self, now: float) -> float:
        if not self.segment_starts:
            return 0.0
        end = self.finish_time if self.finish_time is not None else now
        return max(0.0, end - self.segment_starts[-1])

    def total_elapsed(self, now: float) -> float:
        if not self.segment_starts:
            return 0.0
        end = self.finish_time if self.finish_time is not None else now
        return max(0.0, end - self.segment_starts[0])

    def splits(self, now: float) -> list:
        out = []
        n = len(self.segment_starts)
        for i in range(n):
            s = self.segment_starts[i]
            if i + 1 < n:
                e = self.segment_starts[i + 1]
            else:
                e = self.finish_time if self.finish_time is not None else now
            out.append(SegmentSplit(i, s, max(e, s)))
        return out


# ---- results and stats ------------------------------------------------------------------------

@dataclass
class TimedValue:
    t: float
    value: float


@dataclass
class PedometerSample:
    t: float
    steps: float
    distance: Optional[float] = None


@dataclass
class SegmentResult:
    index: int
    kind: str
    movement: str
    title: str
    start: float
    end: float
    duration: float
    heart_rate_avg: Optional[float] = None
    heart_rate_max: Optional[float] = None
    steps: Optional[float] = None
    distance: Optional[float] = None
    cadence: Optional[float] = None
    pace_seconds_per_km: Optional[float] = None

    _KEYS = (("heartRateAvg", "heart_rate_avg"), ("heartRateMax", "heart_rate_max"), ("steps", "steps"),
             ("distance", "distance"), ("cadence", "cadence"), ("paceSecondsPerKm", "pace_seconds_per_km"))

    def to_dict(self) -> dict:
        d = {"index": self.index, "kind": self.kind, "movement": self.movement, "title": self.title,
             "start": self.start, "end": self.end, "duration": self.duration}
        for jk, pk in self._KEYS:
            v = getattr(self, pk)
            if v is not None:
                d[jk] = v
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "SegmentResult":
        kw = {pk: (None if d.get(jk) is None else float(d[jk])) for jk, pk in cls._KEYS}
        return cls(int(d["index"]), d["kind"], d["movement"], d["title"], float(d["start"]),
                   float(d["end"]), float(d["duration"]), **kw)


def _interpolate(pts: list, t: float, origin: float) -> float:
    """Linear interpolation of a cumulative series; before the first point linear from (origin, 0)."""
    t0, v0 = pts[0]
    if t <= t0:
        if t0 <= origin:
            return v0
        if t <= origin:
            return 0.0
        return v0 * (t - origin) / (t0 - origin)
    t_last, v_last = pts[-1]
    if t >= t_last:
        return v_last
    for i in range(1, len(pts)):
        ta, va = pts[i - 1]
        tb, vb = pts[i]
        if t <= tb:
            if tb == ta:
                return vb
            return va + (vb - va) * (t - ta) / (tb - ta)
    return v_last


def split_stats(progress: WorkoutProgress, now: float, heart_rates: list, pedometer: list) -> list:
    """Per-segment results (SplitStats.compute). heart_rates: [TimedValue]; pedometer: [PedometerSample]."""
    origin = progress.start_time if progress.start_time is not None else now
    ped = sorted(pedometer, key=lambda p: p.t)
    step_pts = [(p.t, p.steps) for p in ped]
    dist_pts = [(p.t, p.distance) for p in ped if p.distance is not None]
    segs = progress.definition.segments
    out = []
    for sp in progress.splits(now):
        seg = segs[sp.index] if sp.index < len(segs) else None
        kind = seg.kind if seg else "station"
        movement = seg.movement if seg else ""
        title = seg.title if seg else f"Segment {sp.index + 1}"
        hrs = [h.value for h in heart_rates if sp.start <= h.t < sp.end]
        hr_avg = sum(hrs) / len(hrs) if hrs else None
        hr_max = max(hrs) if hrs else None
        steps = None
        if step_pts:
            steps = _interpolate(step_pts, sp.end, origin) - _interpolate(step_pts, sp.start, origin)
        distance = None
        if dist_pts:
            distance = _interpolate(dist_pts, sp.end, origin) - _interpolate(dist_pts, sp.start, origin)
        duration = sp.duration
        cadence = steps / duration * 60.0 if steps is not None and duration > 0 else None
        pace = None
        if kind == "run" and distance is not None and distance > 50:
            pace = duration / (distance / 1000.0)
        out.append(SegmentResult(sp.index, kind, movement, title, sp.start, sp.end, duration,
                                 hr_avg, hr_max, steps, distance, cadence, pace))
    return out


@dataclass
class WorkoutResult:
    definition: WorkoutDefinition
    start_date: datetime
    finish_date: Optional[datetime]
    end_date: datetime
    total_seconds: float
    segments: list
    events: list
    heart_rate_avg: Optional[float] = None
    heart_rate_max: Optional[float] = None
    recording_file_name: Optional[str] = None
    id: str = field(default_factory=lambda: str(_uuid.uuid4()).upper())
    version: int = 1

    @property
    def run_seconds(self) -> float:
        return sum(s.duration for s in self.segments if s.kind == "run")

    @property
    def station_seconds(self) -> float:
        return sum(s.duration for s in self.segments if s.kind != "run")

    def to_dict(self) -> dict:
        d = {"version": self.version, "id": self.id, "definition": self.definition.to_dict(),
             "startDate": format_iso8601(self.start_date), "endDate": format_iso8601(self.end_date),
             "totalSeconds": self.total_seconds,
             "segments": [s.to_dict() for s in self.segments],
             "events": [e.to_dict() for e in self.events]}
        if self.finish_date is not None:
            d["finishDate"] = format_iso8601(self.finish_date)
        if self.heart_rate_avg is not None:
            d["heartRateAvg"] = self.heart_rate_avg
        if self.heart_rate_max is not None:
            d["heartRateMax"] = self.heart_rate_max
        if self.recording_file_name is not None:
            d["recordingFileName"] = self.recording_file_name
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "WorkoutResult":
        version = int(d.get("version", 1))
        if version != 1:
            raise ValueError(f"unsupported WorkoutResult version {version}")
        fin = d.get("finishDate")
        return cls(
            definition=WorkoutDefinition.from_dict(d["definition"]),
            start_date=parse_iso8601(d["startDate"]),
            finish_date=parse_iso8601(fin) if fin else None,
            end_date=parse_iso8601(d["endDate"]),
            total_seconds=float(d["totalSeconds"]),
            segments=[SegmentResult.from_dict(s) for s in d["segments"]],
            events=[WorkoutEvent.from_dict(e) for e in d.get("events", [])],
            heart_rate_avg=None if d.get("heartRateAvg") is None else float(d["heartRateAvg"]),
            heart_rate_max=None if d.get("heartRateMax") is None else float(d["heartRateMax"]),
            recording_file_name=d.get("recordingFileName"),
            id=d["id"], version=version)

    def save(self, path) -> None:
        with open(path, "w") as f:
            json.dump(self.to_dict(), f, indent=2, sort_keys=True)

    @classmethod
    def load(cls, path) -> "WorkoutResult":
        with open(path) as f:
            return cls.from_dict(json.load(f))


# ---- session CSV ------------------------------------------------------------------------------

@dataclass
class WorkoutCSV:
    workout_id: Optional[str]
    session_id: Optional[str]
    start_date: Optional[datetime]
    definition: Optional[WorkoutDefinition]
    boundaries: list          # [{"t","name","index","kind","source"}] for segment/undo/finish/unfinish
    heart_rates: list         # [TimedValue]
    pedometer: list           # [PedometerSample]
    marks: list
    end_time: float           # last motion sample or event time, on the CSV's clock
    progress: Optional[WorkoutProgress] = None   # replayed boundaries (None if definition unknown)


def _none_if_neg(x):
    return None if x is None or x < 0 else float(x)


def replay_boundaries(definition: WorkoutDefinition, boundaries: list) -> WorkoutProgress:
    """Replays segment/undo/finish/unfinish events through the state machine."""
    p = WorkoutProgress(definition)
    for b in boundaries:
        name, t = b["name"], b["t"]
        src = b.get("source")
        src = src if src in ADVANCE_SOURCES else "auto"
        if name == "segment":
            if not p.is_started:
                p.start(t)
            else:
                p.advance(t, src)
        elif name == "finish":
            if not p.is_started:
                p.start(t)
            p.advance(t, src)
        elif name in ("undo", "unfinish"):
            p.undo(t, src)
    return p


def load_workout_csv(path) -> WorkoutCSV:
    """Loads a workout session CSV (header 'workout=<id>'); see load_session_csv."""
    s = load_session_csv(path)
    boundaries, hrs, ped = [], [], []
    for e in s.events:
        name = e.get("name")
        t = float(e.get("t", 0.0))
        if name in ("segment", "undo", "finish", "unfinish"):
            idx = e.get("index")
            boundaries.append({"t": t, "name": name,
                               "index": int(idx) if isinstance(idx, float) else None,
                               "kind": e.get("kind"), "source": e.get("source")})
        elif name == "hr":
            if "bpm" in e and isinstance(e["bpm"], float):
                hrs.append(TimedValue(t, e["bpm"]))
        elif name == "pedometer":
            steps = e.get("steps")
            if isinstance(steps, float):
                dist = e.get("distance")
                ped.append(PedometerSample(t, steps, _none_if_neg(dist) if isinstance(dist, float) else None))
    times = [float(x) for x in s.motion.t[-1:]] + [float(e.get("t", 0.0)) for e in s.events]
    end_time = max(times) if times else 0.0
    definition = WorkoutLibrary.definition(s.workout) if s.workout else None
    if definition is None and s.workout:  # tolerate the library property name, e.g. "quickTest"
        cand = getattr(WorkoutLibrary, s.workout, None)
        definition = cand if isinstance(cand, WorkoutDefinition) else None
    progress = replay_boundaries(definition, boundaries) if definition else None
    return WorkoutCSV(s.workout, s.session_id, s.start_date, definition, boundaries, hrs, ped,
                      s.marks, end_time, progress)
