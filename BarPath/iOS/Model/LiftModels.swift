import Foundation
import BarPathKit

/// One point of a bar path, already converted for charting (cm for positions).
struct ChartPoint: Identifiable, Sendable {
    let id: Int              // index into LiftAnalysis.path
    let t: Double            // s since homing
    let forwardCm: Double
    let lateralCm: Double
    let verticalCm: Double
    let vVertical: Double    // m/s
    let speed: Double        // m/s (3-D)
}

enum MarkerKind: String, Sendable {
    case start, maxHeight, catchPoint
}

struct PathMarker: Identifiable, Sendable {
    let kind: MarkerKind
    let label: String
    let forwardCm: Double
    let verticalCm: Double
    var id: String { return kind.rawValue }
}

/// Everything the UI needs from a `LiftAnalysis`, with the path downsampled so the raw
/// recording does not have to stay in memory.
struct LiftDisplay: Sendable {
    let points: [ChartPoint]
    let markers: [PathMarker]
    let segmentBoundaryTimes: [Double]
    let segments: [LiftSegment]
    let metrics: LiftMetrics
    let confidence: Confidence
    let notes: [String]
    let maxDrift: Double         // m/s, largest ZUPT correction
    let maxSpeed: Double         // m/s
    let pathDuration: Double     // s
}

struct LiftEntry: Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    let index: Int
    let liftType: LiftType
    let loadKg: Double?
    let startDate: Date
    let endReason: EndReason?
    let fileURL: URL
    let receivedAt: Date
    let display: LiftDisplay?
    let failure: String?

    var subtitle: String {
        var parts: [String] = [liftType.displayName]
        if let load = Fmt.load(loadKg) {
            parts.append(load)
        }
        return parts.joined(separator: " · ")
    }
}

struct LiftSessionGroup: Identifiable {
    let id: UUID
    let lifts: [LiftEntry]   // ascending lift index

    var startDate: Date {
        return lifts.map { $0.startDate }.min() ?? .distantPast
    }

    var latestDate: Date {
        return lifts.map { $0.startDate }.max() ?? .distantPast
    }

    var newestLift: LiftEntry? {
        return lifts.last
    }

    var liftTypesSummary: String {
        var names: [String] = []
        for lift in lifts {
            let name = lift.liftType.displayName
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names.isEmpty ? "Session" : names.joined(separator: " · ")
    }

    var bestPeakVelocity: Double? {
        return lifts.compactMap { $0.display?.metrics.peakVerticalVelocity }.max()
    }

    var fileURLs: [URL] {
        return lifts.map { $0.fileURL }
    }
}

enum ProcessOutcome: Sendable {
    case entry(LiftEntry)
    case unreadable(URL, String)
}

/// Decoding + analysis. Pure function, run off the main thread.
enum LiftProcessor {
    static let maxChartPoints = 600

    static func process(fileURL: URL) -> ProcessOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .unreadable(fileURL, "Could not read file: \(error.localizedDescription)")
        }
        let recording: LiftRecording
        do {
            recording = try LiftRecording.decode(from: data)
        } catch {
            return .unreadable(fileURL, "Not a lift recording: \(error.localizedDescription)")
        }

        var display: LiftDisplay? = nil
        var failure: String? = nil
        do {
            let analysis = try LiftAnalyzer.analyze(recording)
            display = makeDisplay(from: analysis)
            if display == nil {
                failure = "The analyzer returned an empty path."
            }
        } catch let error as AnalysisError {
            if error == .tooShort {
                failure = "Recording too short to analyze (needs at least 0.5 s after the set position)."
            } else if error == .noHomingFound {
                failure = "Couldn't find a still set position before the pull."
            } else {
                failure = "Analysis failed: \(error)"
            }
        } catch {
            failure = "Analysis failed: \(error.localizedDescription)"
        }

