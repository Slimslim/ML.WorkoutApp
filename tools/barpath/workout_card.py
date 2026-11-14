"""Workout card text: reference for BarPathKit's WorkoutCard.swift.

Turns a WorkoutDefinition into the lines of the workout card (docs/concepts/HEADER_STUDY.md,
"Writing conventions" and "Final card spec"; mockups in docs/concepts/workout-cards.html):

    top-left meta (set by the app) ............ block tag · type tag (top-right)
    name (or the format as the name)
    time-domain line   "40 min AMRAP · rest 1 min between rounds", "Every 1:00 × 8", "3 rounds"
    rep-scheme line    "40-30-20-30-40 Cal", "8 × (1000 m Run + station)"
    movement lines     "qty unit movement @load", one round only
    cap line           "20 min cap" (for-time caps only)

The Swift port must give the same output on the same definitions: the parity fixture
(BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/workout_cards.expected.json) is written by
`python3 -m barpath.workout_card` from tools/ and checked by both test suites.
"""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from .workout import distance_text
from .workout import Movement, WorkoutDefinition, WorkoutLibrary, WorkoutSegment, _number

# Fixed vocabulary of the type tag (HEADER_STUDY.md decision 3). Only some are produced from
# today's definitions; the others are there for definitions that say so later.
TYPE_TAGS = {
    "amrap": "AMRAP", "amrep": "AMREP", "emom": "EMOM", "rft": "RFT", "chipper": "Chipper",
    "sets": "Sets × reps", "deathBy": "Death by", "ladder": "Ladder", "complex": "Complex",
    "forQuality": "For quality", "cycles": "Cycles",
}
BLOCK_TAGS = {"metcon": "Metcon", "strength": "Strength", "accessory": "Accessory"}

FREE_WORKOUT_ID = "free.workout"
FREE_LINE = "Turn the Crown at each change"
# Full card: more than this many movement lines → the first (limit − 1) and "+N more".
LINE_LIMIT = 5

# Short names (singular, plural) per writing conventions rules 5, 6 and 8: Title Case, plural
# when the quantity is more than 1, DB / KB / C&J / DU / ALT abbreviations.
SHORT_NAMES = {
    "run": ("Run", "Run"),
    "skiErg": ("SkiErg", "SkiErg"),
    "sledPush": ("Sled Push", "Sled Push"),
    "sledPull": ("Sled Pull", "Sled Pull"),
    "burpeeBroadJumps": ("Burpee Broad Jump", "Burpee Broad Jumps"),
    "row": ("Row", "Row"),
    "farmersCarry": ("Farmers Carry", "Farmers Carry"),
    "sandbagLunges": ("Sandbag Lunge", "Sandbag Lunges"),
    "wallBalls": ("Wall Ball", "Wall Balls"),
    "dumbbellWalkingLunges": ("DB Walking Lunge", "DB Walking Lunges"),
    "burpees": ("Burpee", "Burpees"),
    "medBallBoxStepOvers": ("Med Ball Box Step-over", "Med Ball Box Step-overs"),
    "devilPress": ("Devil Press", "Devil Press"),
    "dumbbellOverShoulder": ("DB Over-Shoulder", "DB Over-Shoulder"),
    "airSquats": ("Air Squat", "Air Squats"),
    "kettlebellSwings": ("KB Swing", "KB Swings"),
    "pullUps": ("Pull-up", "Pull-ups"),
    "thrusters": ("Thruster", "Thrusters"),
    "lateralBurpeeOverDumbbell": ("Lateral Burpee Over DB", "Lateral Burpees Over DB"),
    "doubleUnders": ("DU", "DU"),
    "dumbbellSnatch": ("ALT DB Snatch", "ALT DB Snatches"),
    "pushUps": ("Push-up", "Push-ups"),
    "powerCleans": ("Power Clean", "Power Cleans"),
    "powerCleanAndJerk": ("Power C&J", "Power C&J"),
}

STRENGTH_ACTIVITIES = ("functionalStrengthTraining", "traditionalStrengthTraining")
# A name that only restates the format ("AMRAP 40 with 1:00 rest", "Every 1:00 × 8: Power C&J").
_GENERIC_START = re.compile(r"^(amrap|amrep|emom|e\d+mom|every |for time)", re.IGNORECASE)


def short_name(movement_id: str, plural: bool) -> Optional[str]:
    """Movement.shortName in Swift: card name of a known movement, None when unknown."""
    names = SHORT_NAMES.get(movement_id)
    if names is None:
        return None
    return names[1] if plural else names[0]


def _whole_seconds(seconds: float) -> int:
    """Swift's Int(x.rounded()): halves away from zero (Python's round() goes to even)."""
    return int(math.floor(abs(seconds) + 0.5)) * (1 if seconds >= 0 else -1)


