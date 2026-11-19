"""Synthetic schema-1 (legacy) definitions for the upgrade() tests and parity fixtures: generic
look-alikes of the row shapes in RFC 7.3, no programme text."""
from barpath.workout import WorkoutLibrary


def seg(kind, movement, name, value=None, unit=None, load=None):
    d = {"kind": kind, "movement": movement, "name": name}
    if value is not None:
        d["target"] = {"value": value, "unit": unit}
    if load is not None:
        d["load"] = load
    return d


def rest(seconds=None):
    return seg("rest", "rest", "Rest", seconds, "seconds" if seconds else None)


def legacy(id_, fmt, segments, **kw):
    d = {"id": "legacy." + id_, "name": id_, "shortName": id_[:10], "format": fmt, "team": "solo",
         "healthKitActivity": "crossTraining", "segments": segments}
    d.update(kw)
    return d


SYNTHETIC = {
    # Tabata 20/10 as it was stored: every 0:30, squats then a 10 s rest.
    "tabataAsEmom": legacy("tabataAsEmom", "emom", [seg("station", "airSquats", "Air Squats"), rest(10)] * 8,
                           intervalSeconds=30, roundSize=2, timeCapSeconds=240),
    # 3-3-3-4 as it was stored: for time with 1:00 rests and a cap.
    "windowsAsRests": legacy("windowsAsRests", "forTime",
                             ([seg("station", "bike", "Bike", 21, "calories"),
                               seg("station", "pullUps", "Pull-ups", 15, "reps"),
                               seg("station", "pushUps", "Push-ups"), rest(60)] * 4)[:-1],
                             timeCapSeconds=960),
    "intervals": legacy("intervals", "forTime", [seg("station", "row", "Row", 250, "meters"), rest(60)] * 5,
                        roundSize=2),
    "ladderAmrap": legacy("ladderAmrap", "amrap",
                          [x for k in range(1, 5) for x in (seg("station", "thrusters", "Thrusters", 3 * k, "reps"),
                                                             seg("station", "pullUps", "Pull-ups", 3 * k, "reps"))],
                          roundSize=2, timeCapSeconds=600),
    "alternatingEmom": legacy("alternatingEmom", "emom",
                              [seg("station", "kettlebellSwings", "KB Swings", 15, "reps"), rest(),
                               seg("station", "burpees", "Burpees", 10, "reps"), rest()] * 3,
                              intervalSeconds=60, roundSize=2, timeCapSeconds=360),
    "emomNoRounds": legacy("emomNoRounds", "emom", [seg("station", "burpees", "Burpees", 10, "reps")] * 3,
                           intervalSeconds=60),
    "amrapNoCap": legacy("amrapNoCap", "amrap", [seg("station", "burpees", "Burpees", 10, "reps")]),
    "unknownFormat": legacy("unknownFormat", "chipper", [seg("station", "burpees", "Burpees", 10, "reps")]),
    "loadsAndHold": legacy("loadsAndHold", "forTime",
                           [seg("station", "thrusters", "Thrusters", 21, "reps", {"value": 42.5, "unit": "kg", "count": 1}),
                            seg("station", "plank", "Plank", 60, "seconds")], roundSize=2),
    "partialAmrap": legacy("partialAmrap", "amrap",
                           [seg("station", "a", "A", 5, "reps"), seg("station", "b", "B", 5, "reps"),
                            seg("station", "a", "A", 5, "reps")], roundSize=2, timeCapSeconds=300),
}

ALL = dict({d.id: d.to_dict() for d in WorkoutLibrary.known}, **SYNTHETIC)

_B = seg("station", "burpees", "Burpees", 10, "reps")
_HELENISH = legacy("v2Authored", "forTime", [_B, rest(60)], roundSize=2)

