import Foundation

/// How session processes are restored after an app restart.
public enum RestoreMode: String, Codable, CaseIterable, Sendable {
    case none
    case rerun
    case live

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RestoreMode(rawValue: raw) ?? .none
    }
}