def clock(seconds: float) -> str:
    total = _whole_seconds(seconds)
    return f"{total // 60}:{total % 60:02d}"


def duration_text(seconds: float) -> str:
    """'40 min', '1 min', '30 s', '1:30'."""
    total = _whole_seconds(seconds)
    if total >= 60 and total % 60 == 0:
        return f"{total // 60} min"
    if total < 60:
        return f"{total} s"
    return clock(total)


def load_text(seg: WorkoutSegment) -> Optional[str]:
    """'155 lb', '2 × 40 lb' (without the '@')."""
    if seg.load is None:
        return None
    v = _number(seg.load.value) + " " + seg.load.unit
    return f"{seg.load.count} × {v}" if seg.load.count > 1 else v


@dataclass
class CardLine:
    text: str                    # "7 Power Cleans"
    load: Optional[str] = None   # "155 lb" (shown as "@155 lb")

    @property
    def full(self) -> str:
        return self.text if self.load is None else self.text + " @" + self.load

    def to_dict(self) -> dict:
        return {"text": self.text, "load": self.load}


@dataclass
class WorkoutCard:
    name: str
    name_is_format: bool
    type_tag: Optional[str]          # key of TYPE_TAGS
    block_tag: Optional[str]         # key of BLOCK_TAGS
    time_domain_line: Optional[str]
    rep_scheme_line: Optional[str]
    lines: list = field(default_factory=list)   # CardLine
    cap_line: Optional[str] = None
    summary_line: str = ""
    # Rep-scheme line goes in front of these lines in the one-line summary (Freedom: "Row").
    scheme_line_indices: list = field(default_factory=list)

    @property
    def type_label(self) -> Optional[str]:
        return None if self.type_tag is None else TYPE_TAGS[self.type_tag]

    @property
    def block_label(self) -> Optional[str]:
        return None if self.block_tag is None else BLOCK_TAGS[self.block_tag]

    def visible_lines(self, limit: int = LINE_LIMIT) -> tuple:
        """(lines to show, hidden count): more than `limit` → the first limit − 1 and '+N more'."""
        if len(self.lines) <= limit:
            return list(self.lines), 0
        keep = max(limit - 1, 1)
        return list(self.lines[:keep]), len(self.lines) - keep

    def to_dict(self) -> dict:
        shown, hidden = self.visible_lines()
        return {
            "name": self.name, "nameIsFormat": self.name_is_format,
            "typeTag": self.type_label, "blockTag": self.block_label,
            "timeDomainLine": self.time_domain_line, "repSchemeLine": self.rep_scheme_line,
            "lines": [ln.to_dict() for ln in self.lines], "capLine": self.cap_line,
            "summaryLine": self.summary_line, "visibleLineCount": len(shown), "hiddenLineCount": hidden,
        }

    # ---- building -------------------------------------------------------------------------

    @classmethod
    def make(cls, d: WorkoutDefinition) -> "WorkoutCard":
        if d.id == FREE_WORKOUT_ID:
            return cls(d.name, False, None, None, None, None, [CardLine(FREE_LINE)], None, FREE_LINE)

        shape = _Shape.detect(d)
        type_tag = _type_tag(d, shape)
        block_tag = "strength" if d.health_kit_activity in STRENGTH_ACTIVITIES else "metcon"
        time_domain = _time_domain_line(d, shape, type_tag)
        cap_line = None
        if d.format == "forTime" and d.time_cap_seconds is not None and d.time_cap_seconds > 0:
            cap_line = duration_text(d.time_cap_seconds) + " cap"
        name, is_format = _card_name(d.name, time_domain)

        lines = shape.lines
        if shape.scheme_line is not None and lines and len(shape.scheme_indices) == len(lines):
            summary = shape.scheme_line + " " + " · ".join(ln.full for ln in lines)
        elif shape.scheme_line is not None and shape.scheme_indices:
            parts = []
            for i, ln in enumerate(lines):
                parts.append(shape.scheme_line + " " + ln.full if i in shape.scheme_indices else ln.full)
            summary = " · ".join(parts)
        else:
            parts = ([shape.scheme_line] if shape.scheme_line else []) + [ln.full for ln in lines]
            summary = " · ".join(parts)
        return cls(name, is_format, type_tag, block_tag, time_domain, shape.scheme_line, lines, cap_line,
                   summary, list(shape.scheme_indices))


# ---- shape of the segment list -------------------------------------------------------------------

def _same(a: WorkoutSegment, b: WorkoutSegment) -> bool:
    return a.kind == b.kind and a.movement == b.movement and a.name == b.name and a.target == b.target \
        and a.load == b.load


