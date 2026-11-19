"""Legacy (schema 1) definitions to v2 (RFC 7.3) and the engine's CSV lines (RFC 9)."""
import copy
import math
import random

import pytest

from barpath import workout_csv as wc
from barpath import workout_engine as we
from barpath import workout_structure as ws
from barpath.recording import MOTION_KEYS, load_session_csv
from barpath.workout_upgrade import upgrade
from engine_cases import ALL as ENGINE_CASES
from upgrade_cases import ALL, EDGE, SYNTHETIC

EXPECTED = {
    "hyrox.solo": "exact", "hyrox.doubles": "exact", "hyrox.half": "exact", "partner.wod1": "exact",
    "partner.wod2": "exact", "wod.helen": "exact", "quick.test": "exact", "intervals": "exact",
    "wod.amrap40": "review", "wod.nightmareAmrap": "review", "wod.rowThrusters": "review",
    "free.workout": "review", "ladderAmrap": "review", "alternatingEmom": "review", "loadsAndHold": "review",
    "partialAmrap": "review",
    "tabataAsEmom": "reencode", "windowsAsRests": "reencode", "emomNoRounds": "reencode",
    "amrapNoCap": "reencode", "unknownFormat": "reencode",
}


@pytest.mark.parametrize("name", sorted(ALL))
def test_every_row_upgrades_to_a_valid_plan_with_the_expected_label(name):
    old = ALL[name]
    u = upgrade(old)
    assert u["label"] == EXPECTED[name], u["reasons"]
    doc = u["definition"]
    assert ws.validate(doc) == []
    assert we.plan(doc).steps
    for k, v in old.items():                      # every old key is kept unchanged
        assert doc[k] == v
    assert old == ALL[name]                       # the input is not changed


def test_reasons_name_what_needs_the_owner():
    assert "restInsideInterval" in upgrade(SYNTHETIC["tabataAsEmom"])["reasons"]
    assert "windowsStoredAsRests" in upgrade(SYNTHETIC["windowsAsRests"])["reasons"]
    assert upgrade(SYNTHETIC["ladderAmrap"])["reasons"] == ["listedRounds", "listedRoundsVary"]
    assert upgrade(ALL["hyrox.doubles"])["reasons"] == ["note:partnerSplitAssumed"]


def test_hyrox_upgrades_to_the_rfc_structure_and_runs_identically():
    doc = upgrade(ALL["hyrox.solo"])["definition"]
    rp = doc["structure"]["body"][0]["repeat"]
    assert rp["times"] == 8 and [list(n)[0] for n in rp["body"]] == ["part", "part"]
    assert len(rp["vary"]["p2"]) == 8 and "p1" not in rp["vary"]
    c = ws.compile_definition(doc)
    assert c["segments"] == ALL["hyrox.solo"]["segments"] and c["roundSize"] == 2


def test_listed_amrap_keeps_its_list_and_runs_past_it():
    doc = upgrade(ALL["wod.nightmareAmrap"])["definition"]
    rp = doc["structure"]["body"][0]["timed"]["body"][0]["repeat"]
    assert rp["times"] is None and rp["listRounds"] == 10
    st, _ = we.run(we.plan(doc), [{"kind": "start", "t": 0}] +
                   [{"kind": "crown", "t": 4500 * k} for k in range(1, 50)])
    assert any(f.get("extra") for f in we.facts(st))


def test_upgrade_is_idempotent_on_its_own_output_shape():
    u1 = upgrade(ALL["wod.helen"])
    u2 = upgrade({k: v for k, v in u1["definition"].items() if k not in ("schemaVersion", "structure")})
    assert u1 == u2


@pytest.mark.parametrize("name", sorted(EDGE))
def test_odd_rows_give_a_label_never_an_exception(name):
    old, label, reasons = EDGE[name]
    before = copy.deepcopy(old)
    u = upgrade(old)
    assert (u["label"], u["reasons"]) == (label, reasons)
    assert old == before
    if label == "notLegacy":                      # drafts and v2 rows come back unchanged
        assert u["definition"] == old
    if label == "exact":
        assert ws.validate(u["definition"]) == []


