"""PushPress week filter (tools/library/pushpress_week.py): only the class's scored workout."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("pushpress_week", Path(__file__).parents[1] / "library" / "pushpress_week.py")
pw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pw)


def part(title, score, kind="METCON", order="1"):
    return {"title": title, "scoreType": score, "workoutType": kind, "sortOrder": order, "description": "<p>x</p>"}


def test_keeps_the_class_workout_and_the_strength_piece():
    day = {"partDtos": [part("WARM UP", "NO_SCORE"), part("Announcement", "FOR_COMMENT"),
                        part("Back Squat ", "FOR_WEIGHT", "STRENGTH"), part("WORKOUT", "FOR_TIME"),
                        part("Barbara", "FOR_TIME"), part("OPTIONAL ACCESSORY", "FOR_COMPLETION"),
                        part("OPTIONAL COOL DOWN", "FOR_TIME")]}
    assert [p["title"] for p in pw.main_parts(day)] == ["Back Squat ", "WORKOUT", "Barbara"]


def test_text_strips_html():
    assert pw.text("<p>4 ROUNDS</p><p>500m Row</p>") == "4 ROUNDS\n500m Row"
