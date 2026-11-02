import SwiftUI
import BarPathKit

// Race progress border for the workout main page (layout "D+ · Big name + race progress
// border", docs/concepts/watch-layouts.html). Read clockwise from 12 o'clock: one equal slice
// per segment (AMRAP: time toward the cap, one slit every 5 minutes), done slices muted, the
// current slice bright and filling, the empty track grey. The Crown arc draws on the same
// line, on top of it, while the Crown is being turned.

// MARK: - Colours

/// The workout screen colours, in one place.
///
/// Semantics (docs/concepts/WATCH_SCREEN_REVIEW.md): yellow = segment time only, red = HR
/// only, blue = run, pink = Roxzone, volt = progress/Crown. Stations get a small per-movement
/// palette so two different stations in a row never share a colour (Helen: KB Swings, then
/// Pull-ups): each distinct station movement takes the next colour, in order of first
/// appearance in the workout, from `stations`.
///
/// NOTE (2026-10-31): first version of the station palette; the colour scheme will be
/// revisited after testing on the wrist. With more than 4 distinct station movements the
/// palette wraps (HYROX: SkiErg and Row are both orange, but runs always separate them).
enum SegmentPalette {
    /// #4D8EFF, runs.
    static let run: Color = SegmentPalette.rgb(0x4D8EFF)
    /// Station colours in assignment order: orange #FF7A1A, purple #B48CFF, green #4CD964,
    /// amber #FFB340. Chosen away from red (HR #FF5B4F), yellow (segment time #FFD60A),
    /// pink (Roxzone #FF2E88), teal (rates #3FD1BE) and volt (#B8FF3C).
    static let stations: [Color] = [
        SegmentPalette.rgb(0xFF7A1A),
        SegmentPalette.rgb(0xB48CFF),
        SegmentPalette.rgb(0x4CD964),
        SegmentPalette.rgb(0xFFB340)
    ]
    /// Rest (and transition) segments: neutral light grey #C7CBD1.
    static let rest: Color = SegmentPalette.rgb(0xC7CBD1)
    /// Segment time (the big timer) and the AMRAP time-to-cap border: #FFD60A.
    static let elapsed: Color = SegmentPalette.rgb(0xFFD60A)
    /// Heart rate: #FF5B4F.
    static let heartRate: Color = SegmentPalette.rgb(0xFF5B4F)
    /// Crown arc turning forward (advance): volt #B8FF3C.
    static let crownForward: Color = SegmentPalette.rgb(0xB8FF3C)
    /// Crown arc turning backward (undo): orange #FF7A1A.
    static let crownBackward: Color = SegmentPalette.rgb(0xFF7A1A)
    /// Empty border track: #2E3238.
    static let track: Color = SegmentPalette.rgb(0x2E3238)
    /// Dark text on a coloured fill (the Exit soon banner): #0C0D0F.
    static let ink: Color = SegmentPalette.rgb(0x0C0D0F)

    static func rgb(_ hex: UInt32) -> Color {
        let r: Double = Double((hex >> 16) & 0xFF) / 255.0
        let g: Double = Double((hex >> 8) & 0xFF) / 255.0
        let b: Double = Double(hex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// One colour per segment of the definition (same order as `definition.segments`).
    static func segmentColors(for definition: WorkoutDefinition) -> [Color] {
        var movementOrder: [String] = []
        var colors: [Color] = []
        for segment in definition.segments {
            switch segment.kind {
            case .run:
                colors.append(SegmentPalette.run)
            case .rest, .transition:
                colors.append(SegmentPalette.rest)
            case .station:
                var index: Int = 0
                if let found = movementOrder.firstIndex(of: segment.movement) {
                    index = found
                } else {
                    movementOrder.append(segment.movement)
                    index = movementOrder.count - 1
                }
                colors.append(SegmentPalette.stations[index % SegmentPalette.stations.count])
            }
        }
        return colors
    }

    /// Colour of the segment at `index` (white when out of range).
    static func color(forSegmentAt index: Int, in definition: WorkoutDefinition) -> Color {
        let colors: [Color] = SegmentPalette.segmentColors(for: definition)
        guard index >= 0, index < colors.count else { return Color.white }
        return colors[index]
    }
}

// MARK: - Shape

/// Rounded rectangle following the screen edge, starting at TOP CENTRE and running clockwise
/// (so `.trim(from:to:)` fractions read clockwise from 12 o'clock). Built from tangent arcs:
/// no clockwise/anticlockwise flag to get wrong in the flipped coordinate space.
struct RaceBorderShape: Shape {
    /// Distance from the screen edge to the centre of the line (pt). With the 4 pt border
    /// the line covers 2…6 pt from the edge.
    static let borderInset: CGFloat = 4
    /// Screen corner radius as a share of the screen width (45 mm ≈ 198 pt → ≈ 44 pt).
    /// Approximate: tune on the device if the corners look off.
    static let screenCornerRatio: CGFloat = 0.22

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = RaceBorderShape.borderInset
        let r: CGRect = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        guard r.width > 0, r.height > 0 else { return path }
        let maxRadius: CGFloat = min(r.width, r.height) / 2
        let radius: CGFloat = max(0, min(maxRadius, rect.width * RaceBorderShape.screenCornerRatio - inset))

        let topRight = CGPoint(x: r.maxX, y: r.minY)
        let bottomRight = CGPoint(x: r.maxX, y: r.maxY)
        let bottomLeft = CGPoint(x: r.minX, y: r.maxY)
        let topLeft = CGPoint(x: r.minX, y: r.minY)
        let topCentre = CGPoint(x: r.midX, y: r.minY)

        path.move(to: topCentre)
        path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: radius)
        path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: radius)
        path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: radius)
        path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: radius)
        path.addLine(to: topCentre)
        return path
    }
}