def test_v2_row_keeps_its_authored_structure():
    old = EDGE["v2Authored"][0]
    assert upgrade(old)["definition"]["structure"] == old["structure"]


@pytest.mark.parametrize("bad", [math.inf, -math.inf, math.nan])
def test_infinity_and_nan_are_invalid_not_a_crash(bad):
    b = {"kind": "station", "movement": "burpees", "name": "B", "target": {"value": 10, "unit": "reps"}}
    rows = [
        {"format": "forTime", "segments": [b], "timeCapSeconds": bad},
        {"format": "forTime", "segments": [b, b], "roundSize": bad},
        {"format": "emom", "segments": [b], "intervalSeconds": bad, "roundSize": 1},
        {"format": "forTime", "segments": [b, {"kind": "rest", "target": {"value": bad, "unit": "seconds"}}]},
        {"format": "forTime", "segments": [dict(b, target={"value": bad, "unit": "reps"}), b], "roundSize": 1},
        {"format": "forTime", "segments": [dict(b, load={"value": bad, "unit": "kg"})]},
    ]
    for row in rows:
        u = upgrade(row)
        assert u["label"] == "reencode" and "invalidField" in u["reasons"], row
    assert upgrade({"schemaVersion": bad, "segments": [b]})["label"] == "notLegacy"


def test_mutated_rows_never_raise_and_exact_always_validates():
    """Round 2: one or two random field changes to every row; Swift's port follows the same rules."""
    rng = random.Random(7)
    values = [None, 0, 0.5, 1, 1.5, 10, 90.5, 600.5, -3, "x", "", True, math.inf, math.nan, 1e12, 5e18,
              [], {}, "furlongs", "kg", "lb", "reps", "seconds", "forTime", "amrap", "emom", "doubles"]
    paths = [("kind",), ("movement",), ("name",), ("target",), ("target", "value"), ("target", "unit"),
             ("load",), ("load", "value"), ("load", "unit"), ("load", "count"), ("x-note",)]
    names = sorted(ALL)
    labels = set()
    for _ in range(4000):
        row = copy.deepcopy(ALL[rng.choice(names)])
        for _ in range(rng.randint(1, 2)):
            if rng.random() < 0.3 or not row.get("segments"):
                row[rng.choice(["timeCapSeconds", "roundSize", "intervalSeconds", "team", "format"])] = rng.choice(values)
                continue
            node = rng.choice(row["segments"])
            path = rng.choice(paths)
            for k in path[:-1]:
                if not isinstance(node.get(k), dict):
                    node[k] = {}
                node = node[k]
            if rng.random() < 0.15:
                node.pop(path[-1], None)
            else:
                node[path[-1]] = rng.choice(values)
        u = upgrade(row)
        labels.add(u["label"])
        if u["label"] == "exact":
            assert ws.validate(u["definition"]) == [], row
    assert labels == {"exact", "review", "reencode"}


# ---- CSV lines --------------------------------------------------------------------------------

def _run(name, crowns, until, tick=1000, extra=()):
    p = we.plan(ws.compile_definition(ENGINE_CASES[name]))
    evs = [{"kind": "start", "t": 0}] + [{"kind": "tick", "t": t} for t in range(tick, until + 1, tick)]
    evs += [{"kind": "crown", "t": c} for c in crowns] + list(extra)
    evs.sort(key=lambda e: (e["t"], {"start": 0, "tick": 1}.get(e["kind"], 2)))
    return p, we.run(p, evs)[0]


