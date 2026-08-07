import Foundation
import Glibc

enum AppImageChildEnvironment {
    static func sanitized(_ environment: [String: String]) -> [String: String] {
        guard environment["APPDIR"] != nil else { return environment }
        var result = environment
        result.removeValue(forKey: "LD_LIBRARY_PATH")
        return result
    }

    static func sanitizeCurrentProcess() {
        guard ProcessInfo.processInfo.environment["APPDIR"] != nil else { return }
        unsetenv("LD_LIBRARY_PATH")
    }
}
