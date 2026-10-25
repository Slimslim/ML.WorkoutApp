import Foundation

public enum SessionCSVError: Error, Equatable {
    case missingColumnHeader
    case missingColumn(String)
    case malformedRow(line: Int)
}

/// Parser for the debug full-session CSV (spec §2.1):
///
///     # barpath-session v1, sessionId=<UUID>, startDate=<ISO8601>, liftType=<raw>
///     t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz
///     0.000000,...
///
/// `header` holds the `key=value` pairs of the `#` comment line(s); a comment part without `=`
/// (e.g. "barpath-session v1") is stored under the key "format".
public enum SessionCSV {
    public static let columns: [String] = ["t", "qw", "qx", "qy", "qz", "ax", "ay", "az",
                                           "gx", "gy", "gz", "rx", "ry", "rz"]

    public static func parse(_ text: String) throws -> (header: [String: String], samples: [MotionSample]) {
        var header: [String: String] = [:]
        var samples: [MotionSample] = []
        var colIndex: [Int]? = nil   // position of each of `columns` in the CSV row
        var lineNumber = 0

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { (c: Character) -> Bool in
            return c.isNewline
        })
        for rawLine in lines {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                let body = String(line.dropFirst())
                for part in body.split(separator: ",") {
                    let item = part.trimmingCharacters(in: .whitespaces)
                    if item.isEmpty { continue }
                    if let eq = item.firstIndex(of: "=") {
                        let key = String(item[item.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                        let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                        header[key] = value
                    } else if header["format"] == nil {
                        header["format"] = item
                    }
                }
                continue
            }

            if colIndex == nil {
                let names: [String] = line.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                var idx: [Int] = []
                for name in columns {
                    guard let pos = names.firstIndex(of: name) else {
                        if Double(names.first ?? "") != nil {
                            throw SessionCSVError.missingColumnHeader
                        }
                        throw SessionCSVError.missingColumn(name)
                    }
                    idx.append(pos)
                }
                colIndex = idx
                continue
            }

            guard let idx = colIndex else { throw SessionCSVError.missingColumnHeader }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            var values: [Double] = []
            values.reserveCapacity(idx.count)
            for pos in idx {
                if pos >= fields.count { throw SessionCSVError.malformedRow(line: lineNumber) }
                let field = fields[pos].trimmingCharacters(in: .whitespaces)
                guard let value = Double(field) else { throw SessionCSVError.malformedRow(line: lineNumber) }
                values.append(value)
            }
            samples.append(MotionSample(t: values[0],
                                        attitude: Quat(w: values[1], x: values[2], y: values[3], z: values[4]),
                                        userAccel: Vec3(values[5], values[6], values[7]),
                                        gravity: Vec3(values[8], values[9], values[10]),
                                        rotationRate: Vec3(values[11], values[12], values[13])))
        }

        if colIndex == nil { throw SessionCSVError.missingColumnHeader }
        return (header: header, samples: samples)
    }
}
