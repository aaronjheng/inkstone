import Foundation
import os

/// Unified logging for the whole app.
///
/// Deliberately a namespace of static functions rather than an instance or a
/// singleton: nothing here holds state, so call sites can log from any layer
/// (including `Sendable` values) without capturing a logger.
enum AppLogger {
    private static let subsystem = "app.inkstone"

    private static func logger(for category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func debug(
        _ message: String, category: String = "App", fields: [String: String] = [:]
    ) {
        #if DEBUG
            logger(for: category).debug("\(format(message, fields), privacy: .public)")
        #endif
    }

    static func info(
        _ message: String, category: String = "App", fields: [String: String] = [:]
    ) {
        logger(for: category).info("\(format(message, fields), privacy: .public)")
    }

    static func warn(
        _ message: String, category: String = "App", fields: [String: String] = [:]
    ) {
        logger(for: category).warning("\(format(message, fields), privacy: .public)")
    }

    static func error(
        _ message: String, category: String = "App", fields: [String: String] = [:]
    ) {
        logger(for: category).error("\(format(message, fields), privacy: .public)")
    }

    /// Structured fields, sorted so repeated runs produce identical output.
    private static func format(_ message: String, _ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return message }
        let extras =
            fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(message) \(extras)"
    }
}