        let entry = LiftEntry(id: recording.id,
                              sessionId: recording.sessionId,
                              index: recording.index,
                              liftType: recording.liftType,
                              loadKg: recording.loadKg,
                              startDate: recording.startDate,
                              endReason: recording.endReason,
                              fileURL: fileURL,
                              receivedAt: LiftFiles.modificationDate(fileURL) ?? Date(),
                              display: display,
                              failure: failure)
        return .entry(entry)
    }

    static func makeDisplay(from analysis: LiftAnalysis) -> LiftDisplay? {
        let path = analysis.path
        guard !path.isEmpty else { return nil }

        var maxSpeed = 0.0
        for p in path where p.speed > maxSpeed {
            maxSpeed = p.speed
        }

        var boundaries: [Double] = []
        for segment in analysis.segments {
            for idx in [segment.startIndex, segment.endIndex] where idx >= 0 && idx < path.count {
                let t = path[idx].t
                if !boundaries.contains(where: { abs($0 - t) < 1e-6 }) {
                    boundaries.append(t)
                }
            }
        }
        boundaries.sort()

        let maxDrift = analysis.segments.map { $0.driftCorrection }.max() ?? 0
        let duration = path[path.count - 1].t - path[0].t

        return LiftDisplay(points: downsample(path, maxPoints: maxChartPoints),
                           markers: markers(path: path, metrics: analysis.metrics),
                           segmentBoundaryTimes: boundaries,
                           segments: analysis.segments,
                           metrics: analysis.metrics,
                           confidence: analysis.confidence,
                           notes: analysis.notes,
                           maxDrift: maxDrift,
                           maxSpeed: maxSpeed,
                           pathDuration: max(duration, 0))
    }

    private static func chartPoint(_ p: PathSample, id: Int) -> ChartPoint {
        return ChartPoint(id: id,
                          t: p.t,
                          forwardCm: p.forward * 100.0,
                          lateralCm: p.lateral * 100.0,
                          verticalCm: p.vertical * 100.0,
                          vVertical: p.vVertical,
                          speed: p.speed)
    }

    static func downsample(_ path: [PathSample], maxPoints: Int) -> [ChartPoint] {
        guard !path.isEmpty else { return [] }
        let ratio = Double(path.count) / Double(max(maxPoints, 2))
        let step = max(1, Int(ratio.rounded(.up)))
        var out: [ChartPoint] = []
        out.reserveCapacity(path.count / step + 2)
        var i = 0
        while i < path.count {
            out.append(chartPoint(path[i], id: i))
            i += step
        }
        let last = path.count - 1
        if last % step != 0 {
            out.append(chartPoint(path[last], id: last))
        }
        return out
    }

    /// Start, max height and catch markers, located on the full-resolution path.
    static func markers(path: [PathSample], metrics: LiftMetrics) -> [PathMarker] {
        guard let first = path.first else { return [] }
        var out: [PathMarker] = [
            PathMarker(kind: .start, label: "Start",
                       forwardCm: first.forward * 100.0, verticalCm: first.vertical * 100.0)
        ]
        let eps = 0.0005
        // maxHeight is the highest point before the catch, so the first sample that reaches
        // it is that point (a later overhead lockout may be just as high).
        var maxIndex: Int? = path.firstIndex(where: { $0.vertical >= metrics.maxHeight - eps })
        if maxIndex == nil {
            var best = 0
            for i in 0..<path.count where path[i].vertical > path[best].vertical {
                best = i
            }
            maxIndex = best
        }
        guard let mi = maxIndex else { return out }
        let top = path[mi]
        out.append(PathMarker(kind: .maxHeight, label: "Max",
                              forwardCm: top.forward * 100.0, verticalCm: top.vertical * 100.0))
        if let catchHeight = metrics.catchHeight {
            if let ci = path[mi...].firstIndex(where: { $0.vertical <= catchHeight + eps }) {
                let c = path[ci]
                out.append(PathMarker(kind: .catchPoint, label: "Catch",
                                      forwardCm: c.forward * 100.0, verticalCm: c.vertical * 100.0))
            }
        }
        return out
    }
}
