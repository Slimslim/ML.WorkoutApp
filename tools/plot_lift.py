#!/usr/bin/env python3
"""Plot a lift recording (JSON, spec §2) or replay the detector over a debug session CSV (§2.1).

  python tools/plot_lift.py <recording.json|session.csv> [--out file.png] [--show]

Lift: side-view bar path (forward vs vertical, colored by speed, markers at homing / max
height / catch), vertical velocity vs time with segment boundaries, and the raw signals.
Session: detector replay over a vertical-ish signal with detected lifts shaded, plus the
watch's own events / marks from the CSV comments when present.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.collections import LineCollection  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402

from barpath.analyzer import analyze  # noqa: E402
from barpath.detector import Armed, Disarmed, LiftEnded, LiftStarted, run_detector  # noqa: E402
from barpath.geometry import G, normalize  # noqa: E402
from barpath.recording import load_recording, load_session_csv  # noqa: E402

INK = "#1f2933"
MUTED = "#7b8794"
GRID = "#e4e7eb"
BLUE = "#2563eb"
ORANGE = "#d97706"
TEAL = "#0d9488"
SPEED_CMAP = LinearSegmentedColormap.from_list("speed", ["#bfdbfe", "#1e3a8a"])


def _style(ax, title=None, xlabel=None, ylabel=None):
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(MUTED)
    ax.tick_params(colors=MUTED, labelsize=8)
    if title:
        ax.set_title(title, loc="left", fontsize=10, color=INK)
    if xlabel:
        ax.set_xlabel(xlabel, fontsize=8, color=MUTED)
    if ylabel:
        ax.set_ylabel(ylabel, fontsize=8, color=MUTED)


def plot_lift(path: Path, out: Path) -> None:
    rec = load_recording(path)
    a = analyze(rec)
    p, mt = a.path, a.metrics
    t0 = rec.motion.t[a.homingIndex]

    fig = plt.figure(figsize=(13, 8.5), constrained_layout=True)
    gs = fig.add_gridspec(3, 2, width_ratios=[1, 1.5])
    ax_path = fig.add_subplot(gs[:, 0])
    ax_v = fig.add_subplot(gs[0, 1])
    ax_acc = fig.add_subplot(gs[1, 1])
    ax_rot = fig.add_subplot(gs[2, 1], sharex=ax_acc)

    # --- side view
    x, z = p.forward * 100, p.vertical * 100
    pts = np.column_stack([x, z]).reshape(-1, 1, 2)
    lc = LineCollection(np.concatenate([pts[:-1], pts[1:]], axis=1), cmap=SPEED_CMAP, linewidth=2.2)
    lc.set_array(p.speed[:-1])
    ax_path.add_collection(lc)
    cb = fig.colorbar(lc, ax=ax_path, shrink=0.6, pad=0.01)
    cb.set_label("speed (m/s)", fontsize=8, color=MUTED)
    cb.ax.tick_params(labelsize=7, colors=MUTED)
    imax = int(np.argmin(np.abs(p.vertical - mt.maxHeight)))
    ax_path.plot(x[0], z[0], "o", ms=9, mfc="white", mec=INK, label="homing")
    ax_path.plot(x[imax], z[imax], "^", ms=9, color=ORANGE, mec="white", label=f"max {mt.maxHeight*100:.0f} cm")
    if mt.catchHeight is not None:
        ic = imax + int(np.argmin(np.abs(p.vertical[imax:] - mt.catchHeight)))
        ax_path.plot(x[ic], z[ic], "s", ms=8, color=TEAL, mec="white", label=f"catch {mt.catchHeight*100:.0f} cm")
    ax_path.plot(x[-1], z[-1], "D", ms=7, color=INK, mec="white", label=f"end {mt.finalHeight*100:.0f} cm")
    span = max(np.ptp(z), 40)
    cx = 0.5 * (x.max() + x.min())
    ax_path.set_xlim(cx - span * 0.35, cx + span * 0.35)
    ax_path.set_ylim(z.min() - 8, z.max() + 8)
    ax_path.set_aspect("equal", adjustable="box")
    ax_path.axvline(0, color=MUTED, lw=0.8, ls=":")
    _style(ax_path, f"Bar path (side view) — {rec.lift_type}", "forward (cm, + away from lifter)",
           "vertical (cm)")
    ax_path.legend(fontsize=8, frameon=False, loc="lower right")

    # --- vertical velocity
    ax_v.plot(p.t, p.vVertical, color=BLUE, lw=1.6, label="vertical velocity")
    for sg in a.segments:
        ax_v.axvline(p.t[sg.startIndex], color=MUTED, lw=0.8, ls="--")
        ax_v.axvline(p.t[sg.endIndex], color=MUTED, lw=0.8, ls="--")
    ax_v.plot(mt.timeToPeakVelocity, mt.peakVerticalVelocity, "o", color=ORANGE, ms=7)
    ax_v.annotate(f"peak {mt.peakVerticalVelocity:.2f} m/s", (mt.timeToPeakVelocity, mt.peakVerticalVelocity),
                  xytext=(8, -4), textcoords="offset points", fontsize=8, color=INK)
    ax_v.axhline(0, color=MUTED, lw=0.8)
    _style(ax_v, f"Vertical velocity (confidence {a.confidence}; dashed = ZUPT segment bounds)",
           "time since homing (s)", "m/s")

    # --- raw signals over the whole recording
    m = rec.motion
    tt = m.t - t0
    ghat = normalize(m.gravity)
    a_up = np.sum(m.user_accel * ghat, axis=1)
    ax_acc.plot(tt, np.linalg.norm(m.user_accel, axis=1), color=MUTED, lw=0.9, label="|userAccel|")
    ax_acc.plot(tt, a_up, color=BLUE, lw=1.1, label="vertical userAccel (+a·ĝ, up)")
    if len(rec.accel):
        ax_acc.plot(rec.accel.t - t0, np.linalg.norm(rec.accel.accel, axis=1) - 1, color=ORANGE, lw=0.5,
                    alpha=0.6, label="|raw 800 Hz| − 1")
    _style(ax_acc, "Acceleration", None, "g")
    ax_acc.legend(fontsize=7, frameon=False, ncol=3, loc="upper right")
    ax_rot.plot(tt, np.linalg.norm(m.rotation_rate, axis=1), color=TEAL, lw=1.0, label="|rotationRate|")
    ax_rot2_vals = ghat[:, 0]
    ax_rot.plot(tt, ax_rot2_vals * 5, color=INK, lw=0.9, ls="--", label="ĝx × 5 (forearm vertical = ±5)")
    _style(ax_rot, "Rotation rate and forearm tilt", "time since homing (s)", "rad/s")
    ax_rot.legend(fontsize=7, frameon=False, ncol=2, loc="upper right")
    for ax in (ax_acc, ax_rot):
        for (r0, r1) in a.anchorRuns:
            ax.axvspan(m.t[r0] - t0, m.t[r1] - t0, color=TEAL, alpha=0.08, lw=0)
        ax.axvline(0, color=INK, lw=0.8, ls=":")
        ax.axvline(p.t[-1], color=INK, lw=0.8, ls=":")
    notes = "; ".join(a.notes) if a.notes else "no notes"
    fig.suptitle(f"{path.name}  ·  max {mt.maxHeight:.3f} m  ·  catch "
                 f"{'-' if mt.catchHeight is None else f'{mt.catchHeight:.3f} m'}  ·  peak v "
                 f"{mt.peakVerticalVelocity:.2f} m/s  ·  back {mt.maxBackward*100:.1f} cm  ·  {notes}",
                 fontsize=10, color=INK)
    fig.savefig(out, dpi=110)
    plt.close(fig)


def plot_session(path: Path, out: Path) -> None:
    ses = load_session_csv(path)
    m = ses.motion
    events = run_detector(m)
    ghat = normalize(m.gravity)
    a_up = np.sum(m.user_accel * ghat, axis=1)

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(15, 7), sharex=True, constrained_layout=True,
                                   gridspec_kw={"height_ratios": [2, 1]})
    ax1.plot(m.t, a_up, color=BLUE, lw=0.6, label="vertical userAccel (+a·ĝ, g, up)")
    ax2.plot(m.t, np.abs(ghat[:, 0]), color=INK, lw=0.8, label="|ĝx| (forearm vertical)")
    ax2.plot(m.t, np.minimum(np.linalg.norm(m.rotation_rate, axis=1) / 10, 1.2), color=TEAL, lw=0.5,
             alpha=0.8, label="|rotationRate| / 10")
    ax2.axhline(0.7, color=MUTED, lw=0.8, ls=":")
    n_lifts = 0
    for i, t, ev in events:
        if isinstance(ev, LiftEnded):
            n_lifts += 1
            for ax in (ax1, ax2):
                ax.axvspan(ev.homingTime, ev.endTime, color=ORANGE, alpha=0.18, lw=0)
            ax1.text(ev.homingTime, 1.6, f"lift {n_lifts}: {ev.reason}",
                     fontsize=8, color=INK, va="bottom")
        elif isinstance(ev, Armed):
            ax1.plot(t, 0, "v", color=TEAL, ms=6)
        elif isinstance(ev, Disarmed):
            ax1.plot(t, 0, "x", color=MUTED, ms=6)
        elif isinstance(ev, LiftStarted):
            ax1.plot(t, 0, "^", color=ORANGE, ms=7)
    # watch-side annotations from CSV comments
    for e in ses.events:
        if "end" in e and isinstance(e.get("homing"), float):
            ax1.axvline(e["homing"], color="#7c3aed", lw=1, ls="--")
            ax1.axvline(e["end"], color="#7c3aed", lw=1, ls="--")
    for mk in ses.marks:
        ax1.axvline(mk.get("t", 0.0), color=INK, lw=1, ls="-.")
        ax1.text(mk.get("t", 0.0), -1.6, f"mark {mk.get('n', '')}", fontsize=7, color=INK)
    ax1.set_ylim(-2, 2)
    ax1.plot([], [], "v", color=TEAL, label="armed")
    ax1.plot([], [], "x", color=MUTED, label="disarmed")
    ax1.plot([], [], "^", color=ORANGE, label="lift started")
    ax1.fill_between([], [], color=ORANGE, alpha=0.18, label="detected lift (homing → end)")
    if ses.events:
        ax1.plot([], [], color="#7c3aed", ls="--", label="watch event (CSV)")
    _style(ax1, f"Detector replay — {path.name}: {n_lifts} lift(s)", None, "g")
    _style(ax2, None, "session time (s)", None)
    ax1.legend(fontsize=8, frameon=False, ncol=6, loc="upper right")
    ax2.legend(fontsize=8, frameon=False, ncol=2, loc="upper right")
    fig.savefig(out, dpi=110)
    plt.close(fig)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path)
    ap.add_argument("--out", type=Path, default=None, help="PNG path (default: next to the input)")
    args = ap.parse_args(argv)
    out = args.out or args.input.with_suffix(".png")
    if args.input.suffix.lower() == ".csv":
        plot_session(args.input, out)
    else:
        plot_lift(args.input, out)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
