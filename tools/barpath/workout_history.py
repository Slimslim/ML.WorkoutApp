"""Which saved results belong to a workout: reference for BarPathKit's WorkoutHistory.swift.

The same workout can reach the phone under more than one id: a built-in on a branch that was never
merged ("wod.freedom") and the library row of the same day ("lib.pitfire.20261102.freedom"). Two
definitions are the same workout when their ids are equal, or when their names match once
normalized AND their segments have the same kinds and movements in the same order. Targets and
loads are left out on purpose: a load typed differently (85 kg vs 155 lb) is still the workout.
"""
from __future__ import annotations

import unicodedata
from typing import Optional

from .workout import WorkoutDefinition, WorkoutResult


def normalized_name(name: str) -> str:
    """Lowercased, accents and width folded, every run of characters that are not letters or digits
    turned into one space, trimmed: 'Every 1:00 × 8: Power C&J' -> 'every 1 00 8 power c j'."""
    folded = unicodedata.normalize("NFKD", name)
    folded = "".join(ch for ch in folded if not unicodedata.combining(ch)).lower()
    words = []
    current = ""
    for ch in folded:
        if ch.isalnum():
            current += ch
        elif current:
            words.append(current)
            current = ""
    if current:
        words.append(current)
    return " ".join(words)


def movement_sequence(d: WorkoutDefinition) -> list:
    """'station:row', 'rest:rest', one per segment, in order."""
    return [f"{s.kind}:{s.movement}" for s in d.segments]


def same_movements(a: WorkoutDefinition, b: WorkoutDefinition) -> bool:
    """Same segment kinds and movements in the same order, whatever the names. For workouts of
    the same day: a program can rename the workout the watch ran."""
    return bool(a.segments) and movement_sequence(a) == movement_sequence(b)


def is_same_workout(a: WorkoutDefinition, b: WorkoutDefinition) -> bool:
    """Same id, or same normalized (non-empty) name and the same segment kinds and movements."""
    if a.id == b.id:
        return True
    if len(a.segments) != len(b.segments):  # cheap check first
        return False
    name_a = normalized_name(a.name)
    if not name_a or name_a != normalized_name(b.name):
        return False
    return movement_sequence(a) == movement_sequence(b)


def results_of(definition: WorkoutDefinition, results: list) -> list:
    """Results of this workout, newest start first."""
    out = [r for r in results if is_same_workout(definition, r.definition)]
    return sorted(out, key=lambda r: r.start_date, reverse=True)


def latest_of(definition: WorkoutDefinition, results: list) -> Optional[WorkoutResult]:
    found = results_of(definition, results)
    return found[0] if found else None
