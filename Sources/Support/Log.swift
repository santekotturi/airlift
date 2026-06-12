import Foundation
import os

/// Lightweight wrapper around the unified logging system.
/// Use category-specific loggers so Console.app filtering is easy during the
/// pre-GA API period (schemas/quotas may shift — see PRD §4).
enum Log {
    private static let subsystem = "com.santekotturi.airlift"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let api = Logger(subsystem: subsystem, category: "googlehealth")
    static let health = Logger(subsystem: subsystem, category: "healthkit")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let background = Logger(subsystem: subsystem, category: "background")
}
