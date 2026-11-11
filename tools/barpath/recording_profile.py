"""Which workouts need the high motion rate (BarPathKit's RecordingProfile.swift).

Pure rule, no I/O. Movement ids and names are free strings, so the rule matches keywords on a
normalised form: the id / name is split into lower-case ASCII words (camelCase and every
non-alphanumeric character are boundaries) and the words are joined without separators
("bentOverRow", "Bent-over row" -> "bentoverrow"). Build 15 records every workout at the high rate
(data collection); this rule is for the later per-movement switching (W21) and is written to the
CSV header as planProfile.
"""
from typing import Optional

STANDARD = "standard"
HIGH = "high"

# Phrases removed before the keywords are searched ("air squats" must not match "squat").
EXCLUDED = ("airsquat", "bodyweightsquat", "bwsquat", "jumpsquat", "squatjump", "pistolsquat", "pistol", "pushup",
            "pressup", "wallball", "burpee", "curlup", "benchdip", "benchjump", "benchstep")

# Barbell / dumbbell / kettlebell strength and Olympic movements (substring of the joined form).
KEYWORDS = ("snatch", "clean", "jerk", "cleanandjerk", "cj", "press", "deadlift", "squat", "thruster",
            "curl", "swing", "bench", "overshoulder", "highpull", "shrug", "goodmorning", "hipthrust",
            "windmill", "turkishgetup", "bentoverrow", "barbellrow", "dumbbellrow", "kettlebellrow",
            "pendlayrow", "tbarrow", "uprightrow", "singlearmrow", "renegaderow", "gorillarow",
            "dbrow", "bbrow", "kbrow")
# Locomotion / machine movements: standard rate even with an external load (weight vest, ruck, sandbag).
# Long, simple pieces (Chad 1000X: 1,000 box step-ups with a vest, 60+ min) must stay at 100 Hz: at
# 200 Hz a session of ~85-90 min or more would exceed the 50 MB upload limit even compressed.
# A keyword still wins ("dumbbell snatch" in a ruck workout); only a named barbell turns these high.
LOCOMOTION = ("stepup", "stepover", "ruck", "carry", "lunge", "sled", "walk", "skierg", "rowerg", "bikeerg",
              "assaultbike", "echobike", "sandbag", "vest")
LOCOMOTION_WORDS = ("run", "row", "bike", "erg", "ruck", "hike")

# Short abbreviations: must be a whole word.
WORD_KEYWORDS = ("ohp", "rdl")

# Segments of these kinds are never movements we measure.
SKIPPED_KINDS = ("run", "rest", "transition")


def words(text: str) -> list:
    """Lower-case ASCII words: boundaries at non-alphanumerics (and non-ASCII) and at a
    lower-case letter followed by an upper-case one."""
    out, cur, prev = [], "", ""
    for ch in text:
        ascii_alnum = ch.isascii() and ch.isalnum()
        if not ascii_alnum:
            if cur:
                out.append(cur)
            cur = ""
        else:
            if cur and prev.isascii() and prev.islower() and ch.isupper() and ch.isalpha():
                out.append(cur)
                cur = ""
            cur += ch.lower()
        prev = ch if ascii_alnum else ""
    if cur:
        out.append(cur)
    return out


def _classify_text(text: str):
    """(has_keyword, had_excluded_phrase) for one id or name."""
    ws = words(text)
    joined = "".join(ws)
    excluded = any(w in LOCOMOTION_WORDS for w in ws) or any(p in joined for p in LOCOMOTION)
    locomotion = excluded
    for phrase in EXCLUDED:
        if phrase in joined:
            excluded = True
            joined = joined.replace(phrase, "")
    for k in KEYWORDS:
        if k in joined:
            return True, excluded
    if locomotion and "barbell" in joined:
        return True, excluded
    for w in ws:
        if w in WORD_KEYWORDS:
            return True, excluded
    return False, excluded


def segment_is_high(kind: str, movement: str, name: str, has_load: bool) -> bool:
    if kind in SKIPPED_KINDS:
        return False
    high_a, ex_a = _classify_text(movement)
    high_b, ex_b = _classify_text(name)
    if high_a or high_b:
        return True
    if ex_a or ex_b:
        return False
    return has_load


def profile_for_segments(segments) -> str:
    """HIGH when any (kind, movement, name, has_load) segment is a loaded strength / Olympic movement."""
    for kind, movement, name, has_load in segments:
        if segment_is_high(kind, movement, name, has_load):
            return HIGH
    return STANDARD


def profile_for(definition) -> str:
    return profile_for_segments((s.kind, s.movement, s.name, s.load is not None) for s in definition.segments)


# ---- Location (GPS) -----------------------------------------------------------------------
# Decided once at START for the whole session, from the planned workout only: GPS is on when the
# plan contains at least one segment of kind "run" (Free Workout and plans without a run: off).
# Independent of the rate rule above.
LOCATION_KINDS = ("run",)


def uses_location_segments(kinds) -> bool:
    """True when any segment kind (a string) is a run."""
    return any(k in LOCATION_KINDS for k in kinds)


def uses_location(definition) -> bool:
    return uses_location_segments(s.kind for s in definition.segments)
