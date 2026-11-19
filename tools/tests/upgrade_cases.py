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