# Rows upgrade() must survive without an exception, with the label and reasons it gives
# (JSON-safe only: the same rows go to Swift; Infinity / NaN are tested in Python alone).
EDGE = {
    "draft": (dict(legacy("draft", "forTime", [_B]), schemaVersion=0), "notLegacy", ["draft"]),
    # An authored v2 row whose old keys are a lossy compile: its structure is kept as written.
    "v2Authored": (dict(_HELENISH, schemaVersion=2, structure={
        "score": {"type": "time"},
        "body": [{"repeat": {"id": "r", "times": 3, "body": [{"part": {"id": "b", "movement": "burpees",
                                                                       "target": {"value": 10, "unit": "reps"}}}]}}]}),
        "notLegacy", ["alreadyV2"]),
    "schemaText": (dict(legacy("schemaText", "forTime", [_B]), schemaVersion="1"), "notLegacy",
                   ["unknownSchemaVersion"]),
    "schemaOne": (dict(legacy("schemaOne", "forTime", [_B]), schemaVersion=1), "exact", []),
    "notAnObject": ([1, 2], "reencode", ["noSegments", "notRunnable"]),
    "segmentsNotAList": (dict(legacy("segmentsNotAList", "forTime", []), segments=5), "reencode",
                         ["noSegments", "notRunnable"]),
    "restNotANumber": (legacy("restNotANumber", "forTime", [_B, seg("rest", "rest", "Rest", "x", "seconds")]),
                       "reencode", ["invalidField"]),
    "restNull": (legacy("restNull", "forTime", [_B, {"kind": "rest", "movement": "rest", "name": "Rest",
                                                     "target": {"value": None, "unit": "seconds"}}]),
                 "reencode", ["invalidField"]),
    "restRounded": (legacy("restRounded", "forTime", [_B, rest(90.5)]), "review", ["restSecondsRounded"]),
    "extraKeys": (legacy("extraKeys", "forTime", [dict(_B, note="scale to 7", **{"x-tempo": "2-0-1"})]),
                  "exact", ["note:segmentKeysNotCopied"]),
    "hugeEmom": (legacy("hugeEmom", "emom", [_B, _B], roundSize=1, intervalSeconds=5e18, timeCapSeconds=60),
                 "reencode", ["movesToEngine", "capNotWindows", "notRunnable"]),
    "targetText": (legacy("targetText", "forTime", [seg("station", "burpees", "Burpees", "ten", "reps")]),
                   "reencode", ["invalidField"]),
    "targetNoUnit": (legacy("targetNoUnit", "forTime", [dict(_B, target={"value": 10})]), "reencode",
                     ["invalidField"]),
    "loadText": (legacy("loadText", "forTime", [dict(_B, load={"value": "heavy"})]), "reencode", ["invalidField"]),
    "noKind": (legacy("noKind", "forTime", [{"movement": "burpees", "name": "B", "target": {"value": 1, "unit": "reps"}}]),
               "reencode", ["invalidField"]),
    "capTooLarge": (legacy("capTooLarge", "forTime", [_B], timeCapSeconds=1e12), "reencode", ["notRunnable"]),
    "capZero": (legacy("capZero", "forTime", [_B], timeCapSeconds=0), "reencode", ["invalidField"]),
    # Round 2: below 1 or not whole (0.5 would truncate to a zero round size / interval).
    "roundSizeHalf": (legacy("roundSizeHalf", "forTime", [_B, _B], roundSize=0.5), "reencode", ["invalidField"]),
    "intervalHalf": (legacy("intervalHalf", "emom", [_B, _B], roundSize=1, intervalSeconds=0.5),
                     "reencode", ["invalidField", "movesToEngine", "emomWithoutRounds"]),
    "capFraction": (legacy("capFraction", "forTime", [_B], timeCapSeconds=600.5), "reencode", ["invalidField"]),
    "restHalf": (legacy("restHalf", "forTime", [_B, rest(0.5)]), "reencode", ["invalidField"]),
    "noMovement": (legacy("noMovement", "forTime", [{"kind": "station", "name": "B",
                                                     "target": {"value": 10, "unit": "reps"}}]),
                   "reencode", ["invalidField"]),
    "unitNotKnown": (legacy("unitNotKnown", "forTime", [seg("station", "row", "Row", 3, "furlongs")]),
                     "reencode", ["invalidField"]),
    "negativeTarget": (legacy("negativeTarget", "forTime", [seg("station", "burpees", "B", -3, "reps")]),
                       "reencode", ["invalidField"]),
    "loadUnitNotKnown": (legacy("loadUnitNotKnown", "forTime", [dict(_B, load={"value": 3, "unit": "st"})]),
                         "reencode", ["invalidField"]),
    "loadCountZero": (legacy("loadCountZero", "forTime", [dict(_B, load={"value": 20, "unit": "kg", "count": 0})]),
                      "reencode", ["invalidField"]),
    "restWithReps": (legacy("restWithReps", "forTime", [_B, seg("rest", "rest", "Rest", 30, "reps")]),
                     "review", ["restTargetDropped"]),
    "boolVsOne": (legacy("boolVsOne", "forTime", [dict(_B, target={"value": True, "unit": "reps"}), _B], roundSize=1),
                  "reencode", ["invalidField"]),
}
