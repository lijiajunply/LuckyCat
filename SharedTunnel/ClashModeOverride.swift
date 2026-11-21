import Foundation

/// Applies the app-wide outbound mode to a Clash configuration without
/// rewriting the stored profile. The core reads the top-level `mode` key, so
/// replacing that one line keeps providers, rules and comments untouched.
enum ClashModeOverride {
    nonisolated static func apply(_ mode: TrafficMode, to configuration: String) -> String {
        let replacement = "mode: \(mode.rawValue)"
        let newline = configuration.contains("\r\n") ? "\r\n" : "\n"
        var lines = configuration.components(separatedBy: newline)
        for index in lines.indices {
            let line = lines[index]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") else {
                continue
            }
            guard line.prefix(while: { $0 != ":" })
                .trimmingCharacters(in: .whitespaces) == "mode" else {
                continue
            }
            lines[index] = replacement
            return lines.joined(separator: newline)
        }
        return replacement + newline + configuration
    }
}
