import Foundation

/// The text of the workout card (docs/concepts/HEADER_STUDY.md, "Writing conventions" and
/// "Final card spec"; mockups in docs/concepts/workout-cards.html). Pure, no UI:
///
///     block tag · type tag (top-right; the app adds date · program top-left)
///     name, or the format as the name
///     time-domain line   "40 min AMRAP · rest 1 min between rounds", "Every 1:00 × 8", "3 rounds"
///     rep-scheme line    "40-30-20-30-40 Cal", "8 × (1000 m Run + station)"
///     movement lines     "qty unit movement @load", one round only
///     cap line           "20 min cap" (for-time caps only)
///
/// Port of tools/barpath/workout_card.py; parity fixture Fixtures/workout_cards.expected.json.
public struct WorkoutCard: Equatable {

    /// Workout type tag, from a fixed vocabulary (HEADER_STUDY.md decision 3). Today's
    /// definitions produce AMRAP, EMOM, RFT and Chipper; the others are for definitions that
    /// say so later.
    public enum TypeTag: String, Equatable, CaseIterable {
        case amrap, amrep, emom, rft, chipper, sets, deathBy, ladder, complex, forQuality, cycles

        public var label: String {
            switch self {
            case .amrap: return "AMRAP"
            case .amrep: return "AMREP"
            case .emom: return "EMOM"
            case .rft: return "RFT"
            case .chipper: return "Chipper"
            case .sets: return "Sets × reps"
            case .deathBy: return "Death by"
            case .ladder: return "Ladder"
            case .complex: return "Complex"
            case .forQuality: return "For quality"
            case .cycles: return "Cycles"
            }
        }
    }

    public enum BlockTag: String, Equatable, CaseIterable {
        case metcon, strength, accessory

        public var label: String {
            switch self {
            case .metcon: return "Metcon"
            case .strength: return "Strength"
            case .accessory: return "Accessory"
            }
        }
    }

    /// One movement line: `text` "7 Power Cleans", `load` "155 lb" (shown as "@155 lb").
    public struct Line: Equatable {
        public let text: String
        public let load: String?

        public init(text: String, load: String?) {
            self.text = text
            self.load = load
        }

        /// "7 Power Cleans @155 lb".
        public var full: String {
            guard let l = load else { return text }
            return text + " @" + l
        }
    }

    public let name: String
    /// The name is the format ("AMRAP 40", or the time-domain line when the workout has none).
    public let nameIsFormat: Bool
    public let typeTag: TypeTag?
    public let blockTag: BlockTag?
    public let timeDomainLine: String?
    public let repSchemeLine: String?
    /// One round (or the whole list for chippers), rests left out.
    public let lines: [Line]
    public let capLine: String?
    /// One line for compact rows: "40-30-20-30-40 Cal Row · 7 Power Cleans @155 lb".
    public let summaryLine: String

    public static let freeWorkoutId: String = "free.workout"
    public static let freeLine: String = "Turn the Crown at each change"
    /// Full card: more than this many movement lines → the first (limit − 1) and "+N more".
    public static let lineLimit: Int = 5

    public init(name: String, nameIsFormat: Bool, typeTag: TypeTag?, blockTag: BlockTag?,
                timeDomainLine: String?, repSchemeLine: String?, lines: [Line], capLine: String?,
                summaryLine: String) {
        self.name = name
        self.nameIsFormat = nameIsFormat
        self.typeTag = typeTag
        self.blockTag = blockTag
        self.timeDomainLine = timeDomainLine
        self.repSchemeLine = repSchemeLine
        self.lines = lines
        self.capLine = capLine
        self.summaryLine = summaryLine
    }

    /// Lines to show and how many are hidden ("+N more").
    public func visibleLines(limit: Int = WorkoutCard.lineLimit) -> (lines: [Line], hidden: Int) {
        if lines.count <= limit {
            return (lines, 0)
        }
        let keep: Int = Swift.max(limit - 1, 1)
        return (Array(lines.prefix(keep)), lines.count - keep)
    }