// MARK: - Border model

/// One slice of the border, as fractions (0…1) of the path, clockwise from 12 o'clock.
struct RaceBorderSlice {
    let start: Double
    let end: Double
    let color: Color
}

/// What the border shows: contiguous slices covering 0…1, the slice we are in and how far
/// into it (0…1). Slices before `currentIndex` are done.
struct RaceBorderState {
    let slices: [RaceBorderSlice]
    let currentIndex: Int
    let currentFraction: Double

    static let empty = RaceBorderState(slices: [], currentIndex: 0, currentFraction: 0)

    /// Equal slices, one per segment, each in its segment colour.
    static func segments(colors: [Color], currentIndex: Int, currentFraction: Double) -> RaceBorderState {
        let n: Int = colors.count
        guard n > 0 else { return RaceBorderState.empty }
        var slices: [RaceBorderSlice] = []
        for i in 0..<n {
            slices.append(RaceBorderSlice(start: Double(i) / Double(n),
                                          end: Double(i + 1) / Double(n),
                                          color: colors[i]))
        }
        return RaceBorderState(slices: slices,
                               currentIndex: min(max(0, currentIndex), n - 1),
                               currentFraction: min(1, max(0, currentFraction)))
    }

    /// AMRAP: the whole border is time toward the cap, a slit every `tick` seconds.
    static func timeToCap(elapsed: Double, cap: Double, tick: Double, color: Color) -> RaceBorderState {
        guard cap > 0, tick > 0 else { return RaceBorderState.empty }
        var slices: [RaceBorderSlice] = []
        var s: Double = 0
        while s < cap - 0.5 {
            // A remainder under 0.5 s joins the last slice, so the slices always reach 1.
            let e: Double = cap - (s + tick) < 0.5 ? cap : s + tick
            slices.append(RaceBorderSlice(start: s / cap, end: e / cap, color: color))
            s = e
        }
        guard !slices.isEmpty else { return RaceBorderState.empty }
        let t: Double = min(cap, max(0, elapsed))
        var index: Int = 0
        for (i, slice) in slices.enumerated() where t >= slice.start * cap {
            index = i
        }
        let slice: RaceBorderSlice = slices[index]
        let length: Double = (slice.end - slice.start) * cap
        let fraction: Double = length > 0 ? (t - slice.start * cap) / length : 0
        return RaceBorderState(slices: slices, currentIndex: index,
                               currentFraction: min(1, max(0, fraction)))
    }
}

// MARK: - Views

/// The race progress border. Full screen: give it `.ignoresSafeArea()`.
struct RaceBorderView: View {
    let state: RaceBorderState
    /// Wrist down: 3 pt, dimmer, steady.
    let isAlwaysOn: Bool

    /// Slit between slices, as a fraction of the path (from the design: 0.7 % above 10
    /// slices, else 1.1 %).
    private var gap: Double {
        let n: Int = state.slices.count
        if n <= 1 { return 0 }
        return n > 10 ? 0.007 : 0.011
    }

    var body: some View {
        ZStack {
            ForEach(0..<state.slices.count, id: \.self) { (i: Int) in
                sliceView(i)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sliceView(_ i: Int) -> RaceBorderSliceView {
        let slice: RaceBorderSlice = state.slices[i]
        let a: Double = slice.start + gap / 2
        let b: Double = max(a, slice.end - gap / 2)
        var fillTo: Double? = nil
        var fillOpacity: Double = 1
        if i < state.currentIndex {
            fillTo = b
            fillOpacity = isAlwaysOn ? 0.5 : 0.55
        } else if i == state.currentIndex {
            fillTo = a + (b - a) * state.currentFraction
            fillOpacity = isAlwaysOn ? 0.85 : 1.0
        }
        return RaceBorderSliceView(start: a,
                                   end: b,
                                   fillTo: fillTo,
                                   color: slice.color,
                                   fillOpacity: fillOpacity,
                                   trackOpacity: isAlwaysOn ? 0.55 : 1.0,
                                   lineWidth: isAlwaysOn ? 3 : 4)
    }
}

/// One slice: grey track, coloured fill from its start to `fillTo`.
struct RaceBorderSliceView: View {
    let start: Double
    let end: Double
    let fillTo: Double?
    let color: Color
    let fillOpacity: Double
    let trackOpacity: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            if end > start {
                RaceBorderShape()
                    .trim(from: CGFloat(start), to: CGFloat(end))
                    .stroke(SegmentPalette.track.opacity(trackOpacity),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            if let to = fillTo, to > start {
                RaceBorderShape()
                    .trim(from: CGFloat(start), to: CGFloat(min(to, end)))
                    .stroke(color.opacity(fillOpacity),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
    }
}

/// Crown-turn arc: on the border line, on top of it (no dimming, no inset). Clockwise from
/// 12 o'clock in volt to advance, anticlockwise in orange to undo. Disappears when the
/// gesture resets (~1 s after the Crown stops). Full screen: give it `.ignoresSafeArea()`.
struct CrownArcView: View {
    let fraction: Double
    let isBackward: Bool

    var body: some View {
        RaceBorderShape()
            .trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
            .stroke(isBackward ? SegmentPalette.crownBackward : SegmentPalette.crownForward,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
            // Mirrored about the vertical centre line: still starts at 12 o'clock, runs
            // anticlockwise.
            .scaleEffect(x: isBackward ? -1 : 1, y: 1)
            .opacity(fraction > 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