def test_plan_lines_hold_the_hash_and_every_bell():
    p, _ = _run("tabata", [], 0)
    lines = wc.plan_lines(p, 1795000000123, 98765)
    assert lines[0] == ("name=plan schema=2 planner=1 hash=%s startEpochMs=1795000000123 startUptimeMs=98765 "
                        "steps=16 bells=16" % p.hash)
    assert lines[1] == "name=bell id=rp.1.work.end anchor=start offsetMs=20000"
    assert len(lines) == 17


def test_event_lines_and_the_loader_round_trip(tmp_path):
    p, st = _run("windows3334", [70000, 140000, 141000], 300000,
                 extra=[{"kind": "reps", "t": 300000, "step": "rp.1.bench", "value": 12}])
    lines = wc.event_lines(st)
    assert lines[0] == (70000, "name=step step=rp.1.bike status=done endedBy=athlete seq=1")
    assert (180000, "name=step step=rp.1.bench status=done endedBy=clock seq=4 reps=12") in lines
    assert any("name=input action=ignored input=crown reason=lockout" in l for _, l in lines)
    # Written to a CSV out of time order (#50), read back in order by (t, seq).
    rows = [(0, "name=segment index=0 kind=station source=start")] + \
        [(0, l) for l in wc.plan_lines(p, 1, 2)] + lines
    random.Random(1).shuffle(rows)
    path = tmp_path / "s.csv"
    body = "# barpath-session workout=test\n" + "".join("# event t=%.3f %s\n" % (t / 1000, l) for t, l in rows)
    path.write_text(body + ",".join(MOTION_KEYS) + "\n" + ",".join(["0"] * len(MOTION_KEYS)) + "\n")
    tl = wc.timeline(load_session_csv(str(path), workout_hz=None).events)
    assert tl["source"] == "plan" and tl["plan"]["hash"] == p.hash
    assert [x["step"] for x in tl["items"]] == [l.split("step=")[1].split()[0] for _, l in lines
                                               if l.startswith("name=step")]
    assert [x["seq"] for x in tl["items"]] == sorted(x["seq"] for x in tl["items"])


def test_without_a_plan_line_the_loader_reads_segments():
    events = [{"t": 5.0, "name": "segment", "index": 1.0, "kind": "run", "source": "crown"},
              {"t": 0.0, "name": "segment", "index": 0.0, "kind": "run", "source": "start"}]
    tl = wc.timeline(events)
    assert tl["source"] == "segments" and [x["index"] for x in tl["items"]] == [0, 1]


@pytest.mark.parametrize("value", ["Épaulé 1", "007", "1.50", "inf", "-x", "NaN", "Infinity", "nb\u00a0sp",
                                   "ls\u2028x", "vt\x0bx", "fs\x1cx", "a,b=c%d", "😀"])
def test_free_text_ids_survive_the_loader(tmp_path, value):
    line = "name=step step=%s status=done endedBy=clock seq=1" % wc.enc(value)
    path = tmp_path / "s.csv"
    path.write_text("# barpath-session workout=test\n# event t=0.000 name=plan schema=2 hash=ab\n"
                    "# event t=1.000 %s\n" % line + ",".join(MOTION_KEYS) + "\n"
                    + ",".join(["0"] * len(MOTION_KEYS)) + "\n", encoding="utf-8")
    tl = wc.timeline(load_session_csv(str(path), workout_hz=None).events)
    assert [x["step"] for x in tl["items"]] == [value]


def test_text_from_an_older_writer_never_raises():
    assert wc._text(float("inf")) == "inf" and wc._text(float("nan")) == "nan" and wc._text(7.0) == "7"


def test_reps_text():
    assert [wc._reps_text(v) for v in (12, 12.0, 12.5, -3, True, "a b")] == ["12", "12", "12.5", "-3", "true", "a%20b"]


def test_values_are_percent_encoded():
    assert wc.enc("a b,c%d") == "a%20b%2Cc%25d"
    assert wc.dec(wc.enc("a b,c%d\n")) == "a b,c%d\n"
    assert wc._text(12.0) == "12"