    /// One segment written like a card line, quantity first: "2 Power C&J", "15 Cal Row",
    /// "400 m Run", "21 KB Swings" @ "24 kg", "Rest" (the preview's "All segments" list).
    public static func segmentLine(_ segment: WorkoutSegment) -> Line {
        return CardText.line(segment)
    }

    // MARK: - Building

    public static func make(definition d: WorkoutDefinition) -> WorkoutCard {
        if d.id == freeWorkoutId {
            return WorkoutCard(name: "Free Workout", nameIsFormat: false, typeTag: nil, blockTag: nil,
                               timeDomainLine: nil, repSchemeLine: nil,
                               lines: [Line(text: freeLine, load: nil)], capLine: nil,
                               summaryLine: freeLine)
        }
        let shape: CardShape = CardShape.detect(d)
        let tag: TypeTag = makeTypeTag(d, shape)
        let strength: Bool = d.healthKitActivity == "functionalStrengthTraining"
            || d.healthKitActivity == "traditionalStrengthTraining"
        let block: BlockTag = strength ? .strength : .metcon
        let timeDomain: String? = makeTimeDomainLine(d, shape, tag)
        var cap: String? = nil
        if d.format == .forTime, let c = d.timeCapSeconds, c > 0 {
            cap = CardText.duration(c) + " cap"
        }
        let named: (name: String, isFormat: Bool) = cardName(d.name, timeDomain: timeDomain)

        let lines: [Line] = shape.lines
        let summary: String
        if let scheme = shape.schemeLine, !lines.isEmpty, shape.schemeIndices.count == lines.count {
            summary = scheme + " " + lines.map { (l: Line) -> String in l.full }.joined(separator: " · ")
        } else if let scheme = shape.schemeLine, !shape.schemeIndices.isEmpty {
            var parts: [String] = []
            for (i, l) in lines.enumerated() {
                parts.append(shape.schemeIndices.contains(i) ? scheme + " " + l.full : l.full)
            }
            summary = parts.joined(separator: " · ")
        } else {
            var parts: [String] = []
            if let scheme = shape.schemeLine { parts.append(scheme) }
            for l in lines { parts.append(l.full) }
            summary = parts.joined(separator: " · ")
        }
        return WorkoutCard(name: named.name, nameIsFormat: named.isFormat, typeTag: tag,
                           blockTag: block, timeDomainLine: timeDomain, repSchemeLine: shape.schemeLine,
                           lines: lines, capLine: cap, summaryLine: summary)
    }

    private static func makeTypeTag(_ d: WorkoutDefinition, _ shape: CardShape) -> TypeTag {
        switch d.format {
        case .amrap:
            return .amrap
        case .emom:
            return .emom
        case .forTime:
            if (shape.kind == .identical || shape.kind == .scheme) && shape.rounds >= 2 {
                return .rft
            }
            return .chipper
        }
    }

    private static func restSuffix(_ shape: CardShape) -> String {
        guard let rest = shape.roundRest else { return "" }
        return " · rest " + CardText.duration(rest) + " between rounds"
    }

    private static func makeTimeDomainLine(_ d: WorkoutDefinition, _ shape: CardShape,
                                           _ tag: TypeTag) -> String? {
        switch tag {
        case .amrap:
            var head: String = "AMRAP"
            if let cap = d.timeCapSeconds, cap > 0 {
                let whole: Bool = Int(cap.rounded()) % 60 == 0
                head = (whole ? CardText.duration(cap) : CardText.clock(cap)) + " AMRAP"
            }
            return head + restSuffix(shape)
        case .emom:
            let sets: Int = emomSets(d)
            if let interval = d.intervalSeconds, interval > 0 {
                return "Every " + CardText.clock(interval) + " × " + String(sets)
            }
            return "EMOM × " + String(sets)
        case .rft:
            return String(shape.rounds) + " rounds" + restSuffix(shape)
        default:
            return nil
        }
    }