def _same_but_value(a: WorkoutSegment, b: WorkoutSegment) -> bool:
    if a.target is None or b.target is None:
        return False
    return a.kind == b.kind and a.movement == b.movement and a.name == b.name and a.load == b.load \
        and a.target.unit == b.target.unit


def _movement_name(seg: WorkoutSegment, plural: bool) -> str:
    """Short name of a known movement under its default name; otherwise the name as written
    (class workouts with a choice, 'Row / Bike', keep theirs)."""
    names = SHORT_NAMES.get(seg.movement)
    if names is not None:
        if seg.name in (Movement.display_name(seg.movement), names[0], names[1]):
            return names[1] if plural else names[0]
    return seg.name


def movement_line(seg: WorkoutSegment, with_quantity: bool = True) -> CardLine:
    """'21 KB Swings', '12 Cal Row', '400 m Run', '1:00 Suitcase Hold', '7 Power Cleans' @ '155 lb'."""
    load = load_text(seg)
    t = seg.target
    if t is None:
        return CardLine(_movement_name(seg, False), load)
    if not with_quantity:
        return CardLine(_movement_name(seg, False), load)
    if t.unit == "reps":
        text = _number(t.value) + " " + _movement_name(seg, t.value != 1)
    elif t.unit == "calories":
        text = _number(t.value) + " Cal " + _movement_name(seg, False)
    elif t.unit == "meters":
        text = distance_text(t.value) + " " + _movement_name(seg, True)
    else:
        text = clock(t.value) + " " + _movement_name(seg, False)
    return CardLine(text, load)


def _unit_suffix(unit: str) -> str:
    if unit == "calories":
        return " Cal"
    if unit == "meters":
        return " m"
    if unit == "seconds":
        return " s"
    return ""


class _Shape:
    """One round of the workout as card lines, plus how the rounds repeat."""

    def __init__(self):
        self.kind = "flat"          # identical | scheme | runStations | flat
        self.rounds = 0             # identical / scheme / runStations: number of rounds
        self.lines = []             # CardLine
        self.scheme_line = None
        self.scheme_indices = []    # indices into lines that the scheme applies to
        self.round_rest = None      # seconds of a timed rest inside the round

    @classmethod
    def detect(cls, d: WorkoutDefinition) -> "_Shape":
        segs = d.segments
        n = len(segs)
        r = d.round_size
        s = cls()
        if r is not None and 1 <= r < n:
            # Identical rounds (the last may be cut short).
            if all(_same(segs[i], segs[i % r]) for i in range(r, n)):
                s.kind = "identical"
                s.rounds = (n + r - 1) // r
                s._set_round(segs[:r])
                return s
            if n % r == 0 and s._try_scheme(segs, r):
                return s
        if s._try_run_stations(segs):
            return s
        s.kind = "flat"
        s.lines = [movement_line(x) for x in segs if x.kind != "rest"]
        return s

    def _set_round(self, round_segs: list) -> None:
        for x in round_segs:
            if x.kind == "rest":
                if x.target is not None and x.target.unit == "seconds" and x.target.value > 0:
                    self.round_rest = x.target.value
                continue
            self.lines.append(movement_line(x))

    def _try_scheme(self, segs: list, r: int) -> bool:
        """Rounds where some positions change only their target value, all in the same sequence
        (40-30-20-30-40 Cal), and the others stay fixed (7 Power Cleans)."""
        rounds = len(segs) // r
        if rounds < 2:
            return False
        varying = []
        for p in range(r):
            column = [segs[k * r + p] for k in range(rounds)]
            if all(_same(c, column[0]) for c in column):
                continue
            if column[0].kind == "rest" or not all(_same_but_value(c, column[0]) for c in column):
                return False
            varying.append(p)
        if not varying:
            return False
        first = [segs[k * r + varying[0]].target for k in range(rounds)]
        for p in varying[1:]:
            col = [segs[k * r + p].target for k in range(rounds)]
            if [t.value for t in col] != [t.value for t in first] or col[0].unit != first[0].unit:
                return False
        self.kind = "scheme"
        self.rounds = rounds
        # Calories move to the movement line: "40-30-20-30-40" then "Cal Row".
        cal = first[0].unit == "calories"
        self.scheme_line = "-".join(_number(t.value) for t in first) + ("" if cal else _unit_suffix(first[0].unit))
        for p in range(r):
            x = segs[p]
            if x.kind == "rest":
                if x.target is not None and x.target.unit == "seconds" and x.target.value > 0:
                    self.round_rest = x.target.value
                continue
            if p in varying:
                self.scheme_indices.append(len(self.lines))
                line = movement_line(x, with_quantity=False)
                self.lines.append(CardLine("Cal " + line.text, line.load) if cal else line)
            else:
                self.lines.append(movement_line(x))
        return True

    def _try_run_stations(self, segs: list) -> bool:
        """HYROX-like: the same run before each station → '8 × (1000 m Run + station)' and the
        stations, one per line."""
        n = len(segs)
        if n < 4 or n % 2 != 0:
            return False
        run = segs[0]
        if run.kind != "run" or run.target is None:
            return False
        for i in range(0, n, 2):
            if not _same(segs[i], run) or segs[i + 1].kind != "station":
                return False
        count = n // 2
        self.kind = "runStations"
        self.rounds = count
        self.scheme_line = f"{count} × ({movement_line(run).full} + station)"
        self.lines = [movement_line(segs[i]) for i in range(1, n, 2)]
        return True


