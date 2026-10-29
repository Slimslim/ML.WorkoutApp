import Foundation
import os

/// Central loggers (view in Console.app, filter by subsystem "BarPathWatch").
enum Log {
    static let workout = Logger(subsystem: "BarPathWatch", category: "workout")
    static let motion = Logger(subsystem: "BarPathWatch", category: "motion")
    static let link = Logger(subsystem: "BarPathWatch", category: "link")
    static let files = Logger(subsystem: "BarPathWatch", category: "files")
}