    private static func emomSets(_ d: WorkoutDefinition) -> Int {
        let n: Int = d.segments.count
        if let r = d.roundSize, r >= 1 {
            return (n + r - 1) / r
        }
        return d.segments.filter { (s: WorkoutSegment) -> Bool in s.kind != .rest }.count
    }

    /// "Every 1:00 × 8: Power C&J" → "Power C&J"; "AMRAP 40 with 1:00 rest" → "AMRAP 40" (the
    /// format is the name); no name → the time-domain line (writing conventions rule 11).
    static func cardName(_ name: String, timeDomain: String?) -> (name: String, isFormat: Bool) {
        var text: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGenericName(text) {
            if let r = text.range(of: ": ") {
                let rest: String = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    return (rest, false)
                }
            }
            if let w = text.range(of: " with ", options: .caseInsensitive), w.lowerBound > text.startIndex {
                text = String(text[..<w.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (text, true)
        }
        if text.isEmpty {
            return (timeDomain ?? "For time", true)
        }
        return (text, false)
    }

    /// Starts like a format: "AMRAP…", "AMREP…", "EMOM…", "E3MOM…", "Every …", "For time…".
    static func isGenericName(_ text: String) -> Bool {
        let lower: String = text.lowercased()
        let prefixes: [String] = ["amrap", "amrep", "emom", "every ", "for time"]
        for p in prefixes where lower.hasPrefix(p) {
            return true
        }
        // E2MOM, E3MOM, E10MOM…
        let chars: [Character] = Array(lower)
        if chars.count >= 4 && chars[0] == "e" {
            var i: Int = 1
            while i < chars.count && chars[i].isASCII && chars[i].isNumber {
                i += 1
            }
            if i > 1 && i + 3 <= chars.count && String(chars[i..<(i + 3)]) == "mom" {
                return true
            }
        }
        return false
    }
}

// MARK: - Text helpers

enum CardText {
    /// Number without a trailing ".0" (same as SegmentTarget's).
    static func number(_ v: Double) -> String {
        if v == v.rounded() {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }

    /// "1:00", "3:00", "7:30".
    static func clock(_ seconds: Double) -> String {
        let total: Int = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "40 min", "1 min", "30 s", "1:30".
    static func duration(_ seconds: Double) -> String {
        let total: Int = Int(seconds.rounded())
        if total >= 60 && total % 60 == 0 {
            return String(total / 60) + " min"
        }
        if total < 60 {
            return String(total) + " s"
        }
        return clock(seconds)
    }

    /// "155 lb", "2 × 40 lb" (without the "@").
    static func load(_ segment: WorkoutSegment) -> String? {
        guard let l = segment.load else { return nil }
        let v: String = number(l.value) + " " + l.unit.rawValue
        return l.count > 1 ? String(l.count) + " × " + v : v
    }

    static func unitSuffix(_ unit: TargetUnit) -> String {
        switch unit {
        case .calories: return " Cal"
        case .meters: return " m"
        case .seconds: return " s"
        case .reps: return ""
        }
    }

    /// Short name of a known movement under its default name; otherwise the name as written
    /// (class workouts with a choice, "Row / Bike", keep theirs).
    static func movementName(_ s: WorkoutSegment, plural: Bool) -> String {
        if let singular = Movement.shortName(s.movement, plural: false),
           let pluralName = Movement.shortName(s.movement, plural: true) {
            if s.name == Movement.displayName(s.movement) || s.name == singular || s.name == pluralName {
                return plural ? pluralName : singular
            }
        }
        return s.name
    }

    /// "21 KB Swings", "12 Cal Row", "400 m Run", "1:00 Suitcase Hold", "7 Power Cleans" @ "155 lb".
    /// Without the quantity (under a shared rep scheme): the singular name.
    static func line(_ s: WorkoutSegment, withQuantity: Bool = true) -> WorkoutCard.Line {
        let l: String? = load(s)
        guard let t = s.target, withQuantity else {
            return WorkoutCard.Line(text: movementName(s, plural: false), load: l)
        }
        let text: String
        switch t.unit {
        case .reps:
            text = number(t.value) + " " + movementName(s, plural: t.value != 1)
        case .calories:
            text = number(t.value) + " Cal " + movementName(s, plural: false)
        case .meters:
            text = SegmentTarget.distance(t.value) + " " + movementName(s, plural: true)
        case .seconds:
            text = clock(t.value) + " " + movementName(s, plural: false)
        }
        return WorkoutCard.Line(text: text, load: l)
    }
}

// MARK: - Shape of the segment list

/// One round of the workout as card lines, plus how the rounds repeat.
struct CardShape {
    enum Kind { case identical, scheme, runStations, flat }

    var kind: Kind = .flat
    var rounds: Int = 0
    var lines: [WorkoutCard.Line] = []
    var schemeLine: String? = nil
    /// Indices into `lines` that the rep scheme applies to.
    var schemeIndices: [Int] = []
    /// Seconds of a timed rest inside the round.
    var roundRest: Double? = nil

    static func detect(_ d: WorkoutDefinition) -> CardShape {
        let segs: [WorkoutSegment] = d.segments
        let n: Int = segs.count
        var s = CardShape()
        if let r = d.roundSize, r >= 1, r < n {
            var identical: Bool = true
            for i in r..<n where !same(segs[i], segs[i % r]) {
                identical = false
                break
            }
            if identical {
                s.kind = .identical
                s.rounds = (n + r - 1) / r
                s.setRound(Array(segs.prefix(r)))
                return s
            }
            if n % r == 0 && s.trySchemeRounds(segs, r) {
                return s
            }
        }
        if s.tryRunStations(segs) {
            return s
        }
        s.kind = .flat
        s.lines = segs.filter { (x: WorkoutSegment) -> Bool in x.kind != .rest }
            .map { (x: WorkoutSegment) -> WorkoutCard.Line in CardText.line(x) }
        return s
    }

    static func same(_ a: WorkoutSegment, _ b: WorkoutSegment) -> Bool {
        return a.kind == b.kind && a.movement == b.movement && a.name == b.name
            && a.target == b.target && a.load == b.load
    }

    static func sameButValue(_ a: WorkoutSegment, _ b: WorkoutSegment) -> Bool {
        guard let ta = a.target, let tb = b.target else { return false }
        return a.kind == b.kind && a.movement == b.movement && a.name == b.name && a.load == b.load
            && ta.unit == tb.unit
    }

    private static func timedRest(_ x: WorkoutSegment) -> Double? {
        guard let t = x.target, t.unit == .seconds, t.value > 0 else { return nil }
        return t.value
    }

    private mutating func setRound(_ round: [WorkoutSegment]) {
        for x in round {
            if x.kind == .rest {
                if let rest = CardShape.timedRest(x) { roundRest = rest }
                continue
            }
            lines.append(CardText.line(x))
        }
    }

    /// Rounds where some positions change only their target value, all in the same sequence
    /// (40-30-20-30-40 Cal), and the others stay fixed (7 Power Cleans).
    private mutating func trySchemeRounds(_ segs: [WorkoutSegment], _ r: Int) -> Bool {
        let count: Int = segs.count / r
        if count < 2 { return false }
        var varying: [Int] = []
        for p in 0..<r {
            let first: WorkoutSegment = segs[p]
            var allSame: Bool = true
            for k in 1..<count where !CardShape.same(segs[k * r + p], first) {
                allSame = false
                break
            }
            if allSame { continue }
            if first.kind == .rest { return false }
            for k in 1..<count where !CardShape.sameButValue(segs[k * r + p], first) {
                return false
            }
            varying.append(p)
        }
        guard let p0 = varying.first, let unit = segs[p0].target?.unit else { return false }
        var values: [Double] = []
        for k in 0..<count {
            values.append(segs[k * r + p0].target?.value ?? 0)
        }
        for p in varying.dropFirst() {
            if segs[p].target?.unit != unit { return false }
            for k in 0..<count where segs[k * r + p].target?.value != values[k] {
                return false
            }
        }
        kind = .scheme
        rounds = count
        schemeLine = values.map { (v: Double) -> String in CardText.number(v) }.joined(separator: "-")
            + CardText.unitSuffix(unit)
        for p in 0..<r {
            let x: WorkoutSegment = segs[p]
            if x.kind == .rest {
                if let rest = CardShape.timedRest(x) { roundRest = rest }
                continue
            }
            if varying.contains(p) {
                schemeIndices.append(lines.count)
                lines.append(CardText.line(x, withQuantity: false))
            } else {
                lines.append(CardText.line(x))
            }
        }
        return true
    }

    /// HYROX-like: the same run before each station → "8 × (1000 m Run + station)" and the
    /// stations, one per line.
    private mutating func tryRunStations(_ segs: [WorkoutSegment]) -> Bool {
        let n: Int = segs.count
        if n < 4 || n % 2 != 0 { return false }
        let run: WorkoutSegment = segs[0]
        if run.kind != .run || run.target == nil { return false }
        var i: Int = 0
        while i < n {
            if !CardShape.same(segs[i], run) || segs[i + 1].kind != .station { return false }
            i += 2
        }
        kind = .runStations
        rounds = n / 2
        schemeLine = String(rounds) + " × (" + CardText.line(run).full + " + station)"
        var out: [WorkoutCard.Line] = []
        var j: Int = 1
        while j < n {
            out.append(CardText.line(segs[j]))
            j += 2
        }
        lines = out
        return true
    }
}

// MARK: - Short movement names

extension Movement {
    /// Card names (singular, plural) per the writing conventions: Title Case, plural when the
    /// quantity is more than 1, DB / KB / C&J / DU / ALT abbreviations.
    private static let shortNames: [String: (String, String)] = [
        "run": ("Run", "Run"),
        "skiErg": ("SkiErg", "SkiErg"),
        "sledPush": ("Sled Push", "Sled Push"),
        "sledPull": ("Sled Pull", "Sled Pull"),
        "burpeeBroadJumps": ("Burpee Broad Jump", "Burpee Broad Jumps"),
        "row": ("Row", "Row"),
        "farmersCarry": ("Farmers Carry", "Farmers Carry"),
        "sandbagLunges": ("Sandbag Lunge", "Sandbag Lunges"),
        "wallBalls": ("Wall Ball", "Wall Balls"),
        "dumbbellWalkingLunges": ("DB Walking Lunge", "DB Walking Lunges"),
        "burpees": ("Burpee", "Burpees"),
        "medBallBoxStepOvers": ("Med Ball Box Step-over", "Med Ball Box Step-overs"),
        "devilPress": ("Devil Press", "Devil Press"),
        "dumbbellOverShoulder": ("DB Over-Shoulder", "DB Over-Shoulder"),
        "airSquats": ("Air Squat", "Air Squats"),
        "kettlebellSwings": ("KB Swing", "KB Swings"),
        "pullUps": ("Pull-up", "Pull-ups"),
        "thrusters": ("Thruster", "Thrusters"),
        "lateralBurpeeOverDumbbell": ("Lateral Burpee Over DB", "Lateral Burpees Over DB"),
        "doubleUnders": ("DU", "DU"),
        "dumbbellSnatch": ("ALT DB Snatch", "ALT DB Snatches"),
        "pushUps": ("Push-up", "Push-ups"),
        "powerCleans": ("Power Clean", "Power Cleans"),
        "powerCleanAndJerk": ("Power C&J", "Power C&J")
    ]

    /// Card name of a known movement ("KB Swings", "ALT DB Snatch"), nil when unknown.
    public static func shortName(_ id: String, plural: Bool) -> String? {
        guard let names = shortNames[id] else { return nil }
        return plural ? names.1 : names.0
    }
}