def _type_tag(d: WorkoutDefinition, shape: _Shape) -> Optional[str]:
    if d.format == "amrap":
        return "amrap"
    if d.format == "emom":
        return "emom"
    if shape.kind in ("identical", "scheme") and shape.rounds >= 2:
        return "rft"
    return "chipper"


def _rest_suffix(shape: _Shape) -> str:
    if shape.round_rest is None:
        return ""
    return " · rest " + duration_text(shape.round_rest) + " between rounds"


def _time_domain_line(d: WorkoutDefinition, shape: _Shape, type_tag: Optional[str]) -> Optional[str]:
    if type_tag == "amrap":
        cap = d.time_cap_seconds
        head = "AMRAP"
        if cap is not None and cap > 0:
            whole = _whole_seconds(cap) % 60 == 0
            head = (duration_text(cap) if whole else clock(cap)) + " AMRAP"
        return head + _rest_suffix(shape)
    if type_tag == "emom":
        sets = _emom_sets(d)
        if d.interval_seconds is not None and d.interval_seconds > 0:
            return f"Every {clock(d.interval_seconds)} × {sets}"
        return f"EMOM × {sets}"
    if type_tag == "rft":
        return f"{shape.rounds} rounds" + _rest_suffix(shape)
    return None


def _emom_sets(d: WorkoutDefinition) -> int:
    r = d.round_size
    n = len(d.segments)
    if r is not None and r >= 1:
        return (n + r - 1) // r
    return sum(1 for s in d.segments if s.kind != "rest")


def _card_name(name: str, time_domain: Optional[str]) -> tuple:
    """(name, is the format). 'Every 1:00 × 8: Power C&J' → 'Power C&J'; 'AMRAP 40 with 1:00 rest'
    → 'AMRAP 40'; no name → the time-domain line (rule 11)."""
    text = name.strip()
    if _GENERIC_START.match(text):
        if ": " in text:
            rest = text.split(": ", 1)[1].strip()
            if rest:
                return rest, False
        cut = text.lower().find(" with ")
        if cut > 0:
            text = text[:cut].strip()
        return text, True
    if not text:
        return (time_domain or "For time"), True
    return text, False


# ---- parity fixture ------------------------------------------------------------------------------

REPO = Path(__file__).resolve().parents[2]
FIXTURE = REPO / "BarPath" / "BarPathKit" / "Tests" / "BarPathKitTests" / "Fixtures" / "workout_cards.expected.json"
SEED = REPO / "tools" / "library" / "seed"


def fixture_definitions() -> list:
    """Every built-in (known) definition, then the library seed workouts."""
    out = list(WorkoutLibrary.known)
    for f in sorted(SEED.glob("*.json")):
        out.append(WorkoutDefinition.from_dict(json.loads(f.read_text())["definition"]))
    return out


def fixture_payload() -> dict:
    return {"cards": [{"definition": d.to_dict(), "card": WorkoutCard.make(d).to_dict()}
                      for d in fixture_definitions()]}


def fixture_text() -> str:
    return json.dumps(fixture_payload(), ensure_ascii=False, indent=1) + "\n"


def render_text(card: WorkoutCard, meta: str = "") -> str:
    """Plain-text rendering of the full card (for reviews and the PR description)."""
    tags = " ".join(t for t in (card.block_label, f"[{card.type_label}]" if card.type_label else None) if t)
    out = [f"{meta:<28}{tags}".rstrip(), card.name]
    if card.time_domain_line:
        out.append(card.time_domain_line)
    if card.rep_scheme_line:
        out.append(card.rep_scheme_line)
    shown, hidden = card.visible_lines()
    out += ["  " + ln.full for ln in shown]
    if hidden:
        out.append(f"  +{hidden} more")
    if card.cap_line:
        out.append(card.cap_line)
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    if "--print" in sys.argv:
        for d in fixture_definitions():
            print(render_text(WorkoutCard.make(d), d.id))
            print()
    else:
        FIXTURE.write_text(fixture_text())
        print("wrote", FIXTURE)
