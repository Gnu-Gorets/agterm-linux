import agtermCore
import Darwin
import Foundation
import os

/// Throwaway zsh-only gate for testing zmx-backed primary panes without bundling zmx.
enum ZmxSpike {
    struct Configuration {
        let command: String
        let environment: [String: String]
    }

    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "ZmxSpike")
    private static let socketPathLimit = 104

    @MainActor
    static func configuration(sessionID: UUID, environment base: [String: String]) -> Configuration? {
        let processEnv = ProcessInfo.processInfo.environment
        guard let rawPath = processEnv["AGTERM_ZMX_PATH"], !rawPath.isEmpty else { return nil }
        guard rawPath.hasPrefix("/") else { return bypass("AGTERM_ZMX_PATH is not absolute") }

        let executable = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return bypass("AGTERM_ZMX_PATH is not executable")
        }
        guard let shell = loginShell(), CommandRestore.basename(shell) == "zsh" else {
            return bypass("the login shell is not zsh")
        }
        guard let resources = processEnv["GHOSTTY_RESOURCES_DIR"],
              FileManager.default.fileExists(atPath: resources + "/shell-integration/zsh/.zshenv") else {
            return bypass("the bundled zsh integration is unavailable")
        }

        let stateDir = processEnv["AGTERM_STATE_DIR"] ?? PersistenceStore.defaultDirectory.path
        let socketDir = "/tmp/agterm-zmx-\(stableHash(stateDir))"
        let name = "agterm-" + sessionID.uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(12).lowercased()
        guard (socketDir + "/" + name).utf8.count < socketPathLimit else {
            return bypass("the zmx socket path exceeds the macOS sun_path budget")
        }

        var environment = base
        environment["SHELL"] = shell
        environment["ZDOTDIR"] = resources + "/shell-integration/zsh"
        if let original = processEnv["ZDOTDIR"] { environment["GHOSTTY_ZSH_ZDOTDIR"] = original }
        environment["ZMX_DIR"] = socketDir
        environment["ZMX_NO_DETACH_KEY"] = "1"
        let command = CommandRestore.shellQuotedLine([executable, "attach", name])
        return Configuration(command: command, environment: environment)
    }

    private static func loginShell() -> String? {
        guard let entry = getpwuid(getuid()), let ptr = entry.pointee.pw_shell else { return nil }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    @MainActor
    private static func bypass(_ reason: String) -> Configuration? {
        logger.warning("zmx spike bypassed: \(reason, privacy: .public)")
        return nil
    }
}
