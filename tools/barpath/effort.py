"""Effort: heart rate load of a workout and a day (docs/DESIGN_GUIDELINES.md section 5).

Effort is Edwards TRIMP: minutes in each heart rate zone × the zone number (1-5), from the start
to the finish. Zones are shares of max heart rate. Max heart rate is `effective_max_heart_rate`:
the manual value, else the larger of the age estimate and the highest sustained value recorded. Also the weight lifted, for segments with a known load and rep count.
Reference for BarPathKit's WorkoutEffort.swift (parity: Fixtures/effort_cases.json).
"""
from typing import Optional

# Lower bound of zones 1-5, as a share of max heart rate.
ZONE_FLOORS = (0.5, 0.6, 0.7, 0.8, 0.9)


def zone(bpm: float, max_heart_rate: float) -> int:
    """0 below zone 1, else 1-5."""
    if max_heart_rate <= 0:
        return 0
    share = bpm / max_heart_rate
    return sum(1 for floor in ZONE_FLOORS if share >= floor)


def series_effort(series, finish: float, max_heart_rate: float) -> Optional[float]:
    """Sum of zone × minutes of the buckets whose centre is before finish (seconds since 1970).
    None when no such bucket has a reading."""
    if series.interval <= 0:
        return None
    total = 0.0
    readings = 0
    for k, bpm in enumerate(series.bpm):
        if bpm is None or series.start + (k + 0.5) * series.interval >= finish:
            continue
        readings += 1
        total += zone(bpm, max_heart_rate) * series.interval / 60.0
    return total if readings > 0 else None


def highest_heart_rate(results: list) -> Optional[float]:
    """Highest heart rate recorded in any result, from its series or its stored max (results
    without a series have only the max). None when there is none."""
    values = [b for r in results if r.heart_rate_series is not None
              for b in r.heart_rate_series.bpm if b is not None]
    values += [r.heart_rate_max for r in results if r.heart_rate_max is not None]
    return max(values) if values else None


# Where the max heart rate in use comes from (shown in the phone's Settings).
MAX_FROM_MANUAL = "manual"
MAX_FROM_AGE = "age"
MAX_FROM_WORKOUTS = "workouts"


def sustained_heart_rate(results: list) -> Optional[float]:
    """The highest heart rate the athlete held, not a spike. A series holds a value every 5 s;
    a value counts only if the neighbouring point reaches it too, so the result is the best
    over pairs of neighbouring readings of min(a, b) (held for at least ~5 s). A lone
    optical-sensor spike counts as its higher neighbour. Results with a series use only the
    series (their `heart_rate_max` is one sample); results without one (old results) count
    their stored max. None when there is no data."""
    best = None
    for r in results:
        series = r.heart_rate_series
        if series is not None:
            values = series.bpm
            for k in range(len(values) - 1):
                a, b = values[k], values[k + 1]
                if a is None or b is None:
                    continue
                low = min(a, b)
                if best is None or low > best:
                    best = low
        elif r.heart_rate_max is not None:
            if best is None or r.heart_rate_max > best:
                best = r.heart_rate_max
    return best


def effective_max_heart_rate(results: list, birth_year: Optional[int], override: Optional[float],
                             year: int):
    """(max heart rate, source) or None when there is no override, no usable birth year and no
    heart rate data. A manual value (100-230) wins; else the larger of Tanaka 208 - 0.7 * age
    (birth year not after `year`, age at most 100) and sustained_heart_rate. Adding results can
    only raise the observed part, so the value is never lowered by new data."""
    if override is not None and 100.0 <= override <= 230.0:
        return (override, MAX_FROM_MANUAL)
    estimate = None
    if birth_year is not None and birth_year <= year and year - birth_year <= 100:
        estimate = 208.0 - 0.7 * float(year - birth_year)
    observed = sustained_heart_rate(results)
    if estimate is None and observed is None:
        return None
    if observed is not None and (estimate is None or observed > estimate):
        return (observed, MAX_FROM_WORKOUTS)
    return (estimate, MAX_FROM_AGE)


def result_effort(result, max_heart_rate: float) -> Optional[float]:
    if result.heart_rate_series is None:
        return None
    finish = (result.finish_date or result.end_date).timestamp()
    return series_effort(result.heart_rate_series, finish, max_heart_rate)


def weight_lifted_kg(result) -> float:
    """Reps × load of the stations with a known load. A workout that wasn't finished counts its
    last segment by `partial_reps`. Results can run past the definition (AMRAP): indexes wrap."""
    planned = result.definition.segments
    if not planned:
        return 0.0
    total = 0.0
    last = len(result.segments) - 1
    for i, done in enumerate(result.segments):
        segment = planned[done.index % len(planned)]
        if done.kind != "station" or segment.load is None or segment.target is None:
            continue
        if segment.target.unit != "reps":
            continue
        reps = segment.target.value
        if i == last and result.finish_date is None:
            reps = result.partial_reps or 0
        total += reps * segment.load.kilograms
    return total


def day_totals(results: list, tz, birth_year: Optional[int] = None,
               override: Optional[float] = None, year: int = 0) -> list:
    """One dict per local day, oldest first: day ("YYYY-MM-DD"), effort (None without heart rate
    data), minutes, weight_kg."""
    found = effective_max_heart_rate(results, birth_year, override, year)
    max_heart_rate = found[0] if found else None
    days = {}
    for r in results:
        key = r.start_date.astimezone(tz).strftime("%Y-%m-%d")
        d = days.setdefault(key, {"day": key, "effort": None, "minutes": 0.0, "weight_kg": 0.0})
        d["minutes"] += r.total_seconds / 60.0
        d["weight_kg"] += weight_lifted_kg(r)
        e = result_effort(r, max_heart_rate) if max_heart_rate else None
        if e is not None:
            d["effort"] = (d["effort"] or 0.0) + e
    return [days[k] for k in sorted(days)]
